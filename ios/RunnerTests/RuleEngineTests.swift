//
//  RuleEngineTests.swift
//  RunnerTests
//
//  规则层回归测试：URL 归一化、JSONPath 子集、模板渲染、XPath / API 规则解析、
//  规则导入（JSON 与 kazumi:// 链接）、JSON 往返与错误分类。
//

import Foundation
import Testing
@testable import Runner

struct EpisodeURLTests {
    @Test("相对路径基于 baseUrl 补全") func relativePath() {
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "/play/1") == "https://example.com/play/1")
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "play/1") == "https://example.com/play/1")
    }

    @Test("同站 http 协议对齐到 baseUrl") func schemeAlignment() {
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "http://example.com/a") == "https://example.com/a")
        // 跨站保持原协议。
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "http://cdn.example.net/a") == "http://cdn.example.net/a")
    }

    @Test("去除多余尾部斜杠与空 query") func trailingSlash() {
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "https://example.com/a/b/?") == "https://example.com/a/b")
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "https://example.com/") == "https://example.com/")
    }

    @Test("空输入返回空串，且幂等") func idempotent() {
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com", raw: "   ") == "")
        let once = EpisodeURL.normalize(baseUrl: "https://example.com/base", raw: "../ep/1/")
        #expect(EpisodeURL.normalize(baseUrl: "https://example.com/base", raw: once) == once)
        #expect(once == "https://example.com/ep/1")
    }
}

struct RestrictedJSONPathTests {
    private let document = try! JSONValue.decode(
        #"{"data":{"list":[{"name":"A","url":"a"},{"name":"B","url":"b"}],"map":{"k":1}}}"#
    )

    @Test("点号与下标取值") func dotted() throws {
        let values = try RestrictedJSONPath.read(document, expression: "$.data.list[1].name")
        #expect(values == [.string("B")])
    }

    @Test("通配符展开数组") func wildcard() throws {
        let values = try RestrictedJSONPath.read(document, expression: "$.data.list[*].url")
        #expect(values == [.string("a"), .string("b")])
    }

    @Test("引号属性名与对象通配") func quoted() throws {
        #expect(try RestrictedJSONPath.read(document, expression: "$['data']['map']['k']") == [.int(1)])
        #expect(try RestrictedJSONPath.read(document, expression: "$.data.map[*]") == [.int(1)])
    }

    @Test("未匹配返回空数组") func missing() throws {
        #expect(try RestrictedJSONPath.read(document, expression: "$.data.none.x").isEmpty)
    }

    @Test("非法表达式报格式错误") func invalid() {
        #expect(throws: ApiRuleFormatError.self) { try RestrictedJSONPath.validate("data.list") }
        #expect(throws: ApiRuleFormatError.self) { try RestrictedJSONPath.validate("$.data[0:2]") }
        #expect(throws: ApiRuleFormatError.self) { try RestrictedJSONPath.validate("$.data.list[") }
    }
}

struct ApiRuleStrategyTests {
    private let strategy = ApiRuleStrategy()

    @Test("模板替换并对值做百分号编码") func templateEncoding() throws {
        let request = try strategy.prepareRequest(
            ApiRequestConfig(method: "GET", url: "https://api.example.com/s?q=@keyword&page=2"),
            variables: ["keyword": .string("进击的巨人")]
        )
        #expect(request.url.hasPrefix("https://api.example.com/s?q=%E8%BF%9B%E5%87%BB"))
        #expect(request.includeCookies)
    }

    @Test("精确占位保留原始类型") func exactVariable() throws {
        let body = try strategy.prepareRequest(
            ApiRequestConfig(method: "POST", url: "https://api.example.com/p", bodyType: .json, body: .object(["page": .string("@page")])),
            variables: ["page": .int(3)]
        )
        #expect(body.body == .object(["page": .int(3)]))
    }

