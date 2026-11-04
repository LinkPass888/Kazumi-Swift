//
//  PluginDraft.swift
//  Kazumi
//
//  编辑器表单状态与"构建 Plugin"的校验逻辑，1:1 对应
//  plugin_editor_page.dart 的 _buildEditedPlugin / _buildSearchApiConfig /
//  _buildChapterApiConfig / _parseJsonMap / _parseBody。
//
//  两张表（搜索 / 选集）都同时保存 XPath 与 API 字段，保存时只校验当前模式，
//  但两种模式的内容都会写回，避免切换模式丢失已填内容。
//

import Foundation

struct PluginDraft {
    // 基本信息
    var name = ""
    var version = ""
    var baseUrl = ""
    var searchURL = ""
    var type = "anime"
    var muliSources = true
    var useWebview = true
    var useNativePlayer = true
    var usePost = false
    var useLegacyParser = false
    var adBlocker = false
    var userAgent = ""
    var referer = ""

    // XPath 规则
    var searchList = ""
    var searchName = ""
    var searchResult = ""
    var chapterRoads = ""
    var chapterResult = ""

    var searchMode: RuleMode = .xpath
    var chapterMode: RuleMode = .xpath

    // API 搜索
    var searchMethod = "GET"
    var searchHeaders = ""
    var searchQuery = ""
    var searchBodyType: ApiBodyType = .none
    var searchBody = ""
    var searchListPath = "$.data[*]"
    var searchNamePath = "$.name"
    var searchSourcePath = "$.url"
    var searchSourceTemplate = ""

    // API 选集
    var chapterMethod = "GET"
    var chapterURL = ""
    var chapterHeaders = ""
    var chapterQuery = ""
    var chapterBodyType: ApiBodyType = .none
    var chapterBody = ""
    var chapterFormat: ApiChapterFormat = .nested
    var chapterRoadsPath = "$.data.roads[*]"
    var chapterRoadNamePath = "$.name"
    var chapterEpisodesPath = "$.episodes[*]"
    var chapterEpisodeNamePath = "$.name"
    var chapterEpisodeURLPath = "$.url"
    var chapterRoadNamesPath = ""
    var chapterRoadEpisodesPath = ""
    var chapterRoadSeparator = "$$$"
    var chapterEpisodeSeparator = "#"
    var chapterFieldSeparator = "$"
    var chapterVariables = ""
    var chapterPageURL = ""
    var chapterPageQuery = ""

    // 反反爬虫
    var antiCrawlerEnabled = false
    var captchaType: CaptchaType = .imageCaptcha
    var captchaImage = ""
    var captchaInput = ""
    var captchaButton = ""
    var captchaDetectType: CaptchaDetectType = .xpath
    var captchaDetectValue = ""
    var captchaScript = ""

    init() {}

