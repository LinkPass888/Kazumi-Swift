//
//  PluginSearchService.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/plugin_search_service.dart 与 lib/utils/async_session.dart。
//
//  每条规则维护一个会话：同一规则的手动重搜（别名/手动关键词）会让仍在运行的
//  旧请求结果作废，避免旧结果覆盖新结果。
//

import Foundation
import Observation

/// 对应 AsyncSessionOwner / AsyncSession。
final class AsyncSessionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let token = UUID()
    private var version = 0
    private var isClosed = false

    struct Session: Sendable {
        let owner: UUID
        let version: Int
    }

    func begin() -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }
        version += 1
        return Session(owner: token, version: version)
    }

    func isActive(_ session: Session) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && session.owner == token && session.version == version
    }

    func cancel() {
        lock.lock()
        if !isClosed { version += 1 }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        version += 1
        lock.unlock()
    }
}

@MainActor
@Observable
final class PluginSearchService {
    private(set) var responses: [PluginSearchResponse] = []
    private(set) var statuses: [String: PluginSearchStatus] = [:]

    private let plugins: PluginsController
    private let engine: RuleEngine
    private var cancelToken = RuleCancelToken()
    private var querySessions: [String: AsyncSessionOwner] = [:]

    /// 整轮检索的代号。每开一轮加一，旧的轮次回来时只认代号、不写状态。
    ///
    /// 全量检索会先把 `responses` / `statuses` 整个清空再逐条填。面板开关得快时
    /// 两轮会重叠：后一轮清空时前一轮还在往回写，于是同一行一会儿「1 个结果」
    /// 一会儿「无结果」——看着像站点时好时坏，其实是两轮在自己踩自己。
    private var searchGeneration = 0

    /// 单个来源的看门狗：这么久还没结果就落到失败，让人能点「重试」。
    /// 规则里的站点常常干脆不回（超时、被墙、挑战页不返回），只靠 URLSession
    /// 的超时不够：它管的是「没数据流动」，挑战页/慢速回传可以一直吊着。
    private static let sourceTimeout: TimeInterval = 15

    init(plugins: PluginsController, engine: RuleEngine = RuleEngine()) {
        self.plugins = plugins
        self.engine = engine
    }

    func status(for pluginName: String) -> PluginSearchStatus? {
        statuses[pluginName]
    }

    func responses(for pluginName: String) -> [SearchItem] {
        responses.first { $0.pluginName == pluginName }?.data ?? []
    }

    func querySource(_ keyword: String, pluginName: String) async {
        guard let plugin = plugins.plugin(named: pluginName) else { return }
        resetCancelTokenIfNeeded()
        responses.removeAll { $0.pluginName == pluginName }
        statuses[pluginName] = .pending
        await queryPlugin(plugin, keyword: keyword)
    }

    /// 发布验证码 WebView 抓到的结果页，省掉一次网络往返。
    /// HTML 解析不出结果时返回 false，调用方回退到 querySource。
    func applyHarvestedSearchResult(pluginName: String, html: String) -> Bool {
        guard let plugin = plugins.plugin(named: pluginName) else { return false }
        let config = RuleExecutionConfig(plugin: plugin)
        guard let result = engine.tryParseHarvestedSearch(config, raw: html) else { return false }
        responses.removeAll { $0.pluginName == pluginName }
        statuses[pluginName] = .success
        plugins.validityTracker.markSearchValid(pluginName)
        responses.append(result)
        return true
    }

    func queryAllSource(_ keyword: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        responses.removeAll()
        statuses.removeAll()
        resetCancelTokenIfNeeded()
        let snapshot = plugins.pluginList
        for plugin in snapshot {
            statuses[plugin.name] = .pending
        }
        await withTaskGroup(of: Void.self) { group in
            for plugin in snapshot {
                // 子任务只捕获 Sendable 的 Plugin，主 actor 上的状态更新留在 queryPlugin 内完成。
                group.addTask {
                    await self.queryPlugin(plugin, keyword: keyword, generation: generation)
                }
            }
        }
    }