    @Test("缺少模板变量报错") func missingVariable() {
        #expect(throws: ApiRuleFormatError.self) {
            _ = try strategy.prepareRequest(ApiRequestConfig(url: "https://a.com/@nope"), variables: [:]) 
        }
    }

    @Test("搜索解析：名称、来源与详情页模板") func parseSearch() throws {
        let raw = #"{"data":[{"name":"进击的巨人","url":"123"},{"name":"","url":"broken"}]}"#
        let config = ApiSearchConfig(
            request: ApiRequestConfig(url: "https://a.com"),
            listPath: "$.data[*]",
            namePath: "$.name",
            sourcePath: "$.url",
            sourceTemplate: "/detail/GV@source"
        )
        let result = try strategy.parseSearch(raw, config: config)
        #expect(result.items.count == 1)
        #expect(result.items.first?.name == "进击的巨人")
        #expect(result.items.first?.src == "/detail/GV123")
        #expect(result.diagnostics.count == 1)
    }

    @Test("分隔符格式解析多条线路") func parseDelimited() throws {
        let raw = #"{"names":"线路A$$$线路B","eps":"第1话$https://a.com/1#第2话$https://a.com/2$$$第1话$https://b.com/1"}"#
        let config = ApiChapterConfig(
            request: ApiRequestConfig(url: "https://a.com"),
            format: .delimited,
            roadNamesPath: "$.names",
            roadEpisodesPath: "$.eps"
        )
        let result = try strategy.parseChapters(raw, config: config, source: "x", baseUrl: "https://a.com")
        #expect(result.roads.count == 2)
        #expect(result.roads[0].name == "线路A")
        #expect(result.roads[0].data == ["https://a.com/1", "https://a.com/2"])
        #expect(result.roads[0].identifier == ["第1话", "第2话"])
        #expect(result.roads[1].data == ["https://b.com/1"])
    }

    @Test("嵌套格式使用播放页模板并补全相对地址") func parseNestedTemplate() throws {
        let raw = #"{"data":{"roads":[{"name":"高清","episodes":[{"name":"第1话","id":"11"}]}]}}"#
        let config = ApiChapterConfig(
            request: ApiRequestConfig(url: "https://a.com"),
            format: .nested,
            episodeUrlPath: "$.id",
            episodePage: ApiEpisodePageConfig(json: .object([
                "url": .string("/play/@episodeUrl"),
                "query": .object(["road": .string("@roadNumber")])
            ]))
        )
        let result = try strategy.parseChapters(raw, config: config, source: "x", baseUrl: "https://a.com")
        #expect(result.roads.first?.name == "高清")
        #expect(result.roads.first?.data.first == "https://a.com/play/11?road=1")
    }
}

struct XPathRuleStrategyTests {
    private let strategy = XPathRuleStrategy()
    private let config = RuleExecutionConfig(plugin: Plugin(
        api: "9",
        name: "站点",
        version: "1.0.0",
        baseUrl: "https://example.com",
        searchURL: "https://example.com/search?q=@keyword",
        searchList: "//div[@class='item']",
        searchName: ".//h3/text()",
        searchResult: ".//a",
        chapterRoads: "//div[@class='road']",
        chapterResult: ".//a"
    ))

    @Test("搜索 URL 编码关键词，GET 模式附带 Cookie") func prepareSearch() throws {
        let request = try strategy.prepareSearchRequest(config, keyword: "进击 的巨人")
        #expect(request.method == "GET")
        #expect(request.url == "https://example.com/search?q=%E8%BF%9B%E5%87%BB%20%E7%9A%84%E5%B7%A8%E4%BA%BA")
        #expect(request.includeCookies)
    }

    @Test("章节请求不附带 Cookie") func chapterWithoutCookies() throws {
        let request = try strategy.prepareChapterRequest(config, source: "/play/1")
        #expect(request.url == "https://example.com/play/1")
        #expect(request.includeCookies == false)
    }

    @Test("搜索解析提取名称与 href") func parseSearch() throws {
        let html = """
        <html><body>
          <div class="item"><h3> 进击的巨人 </h3><a href="/play/1">播放</a></div>
          <div class="item"><h3>无链接</h3></div>
        </body></html>
        """
        let result = try strategy.parseSearch(html, config: config)
        #expect(result.items == [SearchItem(name: "进击的巨人", src: "/play/1")])
        #expect(result.diagnostics.count == 1)
        #expect(result.matchedFragments.count == 1)
    }

    @Test("章节解析去空白命名并补全绝对地址") func parseChapters() throws {
        let html = """
        <html><body>
          <div class="road"><a href="/play/1-1"> 第 1 话 </a><a href="/play/1-2">第 2 话</a></div>
          <div class="road"><a>无地址</a></div>
        </body></html>
        """
        let result = try strategy.parseChapters(html, config: config)
        #expect(result.roads.count == 1)
        #expect(result.roads[0].name == "播放线路1")
        #expect(result.roads[0].identifier == ["第1话", "第2话"])
        #expect(result.roads[0].data.first == "https://example.com/play/1-1")
    }