    init(plugin: Plugin) {
        name = plugin.name
        version = plugin.version
        baseUrl = plugin.baseUrl
        searchURL = plugin.searchURL
        type = plugin.type
        muliSources = plugin.muliSources
        useWebview = plugin.useWebview
        useNativePlayer = plugin.useNativePlayer
        usePost = plugin.usePost
        useLegacyParser = plugin.useLegacyParser
        adBlocker = plugin.adBlocker
        userAgent = plugin.userAgent
        referer = plugin.referer

        searchList = plugin.searchList
        searchName = plugin.searchName
        searchResult = plugin.searchResult
        chapterRoads = plugin.chapterRoads
        chapterResult = plugin.chapterResult
        searchMode = plugin.searchMode
        chapterMode = plugin.chapterMode

        let search = plugin.searchApiConfig
        searchMethod = search.request.method
        searchHeaders = Self.jsonText(search.request.headers)
        searchQuery = Self.jsonText(search.request.query)
        searchBodyType = search.request.bodyType
        searchBody = search.request.body.map { $0.serialized(pretty: true) } ?? ""
        searchListPath = search.listPath
        searchNamePath = search.namePath
        searchSourcePath = search.sourcePath
        searchSourceTemplate = search.sourceTemplate

        let chapter = plugin.chapterApiConfig
        chapterMethod = chapter.request.method
        chapterURL = chapter.request.url
        chapterHeaders = Self.jsonText(chapter.request.headers)
        chapterQuery = Self.jsonText(chapter.request.query)
        chapterBodyType = chapter.request.bodyType
        chapterBody = chapter.request.body.map { $0.serialized(pretty: true) } ?? ""
        chapterFormat = chapter.format
        chapterRoadsPath = chapter.roadsPath
        chapterRoadNamePath = chapter.roadNamePath
        chapterEpisodesPath = chapter.episodesPath
        chapterEpisodeNamePath = chapter.episodeNamePath
        chapterEpisodeURLPath = chapter.episodeUrlPath
        chapterRoadNamesPath = chapter.roadNamesPath
        chapterRoadEpisodesPath = chapter.roadEpisodesPath
        chapterRoadSeparator = chapter.roadSeparator
        chapterEpisodeSeparator = chapter.episodeSeparator
        chapterFieldSeparator = chapter.fieldSeparator
        chapterVariables = chapter.variables.isEmpty
            ? ""
            : JSONValue.dictionary(chapter.variables.map { ($0.key, JSONValue.string($0.value)) }).serialized(pretty: true)
        chapterPageURL = chapter.episodePage?.url ?? ""
        chapterPageQuery = chapter.episodePage.map { Self.jsonText($0.query) } ?? ""

        let anti = plugin.antiCrawlerConfig
        antiCrawlerEnabled = anti.enabled
        captchaType = anti.captchaType
        captchaImage = anti.captchaImage
        captchaInput = anti.captchaInput
        captchaButton = anti.captchaButton
        captchaDetectType = anti.captchaDetectType
        captchaDetectValue = anti.captchaDetectValue
        captchaScript = anti.captchaScript
    }
    /// 对应 _buildEditedPlugin：任一模式为 API 时，api 级别提升到当前客户端级别。
    func build(apiLevel: Int) throws -> Plugin {
        let usesAPI = searchMode == .api || chapterMode == .api
        return Plugin(
            api: usesAPI ? String(apiLevel) : "1",
            type: type,
            name: name,
            version: version,
            muliSources: muliSources,
            useWebview: useWebview,
            useNativePlayer: useNativePlayer,
            usePost: usePost,
            useLegacyParser: useLegacyParser,
            adBlocker: adBlocker,
            userAgent: userAgent,
            baseUrl: baseUrl,
            searchURL: searchURL,
            searchList: searchList,
            searchName: searchName,
            searchResult: searchResult,
            chapterRoads: chapterRoads,
            chapterResult: chapterResult,
            referer: referer,
            searchMode: searchMode,
            chapterMode: chapterMode,
            searchApiConfig: try buildSearchConfig(),
            chapterApiConfig: try buildChapterConfig(),
            antiCrawlerConfig: AntiCrawlerConfig(
                enabled: antiCrawlerEnabled,
                captchaType: captchaType,
                captchaImage: captchaImage,
                captchaInput: captchaInput,
                captchaButton: captchaButton,
                captchaDetectType: captchaDetectType,
                captchaDetectValue: captchaDetectValue,
                captchaScript: captchaScript
            )
        )
    }

