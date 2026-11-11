//
//  XPathRuleStrategy.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/xpath_rule_strategy.dart（HTML 解析改用 Fuzi/libxml2，
//  对应原项目的 xpath_selector_html_parser）。
//
//  与 Dart 版本对齐的行为：
//  * 搜索 URL 中的 `@keyword` 用 query 组件编码方式替换；POST 模式把 query 拆成表单体；
//  * 章节请求不附带 Cookie（历史行为）；
//  * 解析失败按节点粒度跳过并写入 diagnostics；只有 XPath 表达式本身出错才抛出；
//  * 剧集名去除所有空白字符，空名回退为「第 N 集」。
//

import Foundation
import Fuzi

// 类型名一律写 `Fuzi.XMLElement`：macOS 侧 Foundation 也导出了同名的 `XMLElement`
// （iOS 侧没有），两边一起 import 时裸写这个名字在 macOS 上会报
// "ambiguous for type lookup in this context"，写全名两边都对。

struct XPathRuleStrategy: Sendable {
    func prepareSearchRequest(_ config: RuleExecutionConfig, keyword: String) throws -> PreparedRuleRequest {
        let encodedKeyword = encodeQueryComponent(keyword)
        let queryURL = config.searchUrl.replacingOccurrences(of: "@keyword", with: encodedKeyword)
        guard let components = URLComponents(string: queryURL),
              !(components.scheme ?? "").isEmpty,
              !(components.host ?? "").isEmpty else {
            throw XPathRuleFormatError(
                message: String(localized: "搜索 URL 无效: \(String(describing: queryURL))"),
                kind: .invalidUrl
            )
        }
        if !config.usePost {
            return PreparedRuleRequest(method: "GET", url: queryURL, includeCookies: true)
        }
        var base = components
        base.percentEncodedQuery = nil
        base.query = nil
        var body: [String: JSONValue] = [:]
        for item in components.queryItems ?? [] {
            body[item.name] = .string(item.value ?? "")
        }
        return PreparedRuleRequest(
            method: "POST",
            url: base.string ?? queryURL,
            bodyType: .form,
            body: .object(body),
            includeCookies: true
        )
    }

    func prepareChapterRequest(_ config: RuleExecutionConfig, source: String) throws -> PreparedRuleRequest {
        let url = EpisodeURL.normalize(baseUrl: config.baseUrl, raw: source)
        guard let components = URLComponents(string: url),
              !(components.scheme ?? "").isEmpty,
              !(components.host ?? "").isEmpty else {
            throw XPathRuleFormatError(
                message: String(localized: "选集 URL 无效: \(String(describing: url))"),
                kind: .invalidUrl
            )
        }
        // XPath 章节请求历史上不带已存储的 Cookie，只有搜索请求附带。
        return PreparedRuleRequest(method: "GET", url: url)
    }

    func parseSearch(_ raw: String, config: RuleExecutionConfig) throws -> RuleSearchParseResult {
        let html = try documentElement(raw)
        // Fuzi 的节点用 unowned 指向所属文档：文档必须先于节点活着。
        // 若文档只是 documentElement 里的局部变量，它会在函数返回时释放，
        // 下面第一次 root.xpath(...) 就会撞上「read an unowned reference … already destroyed」。
        defer { withExtendedLifetime(html) {} }
        let root = html.root
        if detectsCaptchaChallenge(raw, config: config.antiCrawlerConfig, htmlElement: root) {
            throw RuleError.captchaRequired(plugin: config.pluginName)
        }

        var items: [SearchItem] = []
        var fragments: [String] = []
        var diagnostics: [String] = []
        let nodes = try runSelector(.searchList, expression: config.searchList) {
            Array(root.xpath(config.searchList))
        }

        for (index, node) in nodes.enumerated() {
            do {
                let name = try runSelector(.searchName, expression: config.searchName) { () -> Fuzi.XMLElement? in
                    node.xpath(config.searchName).first
                }?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let source = try runSelector(.searchResult, expression: config.searchResult) { () -> Fuzi.XMLElement? in
                    node.xpath(config.searchResult).first
                }?.attr("href")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty || source.isEmpty {
                    diagnostics.append(String(localized: "搜索节点 \(String(describing: index)) 缺少名称或来源，已跳过"))
                    continue
                }
                items.append(SearchItem(name: name, src: source))
                fragments.append(fragment(node))
            } catch let error as XPathRuleFormatError {
                throw error
            } catch {
                diagnostics.append(String(localized: "搜索节点 \(String(describing: index)) 解析失败: \(String(describing: error.localizedDescription))"))
            }
        }

        return RuleSearchParseResult(items: items, matchedFragments: fragments, diagnostics: diagnostics)
    }