    @Test("验证页检测：文本与 XPath") func captchaDetection() {
        let anti = AntiCrawlerConfig(
            enabled: true,
            captchaType: .imageCaptcha,
            captchaImage: "//img[@id='captcha']",
            captchaInput: "",
            captchaButton: "",
            captchaDetectType: .text,
            captchaDetectValue: "请完成验证"
        )
        #expect(strategy.detectsCaptchaChallenge("<html>请完成验证</html>", config: anti))
        #expect(!strategy.detectsCaptchaChallenge("<html>正常页面</html>", config: anti))

        var xpathAnti = anti
        xpathAnti.captchaDetectType = .xpath
        xpathAnti.captchaDetectValue = "//img[@id='captcha']"
        #expect(strategy.detectsCaptchaChallenge("<html><img id='captcha'/></html>", config: xpathAnti))
        // 未配置检测值时会退化到验证码图片 / 按钮选择器。
        var fallback = xpathAnti
        fallback.captchaDetectValue = ""
        #expect(strategy.detectsCaptchaChallenge("<html><img id='captcha'/></html>", config: fallback))
    }
}

struct PluginImportTests {
    private let ruleJSON = #"{"api":"9","name":"测试站","version":"1.0.0","baseURL":"https://example.com","searchURL":"https://example.com/s?q=@keyword","searchList":"//div","searchName":"//h3","searchResult":"//a","chapterRoads":"//div","chapterResult":"//a"}"#

    @Test("解析单条 JSON 规则") func singleObject() {
        let result = PluginImportParser.parse(ruleJSON)
        #expect(result.plugins.count == 1)
        #expect(result.plugins.first?.name == "测试站")
        #expect(result.plugins.first?.baseUrl == "https://example.com")
        #expect(result.failures.isEmpty)
    }

    @Test("解析 kazumi:// 链接并可往返") func ruleLinkRoundTrip() throws {
        let link = KazumiRuleLink.encode(json: ruleJSON)
        #expect(try KazumiRuleLink.decode(link) == ruleJSON)
        let result = PluginImportParser.parse("看看这条规则 \(link) 谢谢")
        #expect(result.plugins.first?.name == "测试站")
    }