    private func buildSearchConfig() throws -> ApiSearchConfig {
        // 只有当前模式是 API 时才裁剪空白并做严格校验，避免误报干扰 XPath 规则。
        let shouldValidate = searchMode == .api
        func value(_ text: String) -> String {
            shouldValidate ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
        let config = ApiSearchConfig(
            request: ApiRequestConfig(
                method: searchMethod.uppercased(),
                url: value(searchURL),
                headers: try parseJSONMap(searchHeaders, label: String(localized: "搜索请求头")),
                query: try parseJSONMap(searchQuery, label: String(localized: "搜索查询参数")),
                bodyType: searchBodyType,
                body: try parseBody(searchBody, bodyType: searchBodyType, label: String(localized: "搜索请求体"))
            ),
            listPath: value(searchListPath),
            namePath: value(searchNamePath),
            sourcePath: value(searchSourcePath),
            sourceTemplate: value(searchSourceTemplate)
        )
        guard shouldValidate else { return config }
        guard !config.request.url.isEmpty else {
            throw EditorError.emptyRequestURL(String(localized: "搜索请求地址"))
        }
        let strategy = ApiRuleStrategy()
        _ = try strategy.prepareRequest(config.request, variables: ["keyword": .string("test")])
        try strategy.validateSearchConfig(config)
        return config
    }

    private func buildChapterConfig() throws -> ApiChapterConfig {
        let pageURL = chapterPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let variablesRaw = try parseJSONMap(chapterVariables, label: String(localized: "选集响应变量"))
        var variables: [String: String] = [:]
        for (key, value) in variablesRaw {
            variables[key] = value.stringValue ?? value.serialized(pretty: false)
        }
        let pageQuery = try parseJSONMap(chapterPageQuery, label: String(localized: "播放页查询参数"))
        // ApiEpisodePageConfig 只提供 json: 构造器，这里按 toJSON() 的同构形态回填。
        let episodePage = pageURL.isEmpty
            ? nil
            : ApiEpisodePageConfig(json: .object([
                "url": .string(pageURL),
                "query": .object(pageQuery)
            ]))
        let config = ApiChapterConfig(
            request: ApiRequestConfig(
                method: chapterMethod.uppercased(),
                url: chapterURL.trimmingCharacters(in: .whitespacesAndNewlines),
                headers: try parseJSONMap(chapterHeaders, label: String(localized: "选集请求头")),
                query: try parseJSONMap(chapterQuery, label: String(localized: "选集查询参数")),
                bodyType: chapterBodyType,
                body: try parseBody(chapterBody, bodyType: chapterBodyType, label: String(localized: "选集请求体"))
            ),
            format: chapterFormat,
            roadsPath: chapterRoadsPath.trimmingCharacters(in: .whitespacesAndNewlines),
            roadNamePath: chapterRoadNamePath.trimmingCharacters(in: .whitespacesAndNewlines),
            episodesPath: chapterEpisodesPath.trimmingCharacters(in: .whitespacesAndNewlines),
            episodeNamePath: chapterEpisodeNamePath.trimmingCharacters(in: .whitespacesAndNewlines),
            episodeUrlPath: chapterEpisodeURLPath.trimmingCharacters(in: .whitespacesAndNewlines),
            roadNamesPath: chapterRoadNamesPath.trimmingCharacters(in: .whitespacesAndNewlines),
            roadEpisodesPath: chapterRoadEpisodesPath.trimmingCharacters(in: .whitespacesAndNewlines),
            roadSeparator: chapterRoadSeparator,
            episodeSeparator: chapterEpisodeSeparator,
            fieldSeparator: chapterFieldSeparator,
            variables: variables,
            episodePage: episodePage
        )
        guard chapterMode == .api else { return config }
        guard !config.request.url.isEmpty else {
            throw EditorError.emptyRequestURL(String(localized: "选集请求地址"))
        }
        let strategy = ApiRuleStrategy()
        _ = try strategy.prepareRequest(config.request, variables: ["source": .string("test")])
        try strategy.validateChapterConfig(config)
        return config
    }

    /// 对应 _parseJsonMap：空文本视为空对象，非对象报错。
    private func parseJSONMap(_ text: String, label: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        let decoded: JSONValue
        do {
            decoded = try JSONValue.decode(trimmed)
        } catch {
            throw EditorError.headersNotObject(label)
        }
        guard let object = decoded.objectValue else {
            throw EditorError.headersNotObject(label)
        }
        return object
    }

    /// 对应 _parseBody：none 时丢弃内容；空文本视为空对象；表单模式必须是对象。
    private func parseBody(_ text: String, bodyType: ApiBodyType, label: String) throws -> JSONValue? {
        guard bodyType != .none else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        let decoded: JSONValue
        do {
            decoded = try JSONValue.decode(trimmed)
        } catch {
            throw EditorError.bodyNotJSON(label, error.localizedDescription)
        }
        if bodyType == .form, decoded.objectValue == nil {
            throw EditorError.bodyNotObject(label)
        }
        return decoded
    }

    private static func jsonText(_ value: [String: JSONValue]) -> String {
        value.isEmpty ? "" : JSONValue.object(value).serialized(pretty: true)
    }
}