    func parseChapters(_ raw: String, config: RuleExecutionConfig) throws -> RuleChapterParseResult {
        let html = try documentElement(raw)
        // 同 parseSearch：文档必须由这里持有，不能随 documentElement 返回一起释放。
        defer { withExtendedLifetime(html) {} }
        let root = html.root
        var roads: [Road] = []
        var diagnostics: [String] = []
        let roadNodes = try runSelector(.chapterRoads, expression: config.chapterRoads) {
            Array(root.xpath(config.chapterRoads))
        }

        for (roadIndex, roadNode) in roadNodes.enumerated() {
            do {
                var urls: [String] = []
                var names: [String] = []
                let episodeNodes = try runSelector(.chapterResult, expression: config.chapterResult) {
                    Array(roadNode.xpath(config.chapterResult))
                }
                for (episodeIndex, episode) in episodeNodes.enumerated() {
                    let source = episode.attr("href")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if source.isEmpty {
                        diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 的剧集节点 \(String(describing: episodeIndex)) 缺少 URL，已跳过"))
                        continue
                    }
                    let name = removeWhitespace(episode.stringValue)
                    urls.append(EpisodeURL.normalize(baseUrl: config.baseUrl, raw: source))
                    names.append(name.isEmpty ? String(localized: "第\(String(describing: episodeIndex + 1))集") : name)
                }
                if urls.isEmpty {
                    diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 没有有效剧集，已跳过"))
                    continue
                }
                roads.append(Road(
                    name: String(localized: "播放线路\(String(describing: roads.count + 1))"),
                    data: urls,
                    identifier: names
                ))
            } catch let error as XPathRuleFormatError {
                throw error
            } catch {
                diagnostics.append(String(localized: "线路节点 \(String(describing: roadIndex)) 解析失败: \(String(describing: error.localizedDescription))"))
            }
        }

        return RuleChapterParseResult(roads: roads, diagnostics: diagnostics)
    }
    func detectsCaptchaChallenge(
        _ raw: String,
        config: AntiCrawlerConfig,
        htmlElement: Fuzi.XMLElement? = nil
    ) -> Bool {
        guard config.enabled else { return false }
        let detectValue = config.captchaDetectValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detectValue.isEmpty {
            switch config.captchaDetectType {
            case .text:
                return raw.contains(detectValue)
            case .regex:
                guard let regex = try? NSRegularExpression(
                    pattern: detectValue,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]
                ) else {
                    return false
                }
                let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
                return regex.firstMatch(in: raw, options: [], range: range) != nil
            case .xpath:
                let parsed = htmlElement == nil ? (try? documentElement(raw)) : nil
                defer { withExtendedLifetime(parsed) {} }
                guard let root = htmlElement ?? parsed?.root else { return false }
                let node: Fuzi.XMLElement? = try? runSelector(.captchaDetectValue, expression: detectValue) {
                    root.xpath(detectValue).first
                }
                return node != nil
            }
        }

        let parsedFallback = htmlElement == nil ? (try? documentElement(raw)) : nil
        defer { withExtendedLifetime(parsedFallback) {} }
        guard let root = htmlElement ?? parsedFallback?.root else { return false }
        let fallbackSelectors: [(XPathRuleField, String)] = [
            (.captchaImage, config.captchaImage),
            (.captchaButton, config.captchaButton)
        ]
        for (field, expression) in fallbackSelectors {
            if expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let node: Fuzi.XMLElement? = try? runSelector(field, expression: expression) {
                root.xpath(expression).first
            }
            if node != nil { return true }
        }
        return false
    }

    // MARK: - Helpers

    /// 解析出的文档与它的根节点。两者必须一起被持有。
    struct ParsedHTML {
        let document: HTMLDocument
        let root: Fuzi.XMLElement
    }

    /// 解析 HTML，并**连同文档一起**返回。
    ///
    /// Fuzi 的节点内部用 unowned 指向所属文档，文档一释放，节点上任何一次
    /// XPath 查询都会以「read an unowned reference but object was already
    /// destroyed」硬崩——这不是能 catch 的错误，是运行时 fatalError。
    /// 所以文档不能是这里的局部变量，必须由调用方持有到用完为止。
    private func documentElement(_ raw: String) throws -> ParsedHTML {
        do {
            let document = try HTMLDocument(data: Data(raw.utf8))
            guard let root = document.root else {
                throw XPathRuleFormatError(message: String(localized: "HTML 响应没有根节点"), kind: .invalidDocument)
            }
            return ParsedHTML(document: document, root: root)
        } catch let error as XPathRuleFormatError {
            throw error
        } catch {
            throw XPathRuleFormatError(
                message: String(localized: "HTML 响应解析失败"),
                kind: .invalidDocument,
                cause: String(describing: error)
            )
        }
    }

    /// 空表达式与非法表达式都视为规则错误；其他节点级异常由调用方吞掉并记入 diagnostics。
    private func runSelector<T>(_ field: XPathRuleField, expression: String, query: () throws -> T) throws -> T {
        if expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw XPathRuleFormatError(
                message: String(localized: "\(String(describing: field.label)) XPath 不能为空"),
                kind: .invalidSelector,
                field: field,
                expression: expression
            )
        }
        do {
            return try query()
        } catch {
            throw XPathRuleFormatError(
                message: String(localized: "\(String(describing: field.label)) XPath 无效: \(String(describing: expression))"),
                kind: .invalidSelector,
                field: field,
                expression: expression,
                cause: String(describing: error)
            )
        }
    }

    /// 对应 Dart 的 `node is Element ? node.outerHtml : node.text`。
    private func fragment(_ node: Fuzi.XMLElement) -> String {
        node.rawXML
    }

    /// 对应 Dart 的 `replaceAll(RegExp(r'\s+'), '')`：去掉所有空白字符
    /// （含全角空格，避免 "第 1 集" 与 "第1集" 被视为不同剧集）。
    private func removeWhitespace(_ value: String) -> String {
        String(value.filter { !$0.isWhitespace && $0 != "\u{3000}" })
    }

    /// 对应 Dart 的 Uri.encodeQueryComponent。
    private func encodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
