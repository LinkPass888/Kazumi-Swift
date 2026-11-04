//
//  RuleExecutionConfig.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/rule_engine_models.dart。
//  注意：播放使用的 UA/Referer 刻意不进入执行配置，API 请求只使用规则自带静态头。
//

import Foundation

/// 规则运行时的不可变快照。
struct RuleExecutionConfig: Sendable {
    let pluginName: String
    let baseUrl: String
    let usePost: Bool
    let searchMode: RuleMode
    let chapterMode: RuleMode
    let searchUrl: String
    let searchList: String
    let searchName: String
    let searchResult: String
    let chapterRoads: String
    let chapterResult: String
    let searchApiConfig: ApiSearchConfig
    let chapterApiConfig: ApiChapterConfig
    let antiCrawlerConfig: AntiCrawlerConfig

    init(plugin: Plugin) {
        self.pluginName = plugin.name
        self.baseUrl = plugin.baseUrl
        self.usePost = plugin.usePost
        self.searchMode = plugin.searchMode
        self.chapterMode = plugin.chapterMode
        self.searchUrl = plugin.searchURL
        self.searchList = plugin.searchList
        self.searchName = plugin.searchName
        self.searchResult = plugin.searchResult
        self.chapterRoads = plugin.chapterRoads
        self.chapterResult = plugin.chapterResult
        self.searchApiConfig = plugin.searchApiConfig
        self.chapterApiConfig = plugin.chapterApiConfig
        self.antiCrawlerConfig = plugin.antiCrawlerConfig
    }
}

/// 策略产出的、尚未发出的请求。
struct PreparedRuleRequest: Sendable {
    var method: String
    var url: String
    var headers: [String: JSONValue]
    var query: [String: JSONValue]
    var bodyType: ApiBodyType
    var body: JSONValue?

    /// 是否附带已存储的插件 Cookie：历史上只有搜索与 API 请求携带，
    /// XPath 章节请求不携带。
    var includeCookies: Bool

    init(
        method: String,
        url: String,
        headers: [String: JSONValue] = [:],
        query: [String: JSONValue] = [:],
        bodyType: ApiBodyType = .none,
        body: JSONValue? = nil,
        includeCookies: Bool = false
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.query = query
        self.bodyType = bodyType
        self.body = body
        self.includeCookies = includeCookies
    }
}

struct RuleSearchParseResult: Sendable {
    var items: [SearchItem]
    var matchedFragments: [String] = []
    var diagnostics: [String] = []
}

struct RuleChapterParseResult: Sendable {
    var roads: [Road]
    var diagnostics: [String] = []
}

struct RuleSearchTrace: Sendable {
    var rawResponse: String
    var response: PluginSearchResponse
    var matchedFragments: [String]
    var diagnostics: [String]
}

struct RuleChapterTrace: Sendable {
    var rawResponse: String
    var roads: [Road]
    var diagnostics: [String]
}

/// 对应 Dio 的 CancelToken：协作式取消，检查点位于请求前后。
final class RuleCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        if isCancelled { throw NetworkError.cancelled }
    }
}

/// 规则请求执行器抽象（对应 RuleRequestExecutor）。
protocol RuleRequestExecutor: Sendable {
    func execute(_ request: PreparedRuleRequest, config: RuleExecutionConfig) async throws -> String
}