    @Test("空名称与更高版本要求被拒绝") func rejectsInvalid() {
        let emptyName = PluginImportParser.parse(#"{"api":"9","name":"  ","version":"1"}"#)
        #expect(emptyName.plugins.isEmpty)
        #expect(emptyName.failures.count == 1)

        let newer = PluginImportParser.parse(#"{"api":"99","name":"未来规则","version":"1"}"#)
        #expect(newer.plugins.isEmpty)
    }

    @Test("同名规则合并去重且保留顺序") func dedupe() {
        let other = ruleJSON.replacingOccurrences(of: "测试站", with: "其他站")
        let input = "[\(other),\(ruleJSON),\(ruleJSON)]"
        let result = PluginImportParser.parse(input)
        #expect(result.plugins.count == 2)
        #expect(result.plugins.first?.name == "其他站")
        #expect(result.duplicateCount == 1)
    }
}

struct PluginModelTests {
    @Test("JSON 往返保留 muliSources 与 API 配置") func roundTrip() throws {
        var plugin = Plugin(api: "9", name: "往返", version: "2.0.0")
        plugin.searchMode = .api
        plugin.searchApiConfig.listPath = "$.items[*]"
        plugin.muliSources = false
        plugin.antiCrawlerConfig.enabled = true

        let json = plugin.toJSON()
        #expect(json.objectValue?["muliSources"]?.boolValue == false)
        let restored = Plugin(json: try JSONValue.decode(json.serialized(pretty: false)))
        #expect(restored == plugin)
    }

    @Test("api 级别按整数比较") func apiLevel() {
        #expect(Plugin(api: "9", name: "n", version: "v").requiresNewerClient == false)
        #expect(Plugin(api: "10", name: "n", version: "v").requiresNewerClient == true)
        #expect(Plugin(api: "abc", name: "n", version: "v").requiresNewerClient == false)
    }

    @Test("版本比较忽略缺失段") func versionCompare() {
        #expect(VersionCompare.needUpdate(local: "1.0.0", remote: "1.0.1"))
        #expect(VersionCompare.needUpdate(local: "1.2", remote: "1.2.0") == false)
        #expect(VersionCompare.needUpdate(local: "2.0.0", remote: "1.9.9") == false)
    }

    /// 规则里的数字不能变布尔：JSONSerialization 给的是 NSNumber，
    /// NSNumber 桥到 Bool 永远成功，`1` 曾经被发成 `page=true`（LP 3422 的抓包）。
    @Test("数字与布尔分开解析，query 渲染不串") func numbersStayNumbers() throws {
        let raw = #"""
        {"api":"8","name":"数字","version":"1","searchMode":"api",
         "searchApiConfig":{"request":{"method":"GET","url":"https://a.com/s",
         "query":{"q":"@keyword","page":1,"page_size":50,"ratio":1.5,"deep":true,"off":false}}}}
        """#
        let plugin = Plugin(json: try JSONValue.decode(raw))
        let query = plugin.searchApiConfig.request.query
        #expect(query["page"] == .int(1))
        #expect(query["page_size"] == .int(50))
        #expect(query["ratio"] == .double(1.5))
        #expect(query["deep"] == .bool(true))
        #expect(query["off"] == .bool(false))

        let request = try ApiRuleStrategy().prepareRequest(
            plugin.searchApiConfig.request,
            variables: ["keyword": .string("飙马野郎")]
        )
        #expect(request.query["page"]?.stringValue == "1")
        #expect(request.query["page_size"]?.stringValue == "50")
        #expect(request.query["ratio"]?.stringValue == "1.5")
        #expect(request.query["deep"]?.stringValue == "true")
        #expect(request.query["off"]?.stringValue == "false")
    }
}

struct RuleEngineTests {
    /// 用固定响应替换真实网络，验证错误分类与空结果处理。
    private struct StubExecutor: RuleRequestExecutor {
        let response: Result<String, Error>

        func execute(_ request: PreparedRuleRequest, config: RuleExecutionConfig) async throws -> String {
            try response.get()
        }
    }

    private func makeConfig() -> RuleExecutionConfig {
        RuleExecutionConfig(plugin: Plugin(
            api: "9",
            name: "站点",
            version: "1",
            baseUrl: "https://example.com",
            searchURL: "https://example.com/s?q=@keyword",
            searchList: "//div[@class='item']",
            searchName: ".//h3/text()",
            searchResult: ".//a",
            chapterRoads: "//div[@class='road']",
            chapterResult: ".//a"
        ))
    }

    @Test("空结果抛出 noResult") func noResult() async {
        let engine = RuleEngine(requestExecutor: StubExecutor(response: .success("<html></html>")))
        do {
            _ = try await engine.search(makeConfig(), keyword: "x")
            Issue.record("预期抛出 noResult")
        } catch let error as RuleError {
            guard case .noResult(let plugin) = error else {
                Issue.record("抛出了错误的 RuleError")
                return
            }
            #expect(plugin == "站点")
        } catch {
            Issue.record("抛出了非 RuleError")
        }
    }

    @Test("5xx 挑战页转成 captchaRequired") func challengePage() async {
        var anti = AntiCrawlerConfig.empty
        anti.enabled = true
        anti.captchaDetectType = .text
        anti.captchaDetectValue = "请完成验证"
        var plugin = Plugin(
            api: "9",
            name: "站点",
            version: "1",
            baseUrl: "https://example.com",
            searchURL: "https://example.com/s?q=@keyword",
            searchList: "//div[@class='item']",
            searchName: ".//h3/text()",
            searchResult: ".//a"
        )
        plugin.antiCrawlerConfig = anti
        let config = RuleExecutionConfig(plugin: plugin)
        let failure = NetworkError.badResponse(status: 503, body: "<html>请完成验证</html>", headers: [:])
        let engine = RuleEngine(requestExecutor: StubExecutor(response: .failure(failure)))
        do {
            _ = try await engine.search(config, keyword: "x")
            Issue.record("预期抛出 captchaRequired")
        } catch let error as RuleError {
            guard case .captchaRequired(let plugin) = error else {
                Issue.record("抛出了错误的 RuleError")
                return
            }
            #expect(plugin == "站点")
        } catch {
            Issue.record("抛出了非 RuleError")
        }
    }

    @Test("取消错误原样抛出") func cancellation() async {
        do {
            _ = try await engineWithCancellation.queryChapters(makeConfig(), source: "https://example.com/1")
            Issue.record("应当抛出取消错误")
        } catch NetworkError.cancelled {
            // 期望路径：取消不会被包装成 RuleError.chapterFailed。
        } catch {
            Issue.record("错误类型不是 NetworkError.cancelled: \(error)")
        }
    }

    private var engineWithCancellation: RuleEngine {
        RuleEngine(requestExecutor: StubExecutor(response: .failure(NetworkError.cancelled)))
    }
}