    /// `generation` 是发起这一轮时的整轮代号；为 nil 表示单条重搜，不受整轮换代影响。
    private func queryPlugin(_ plugin: Plugin, keyword: String, generation: Int? = nil) async {
        let owner = querySessions[plugin.name] ?? {
            let created = AsyncSessionOwner()
            querySessions[plugin.name] = created
            return created
        }()
        guard let session = owner.begin() else { return }
        // 看门狗：超时没结果就落到失败。请求本身不强杀——它回来时会被下面的
        // 会话校验丢掉，不会把「失败」又盖成结果。
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.sourceTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard owner.isActive(session), self.statuses[plugin.name] == .pending else { return }
            if let generation, generation != self.searchGeneration { return }
            KazumiLog.plugin.warning(
                "PluginSearchService: \(plugin.name, privacy: .public) timed out after \(Int(Self.sourceTimeout))s"
            )
            self.statuses[plugin.name] = .error
        }
        defer { watchdog.cancel() }
        do {
            let trace = try await engine.search(
                RuleExecutionConfig(plugin: plugin),
                keyword: keyword,
                cancelToken: cancelToken
            )
            guard owner.isActive(session) else { return }
            // 这一轮已经被更新的一轮顶掉了：结果只属于旧轮，不许写进现在的列表。
            if let generation, generation != searchGeneration { return }
            // 回话里一条都没有，就是「找不到」：状态字本来写的也是「无结果」，
            // 那就落到 .noResult，才能跟别的找不到一样给「使用别名」。
            if trace.response.data.isEmpty {
                statuses[plugin.name] = .noResult
            } else {
                statuses[plugin.name] = .success
                plugins.validityTracker.markSearchValid(plugin.name)
            }
            // 结果整体替换，避免手动重搜后出现重复条目。
            responses.removeAll { $0.pluginName == plugin.name }
            responses.append(trace.response)
        } catch {
            guard owner.isActive(session) else { return }
            if let generation, generation != searchGeneration { return }
            handleSearchError(plugin, error: error)
        }
    }

    private func handleSearchError(_ plugin: Plugin, error: Error) {
        switch error {
        case RuleError.captchaRequired(let name):
            KazumiLog.plugin.info("PluginSearchService: captcha required for \(name, privacy: .public)")
            statuses[name] = .captcha
        case RuleError.noResult(let name):
            KazumiLog.plugin.info("PluginSearchService: no results for \(name, privacy: .public)")
            statuses[name] = .noResult
        case RuleError.searchFailed(let name, _):
            KazumiLog.plugin.warning("PluginSearchService: search error for \(name, privacy: .public)")
            statuses[name] = .error
        default:
            KazumiLog.plugin.warning("PluginSearchService: search error for \(plugin.name, privacy: .public)")
            statuses[plugin.name] = .error
        }
    }

    func cancel() {
        searchGeneration += 1
        cancelToken.cancel()
        for owner in querySessions.values { owner.cancel() }
    }

    /// 上一轮被取消后，下一次检索要换一张新的取消牌，否则所有请求会在
    /// 起跑线上就判成已取消——旧实现的取消是一次性的、永久生效，关过一次
    /// 选源面板之后，再打开每一行都永远停在「检索中…」，点重试也没反应。
    private func resetCancelTokenIfNeeded() {
        guard cancelToken.isCancelled else { return }
        cancelToken = RuleCancelToken()
    }
}
// MARK: - 验证码接管

@MainActor
extension PluginSearchService {
    /// 当某条规则返回 `captchaRequired` 时创建验证流程；
    /// 验证成功会优先使用 WebView 收割到的页面，省掉一次网络往返。
    func makeCaptchaFlow(for pluginName: String, keyword: String) -> CaptchaFlow? {
        guard let plugin = plugins.plugin(named: pluginName) else { return nil }
        guard plugin.antiCrawlerConfig.enabled else { return nil }
        let flow = CaptchaFlow(plugin: plugin, keyword: keyword) { [weak self] html in
            guard let self else { return }
            if self.applyHarvestedSearchResult(pluginName: pluginName, html: html) { return }
            // 收割页解析不出结果（仍是挑战页或重定向页）时回退到重新搜索。
            Task { await self.querySource(keyword, pluginName: pluginName) }
        }
        return flow
    }

    /// 需要验证的规则名称（供界面决定是否弹出验证面板）。
    var captchaPluginNames: [String] {
        statuses.compactMap { name, status in status == .captcha ? name : nil }
    }
}
