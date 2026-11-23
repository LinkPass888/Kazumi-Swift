//
//  BangumiProgress.swift
//  Kazumi
//
//  「自动标记看过」的消费端：一集看到 90% 就在 Bangumi 上把它标成看过。
//  对应 lib/services/bangumi_progress/bangumi_progress_service.dart。
//
//  为什么要有这一层：设置里那个开关没有别的读者，播放器不该自己拼接口，
//  也不该自己记住「这集标过了」——进度回调每秒都会来，不记住就会刷出一串重复请求。
//
//  与「自动同步追番」的关系：那是搬收藏状态，这是搬单集进度，两者互不依赖，
//  各自的开关管各自的活。
//
//  离线补标记：原版把没发出去的集数存进设置项 `bangumiProgressQueue`，
//  回到前台再补一次。这里照做（LP 4744「参考 main 的做法」）——不然在车上、
//  在地铁里看完的那一集，永远没人补。
//

import Foundation
import Observation

@MainActor
@Observable
final class BangumiProgressService {
    private let settings: SettingsStore

    /// 这次运行里已经处理过的「番剧:集数」。只记内存：重开 App 再标一次也不会错，
    /// 服务端同状态重复写是幂等的。
    private var handled = Set<String>()

    /// 标记提示信息（成功或失败提示）。
    struct MarkedNotice: Equatable {
        let message: String
        let serial: Int
    }

    private(set) var markedNotice: MarkedNotice?
    private(set) var failureNotice: MarkedNotice?
    private var markedNoticeSerial = 0

    /// 记一句「刚标记了」并换一个序号，保证消费端每次都算新值。
    private func noteMarked(episodeNumber: Int? = nil) {
        markedNoticeSerial += 1
        let text = episodeNumber.map { String(localized: "已标记第 \($0) 集看过") } ?? String(localized: "已标记本集看过")
        markedNotice = MarkedNotice(
            message: text,
            serial: markedNoticeSerial
        )
    }

    /// 记一句「标记失败」并换一个序号，供播放器 HUD 提示。
    private func noteFailure(_ message: String) {
        markedNoticeSerial += 1
        failureNotice = MarkedNotice(
            message: message,
            serial: markedNoticeSerial
        )
    }

