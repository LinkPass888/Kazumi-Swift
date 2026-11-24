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
    private var activeSearchTask: Task<Void, Never>?

    private struct SourceSearchTimeoutError: Error {}

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
    /// 全源检索并发上限：避免安装数十条规则时瞬时发起连接风暴与主线程刷新抖动。
    private static let maxConcurrentSearches = 6

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
    func applyHarvestedSearchResult(pluginName: String, html: String) async -> Bool {
        guard let plugin = plugins.plugin(named: pluginName) else { return false }
        let config = RuleExecutionConfig(plugin: plugin)
        guard let result = await engine.tryParseHarvestedSearch(config, raw: html) else { return false }
        responses.removeAll { $0.pluginName == pluginName }
        statuses[pluginName] = .success
        plugins.validityTracker.markSearchValid(pluginName)
        responses.append(result)
        return true
    }

    func queryAllSource(_ keyword: String) async {
        activeSearchTask?.cancel()
        activeSearchTask = nil
        searchGeneration += 1
        let generation = searchGeneration
        responses.removeAll()
        statuses.removeAll()
        resetCancelTokenIfNeeded()
        let token = cancelToken
        let snapshot = plugins.pluginList
        for plugin in snapshot {
            statuses[plugin.name] = .pending
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var nextIndex = 0
                var inFlight = 0

                while nextIndex < snapshot.count,
                      inFlight < Self.maxConcurrentSearches,
                      !Task.isCancelled,
                      !token.isCancelled,
                      generation == self.searchGeneration {
                    let plugin = snapshot[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await self.queryPlugin(plugin, keyword: keyword, generation: generation)
                    }
                }

                while inFlight > 0 {
                    await group.next()
                    inFlight -= 1
                    if nextIndex < snapshot.count,
                       !Task.isCancelled,
                       !token.isCancelled,
                       generation == self.searchGeneration {
                        let plugin = snapshot[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            await self.queryPlugin(plugin, keyword: keyword, generation: generation)
                        }
                    }
                }
            }
            if self.searchGeneration == generation {
                self.activeSearchTask = nil
            }
        }
        activeSearchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
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
        let engine = self.engine
        let config = RuleExecutionConfig(plugin: plugin)
        let token = self.cancelToken
        let timeout = Self.sourceTimeout
        do {
            // 与单源超时竞速：任一先返回立刻 cancelAll，确保超时立刻取消底层 URLSession 并释放并发槽位。
            let trace = try await withThrowingTaskGroup(of: RuleSearchTrace.self) { group in
                group.addTask {
                    try await engine.search(config, keyword: keyword, cancelToken: token)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw SourceSearchTimeoutError()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
            guard !Task.isCancelled, owner.isActive(session) else { return }
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
        } catch is SourceSearchTimeoutError {
            guard owner.isActive(session) else { return }
            if let generation, generation != searchGeneration { return }
            KazumiLog.plugin.warning(
                "PluginSearchService: \(plugin.name, privacy: .public) timed out after \(Int(Self.sourceTimeout))s"
            )
            statuses[plugin.name] = .error
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, owner.isActive(session) else { return }
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
        activeSearchTask?.cancel()
        activeSearchTask = nil
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.applyHarvestedSearchResult(pluginName: pluginName, html: html) { return }
                // 收割页解析不出结果（仍是挑战页或重定向页）时回退到重新搜索。
                await self.querySource(keyword, pluginName: pluginName)
            }
        }
        return flow
    }

    /// 需要验证的规则名称（供界面决定是否弹出验证面板）。
    var captchaPluginNames: [String] {
        statuses.compactMap { name, status in status == .captcha ? name : nil }
    }
}
