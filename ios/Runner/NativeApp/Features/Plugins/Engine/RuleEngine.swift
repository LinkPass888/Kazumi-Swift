//
//  RuleEngine.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/rule_engine.dart：搜索 / 章节查询的统一入口，
//  负责选择 XPath 或 API 策略、把底层错误包装成 RuleError，并在失败响应其实是
//  反爬验证页时切换到验证码流程。
//

import Foundation

struct RuleEngine: Sendable {
    private let requestExecutor: any RuleRequestExecutor
    private let apiStrategy: ApiRuleStrategy
    private let xpathStrategy: XPathRuleStrategy
    private let logFailures: Bool

    init(
        requestExecutor: (any RuleRequestExecutor)? = nil,
        apiStrategy: ApiRuleStrategy = ApiRuleStrategy(),
        xpathStrategy: XPathRuleStrategy = XPathRuleStrategy(),
        logFailures: Bool = true
    ) {
        // 协议本身没有 default 实现，缺省时显式退回共享的 HTTP 客户端。
        self.requestExecutor = requestExecutor ?? RuleHTTPClient.shared
        self.apiStrategy = apiStrategy
        self.xpathStrategy = xpathStrategy
        self.logFailures = logFailures
    }

    func search(
        _ config: RuleExecutionConfig,
        keyword: String,
        cancelToken: RuleCancelToken? = nil
    ) async throws -> RuleSearchTrace {
        let request: PreparedRuleRequest
        do {
            request = config.searchMode == .api
                ? try apiStrategy.prepareRequest(config.searchApiConfig.request, variables: ["keyword": .string(keyword)])
                : try xpathStrategy.prepareSearchRequest(config, keyword: keyword)
        } catch {
            logFailure(config, "search request preparation", error)
            throw RuleError.searchFailed(plugin: config.pluginName, cause: describe(error))
        }

        let raw: String
        var failureBody: String?
        do {
            raw = try await execute(
                request,
                config: config,
                phase: "search request",
                cancelToken: cancelToken,
                wrap: { error in
                    if let networkError = error as? NetworkError,
                       case .badResponse(_, let body, _) = networkError {
                        failureBody = body
                    }
                    return RuleError.searchFailed(plugin: config.pluginName, cause: describe(error))
                }
            )
        } catch let error as RuleError {
            if isCaptchaChallengeResponse(error, body: failureBody, config: config) {
                throw RuleError.captchaRequired(plugin: config.pluginName)
            }
            throw error
        }

        do {
            let parsed = config.searchMode == .api
                ? try apiStrategy.parseSearch(raw, config: config.searchApiConfig)
                : try xpathStrategy.parseSearch(raw, config: config)
            if parsed.items.isEmpty {
                throw RuleError.noResult(plugin: config.pluginName)
            }
            logDiagnostics(config, "search", parsed.diagnostics)
            return RuleSearchTrace(
                rawResponse: raw,
                response: PluginSearchResponse(pluginName: config.pluginName, data: parsed.items),
                matchedFragments: parsed.matchedFragments,
                diagnostics: parsed.diagnostics
            )
        } catch let error as RuleError {
            throw error
        } catch {
            if isCancellation(error) { throw error }
            logFailure(config, "search response parsing", error)
            throw RuleError.searchFailed(plugin: config.pluginName, cause: describe(error))
        }
    }