    /// 番剧 → (集数 → Bangumi 单集 id)。同一次播放里会反复问进度，缓存一次省一批请求。
    private var episodeIndex: [Int: [Int: Int]] = [:]
    /// 串行化：上一集还在标，下一集不要抢在同一条队列前面。
    private var chain: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        // 回到前台补一次上次没发出去的标记（原版 `attachLifecycle`）。
        // 服务跟着 App 活一辈子，不需要注销这条观察。
        NotificationCenter.default.addObserver(
            forName: .kazumiAppDidBecomeActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    /// 开关是否生效：既要拨开，也要有令牌 —— 对应原版 enabled()。
    private var enabled: Bool {
        settings.bangumiAutoMarkWatched
            && !settings.bangumiAccessToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    /// 播放器每次进度回调都调用它；不到 90% 或没开开关时立刻返回。
    ///
    /// 两条下限照原版：时长不到 2 分钟的不算（预览、短片），位置不到 90% 的不算。
    func onPosition(
        subjectID: Int,
        episodeNumber: Int,
        position: Double,
        duration: Double
    ) {
        guard subjectID > 0, episodeNumber > 0 else { return }
        guard duration.isFinite, duration >= 120 else { return }
        guard position.isFinite, position >= duration * 0.9 else { return }
        guard enabled else { return }
        let key = "\(subjectID):\(episodeNumber)"
        guard handled.insert(key).inserted else { return }
        let previous = chain
        chain = Task { [weak self] in
            _ = await previous?.value
            _ = await self?.markOnce(subjectID: subjectID, episodeNumber: episodeNumber)
        }
    }

    /// 手动标记某集为已看（如在选集面板快捷标记）。
    func markManually(subjectID: Int, episodeNumber: Int) async {
        guard subjectID > 0, episodeNumber > 0 else { return }
        guard !settings.bangumiAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noteFailure(String(localized: "请先在设置中绑定 Bangumi 访问令牌"))
            return
        }
        _ = await markOnce(subjectID: subjectID, episodeNumber: episodeNumber)
    }

    /// 把队列里欠着的标记补一遍（回前台、以及手动调用时）。
    ///
    /// 一条一条来：补到一半被系统杀掉，队列里剩下的还在，下次接着补。
    func flush() {
        guard enabled else { return }
        let previous = chain
        chain = Task { [weak self] in
            _ = await previous?.value
            await self?.drainQueue()
        }
    }

    // MARK: - 标记

    private func drainQueue() async {
        let items = queuedItems
        guard !items.isEmpty else { return }
        for item in items {
            // 返回 false 表示这条已经了结（标上了，或者服务端说这集不存在），
            // 把它从队列里摘掉；还欠着的（网络失败）就留着。
            if !(await markOnce(subjectID: item.subjectID, episodeNumber: item.episodeNumber)) {
                dequeue(item)
            }
        }
    }

    /// 标一集。返回 true 表示「这集还欠着」，已经写进队列等下次补。
    private func markOnce(subjectID: Int, episodeNumber: Int) async -> Bool {
        let lookup = await resolveEpisodeID(subjectID: subjectID, episodeNumber: episodeNumber)
        let episodeID: Int
        switch lookup {
        case let .found(id):
            episodeID = id
        case .listUnavailable:
            // 列表拉不下来多半是网络：先欠着，回前台再试（原版 eps 为空也入队）。
            enqueue(subjectID: subjectID, episodeNumber: episodeNumber)
            noteFailure(String(localized: "获取 Bangumi 剧集失败，已加入稍后重试"))
            return true
        case .noSuchEpisode:
            // 服务端没有这一集（特别篇、未开播）：再试多少次也一样，丢掉。
            KazumiLog.network.notice(
                "Bangumi: \(subjectID, privacy: .public) 没有第 \(episodeNumber, privacy: .public) 集，跳过"
            )
            noteFailure(String(localized: "Bangumi 未找到第 \(episodeNumber) 集"))
            return false
        }

        let result = await BangumiAPI.markEpisodeWatched(episodeID: episodeID)
        switch result {
        case .ok:
            KazumiLog.network.notice(
                "Bangumi: 已标记看过 \(subjectID, privacy: .public) 第 \(episodeNumber, privacy: .public) 集"
            )
            noteMarked(episodeNumber: episodeNumber)
            return false
        case .unauthorized:
            // 令牌没了或过期：这次就算了，不要拿一个失效凭据反复重试。
            KazumiLog.network.error("Bangumi: 自动标记看过失败，令牌无效")
            noteFailure(String(localized: "Bangumi 标记看过失败：访问令牌已失效"))
            return false
        case .rejected:
            KazumiLog.network.error(
                "Bangumi: \(subjectID, privacy: .public) 第 \(episodeNumber, privacy: .public) 集在 Bangumi 上不存在，标记丢弃"
            )
            noteFailure(String(localized: "Bangumi 标记看过失败：单集不存在"))
            return false
        case .notCollected:
            // 这部番不在收藏里。Bangumi 的单集接口挂在 `/collections/{subject_id}/`
            // 下面，没收藏就是 400，标不了。
            KazumiLog.network.notice(
                "Bangumi: 该番未收藏，跳过本集标记（不改收藏状态）"
            )
            noteFailure(String(localized: "Bangumi 标记看过失败：请先将番剧加入收藏"))
            return false
        case let .failed(reason):
            KazumiLog.network.error(
                "Bangumi: 自动标记看过失败 \(subjectID, privacy: .public) 第 \(episodeNumber, privacy: .public) 集，进队列等下次补: \(reason)"
            )
            enqueue(subjectID: subjectID, episodeNumber: episodeNumber)
            noteFailure(String(localized: "Bangumi 标记第 \(episodeNumber) 集失败（\(reason)），已加入重试"))
            return true
        }
    }

    // MARK: - 集数 → 单集 id

    private enum EpisodeLookup {
        /// 找到了对应的 Bangumi 单集 id。
        case found(Int)
        /// 列表拉下来了，但没有这一集。
        case noSuchEpisode
        /// 列表没拉到（网络 / 接口失败），下次还能再试。
        case listUnavailable
    }

    /// 集数 → Bangumi 单集 id。
    ///
    /// 认集先用「当季话数」`ep`，再用绝对话数 `sort`，只看本篇（`type == 0`）——
    /// 原版 `bangumi_episode_matcher.dart` 的规矩。不能只看 `sort`：
    /// 第二季之后的 sort 接着上一季往下数，第三季第 1 集 sort 是 49，
    /// 拿播放器里的第 1 集去查 sort 永远查不到，标记就被当成「没有这一集」丢掉（LP 4744）。
    private func resolveEpisodeID(subjectID: Int, episodeNumber: Int) async -> EpisodeLookup {
        if let cached = episodeIndex[subjectID]?[episodeNumber] { return .found(cached) }
        let list = await BangumiAPI.episodes(subjectID: subjectID)
        guard !list.isEmpty else { return .listUnavailable }
        let mains = list.filter { $0.type == 0 }
        var index: [Int: Int] = [:]
        for episode in mains where episode.sort > 0 {
            index[Int(episode.sort)] = episode.id
        }
        for episode in mains where episode.ep > 0 {
            index[Int(episode.ep)] = episode.id
        }
        episodeIndex[subjectID] = index
        guard let id = index[episodeNumber] else { return .noSuchEpisode }
        return .found(id)
    }

    // MARK: - 待补队列（原版 bangumiProgressQueue）

    private struct QueueItem: Hashable {
        var subjectID: Int
        var episodeNumber: Int
    }

    /// 队列原文：`[{"s": 番剧 id, "e": 集数}, …]`，跟原版同一个形状。
    private var queuedItems: [QueueItem] {
        guard let data = settings.bangumiProgressQueue.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { item in
            guard let subject = item["s"] as? Int,
                  let episode = item["e"] as? Int,
                  subject > 0, episode > 0
            else { return nil }
            return QueueItem(subjectID: subject, episodeNumber: episode)
        }
    }

    private func writeQueue(_ items: [QueueItem]) {
        guard !items.isEmpty else {
            settings.bangumiProgressQueue = ""
            return
        }
        let raw = items.map { ["s": $0.subjectID, "e": $0.episodeNumber] }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let text = String(data: data, encoding: .utf8)
        else { return }
        settings.bangumiProgressQueue = text
    }

    private func enqueue(subjectID: Int, episodeNumber: Int) {
        var items = queuedItems
        let item = QueueItem(subjectID: subjectID, episodeNumber: episodeNumber)
        guard !items.contains(item) else { return }
        items.append(item)
        writeQueue(items)
    }

    private func dequeue(_ item: QueueItem) {
        var items = queuedItems
        items.removeAll { $0 == item }
        writeQueue(items)
    }
}