    /// 解析验证码 WebView 抓到的 HTML 作为搜索结果，省掉验证后的一轮网络请求。
    /// 不适用（API / POST 规则）或无法解析时返回 nil，调用方回退到重新搜索。
    func tryParseHarvestedSearch(_ config: RuleExecutionConfig, raw: String) -> PluginSearchResponse? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if config.searchMode == .api || config.usePost { return nil }
        do {
            let parsed = try xpathStrategy.parseSearch(raw, config: config)
            if parsed.items.isEmpty { return nil }
            logDiagnostics(config, "harvested search", parsed.diagnostics)
            return PluginSearchResponse(pluginName: config.pluginName, data: parsed.items)
        } catch {
            if logFailures {
                KazumiLog.plugin.info(
                    "Plugin: \(config.pluginName, privacy: .public) harvested page not parseable, falling back to re-search"
                )
            }
            return nil
        }
    }

    func queryChapters(
        _ config: RuleExecutionConfig,
        source: String,
        cancelToken: RuleCancelToken? = nil
    ) async throws -> RuleChapterTrace {
        let request: PreparedRuleRequest
        do {
            request = config.chapterMode == .api
                ? try apiStrategy.prepareRequest(config.chapterApiConfig.request, variables: ["source": .string(source)])
                : try xpathStrategy.prepareChapterRequest(config, source: source)
        } catch {
            logFailure(config, "chapter request preparation", error)
            throw RuleError.chapterFailed(plugin: config.pluginName, cause: describe(error))
        }

        let raw = try await execute(
            request,
            config: config,
            phase: "chapter request",
            cancelToken: cancelToken,
            wrap: { RuleError.chapterFailed(plugin: config.pluginName, cause: describe($0)) }
        )

        do {
            let parsed = config.chapterMode == .api
                ? try apiStrategy.parseChapters(
                    raw,
                    config: config.chapterApiConfig,
                    source: source,
                    baseUrl: config.baseUrl
                )
                : try xpathStrategy.parseChapters(raw, config: config)
            if parsed.roads.isEmpty {
                // 上屏只说「没能加载」，这里把接口到底回了什么留下痕迹，方便查。
                if logFailures {
                    KazumiLog.plugin.warning(
                        "Plugin: \(config.pluginName, privacy: .public) chapter parsed to 0 roads, raw \(raw.count, privacy: .public) bytes, source \(source, privacy: .public)"
                    )
                }
                throw RuleError.chapterFailed(plugin: config.pluginName, cause: nil)
            }
            logDiagnostics(config, "chapter", parsed.diagnostics)
            return RuleChapterTrace(
                rawResponse: raw,
                roads: parsed.roads,
                diagnostics: parsed.diagnostics
            )
        } catch let error as RuleError {
            throw error
        } catch {
            if isCancellation(error) { throw error }
            logFailure(config, "chapter response parsing", error)
            throw RuleError.chapterFailed(plugin: config.pluginName, cause: describe(error))
        }
    }

    // MARK: - Internals

    private func execute(
        _ request: PreparedRuleRequest,
        config: RuleExecutionConfig,
        phase: String,
        cancelToken: RuleCancelToken?,
        wrap: (Error) -> RuleError
    ) async throws -> String {
        if let cancelToken, cancelToken.isCancelled { throw NetworkError.cancelled }
        do {
            return try await requestExecutor.execute(request, config: config)
        } catch {
            if isCancellation(error) { throw error }
            logFailure(config, phase, error)
            throw wrap(error)
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkError else { return false }
        return networkError.isCancellation
    }

    /// Dio 在 2xx 之外直接抛错，受保护站点常用 403/429/503 返回验证页，
    /// 因此复用配置好的验证码检测器检查响应体，命中则交给验证码流程。
    ///
    /// 注意：`searchFailed` 的 `cause` 在 Swift 侧是 `String?`（由 `describe(_:)` 生成），
    /// 不像 Dart 那样保留原始异常对象，所以这里只能对文本做检测；
    /// 文本为空说明没有可判定内容，直接放弃。
    private func isCaptchaChallengeResponse(_ error: RuleError, body: String?, config: RuleExecutionConfig) -> Bool {
        guard config.searchMode == .xpath, config.antiCrawlerConfig.enabled else { return false }
        guard case .searchFailed = error, let body else { return false }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return xpathStrategy.detectsCaptchaChallenge(body, config: config.antiCrawlerConfig)
    }

    /// 即使规则整体成功，也把被跳过的节点写入日志，便于排查结果缺失。
    private func logDiagnostics(_ config: RuleExecutionConfig, _ phase: String, _ diagnostics: [String]) {
        guard logFailures, !diagnostics.isEmpty else { return }
        let preview = diagnostics.prefix(3).joined(separator: "; ")
        KazumiLog.plugin.warning(
            "Plugin: \(config.pluginName, privacy: .public) \(phase, privacy: .public) skipped \(diagnostics.count) node(s): \(preview, privacy: .public)"
        )
    }

    private func logFailure(_ config: RuleExecutionConfig, _ phase: String, _ error: Error) {
        guard logFailures else { return }
        KazumiLog.plugin.warning(
            "Plugin: \(config.pluginName, privacy: .public) \(phase, privacy: .public) failed: \(describe(error), privacy: .public)"
        )
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
