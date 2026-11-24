//
//  DownloadCenter.swift
//  Kazumi
//
//  下载的中枢：排队、解析、下载、落盘、记录。
//
//  并行形状跟原版 `download_manager.dart` 对齐：
//    * 同时下载的**集数**由设置「同时下载集数」决定（1–5，默认 2）；
//    * 一集内部的分片并发由「每集分片并发」决定（1–10，默认 3）。
//  两个数都是设置项，改了当场生效，不用重启。
//
//  每集分两步：先在隐藏网页里嗅真实地址（`EpisodeMediaResolver`），再把地址交给
//  `DownloadEngine` 落盘。嗅地址很重（一个 WebView 一个进程），由独立异步限流器
//  限制同时最多 2 个并发解析，与集数并发解耦，防止低内存机型触发 Jetsam。
//
//  记录存 Application Support/downloads.json；文件落在下载目录
//  `<番剧ID>-<规则名>/` 下，离线播放直接喂本地播放列表。
//

import Foundation
import Observation
import UIKit

private actor DownloadPersistenceActor {
    func writeSnapshot(_ snapshot: [DownloadRecord], to storeURL: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// 独立的异步并发限流器：限制同时活跃的隐藏 `WKWebView` 解析数量（最多 2 个），
/// 与 `downloadParallelEpisodes` 解耦，防止低内存机型因过多 WebContent 进程触发 Jetsam。
@MainActor
private final class ResolveConcurrencyLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let cancelToken: UUID
        let cancellation: CancellationFlag
    }

    private let maxConcurrent: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire(cancellation: CancellationFlag) async throws {
        if cancellation.isCancelled || Task.isCancelled {
            throw DownloadError.cancelled
        }
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellation.isCancelled || Task.isCancelled {
                    continuation.resume(throwing: DownloadError.cancelled)
                    return
                }
                if activeCount < maxConcurrent {
                    activeCount += 1
                    continuation.resume()
                    return
                }
                let token = cancellation.addCancelHandler { [weak self] in
                    Task { @MainActor in
                        self?.cancelWaiter(id: waiterID)
                    }
                }
                waiters.append(Waiter(
                    id: waiterID,
                    continuation: continuation,
                    cancelToken: token,
                    cancellation: cancellation
                ))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.cancellation.removeCancelHandler(next.cancelToken)
            if next.cancellation.isCancelled {
                next.continuation.resume(throwing: DownloadError.cancelled)
                continue
            }
            // 名额直接交接给下一个等待者，`activeCount` 保持不变。
            next.continuation.resume()
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.cancellation.removeCancelHandler(waiter.cancelToken)
        waiter.continuation.resume(throwing: DownloadError.cancelled)
    }
}

@MainActor
@Observable
final class DownloadCenter {
    /// 单集实时下载进度状态：独立于值类型 `records`，仅由对应行视图观察，
    /// 避免单集高频进度刷新触发整页重绘。
    @MainActor
    @Observable
    final class EpisodeProgressState {
        var progress: Double
        var downloadedBytes: Int64
        var totalBytes: Int64

        init(progress: Double = 0, downloadedBytes: Int64 = 0, totalBytes: Int64 = 0) {
            self.progress = progress
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
        }
    }

    /// 所有记录，最近下的在前面。
    private(set) var records: [DownloadRecord] = []

    /// 正在跑的那几集（界面画「下载中」用）。
    private(set) var activeNumbers: [String: Set<Int>] = [:]

    /// 最近一次失败的一句话，给界面弹一下（LP 5115：失败要说，不能只画个红点）。
    /// 界面拿来当 toast 显示完就把 `notice` 清掉，所以它不会自己一直在。
    var failureNotice: String?

    @ObservationIgnored private var progressStates: [String: EpisodeProgressState] = [:]
    @ObservationIgnored private let persistenceActor = DownloadPersistenceActor()
    @ObservationIgnored private let engine = DownloadEngine()

    private let resolver = EpisodeMediaResolver()
    @ObservationIgnored private let resolveLimiter = ResolveConcurrencyLimiter(maxConcurrent: 2)
    private let directory: DownloadDirectoryStore
    private let plugins: PluginsController?
    private let settings: SettingsStore

    /// 排队等待的集。
    private var queue: [QueueItem] = []
    /// 正在跑的集数。不能拿 `workers.filter { !$0.isCancelled }` 数：
    /// 正常跑完的 Task 它 `isCancelled` 也是 false，会把已结束的算成在跑，队列就卡住。
    private var activeEpisodeCount = 0
    /// 每一集自己的取消标记。
    private var cancellationFlags: [String: CancellationFlag] = [:]
    /// 用户按过取消、还没轮到的那几集。
    private var cancelledBeforeStart = Set<String>()
    /// 后台任务保活标识：有活跃下载时向系统申请后台时间窗，配合后台 URLSession 保障 HLS 分片调度与落盘。
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// 下载进度节流落盘时间戳：防止只存内存导致强杀 App 后重启显示旧进度。
    private var lastProgressPersistUptime: TimeInterval = 0
    /// 监听切出前台（如呼出多任务准备划掉 App），立即把最新下载进度刷入磁盘。
    @ObservationIgnored private var resignActiveObserver: NSObjectProtocol?

    private struct QueueItem: Equatable, Sendable, Identifiable {
        var recordKey: String
        var episodeNumber: Int

        var id: String { "\(recordKey)#\(episodeNumber)" }
    }

    init(directory: DownloadDirectoryStore, plugins: PluginsController?, settings: SettingsStore) {
        self.directory = directory
        self.plugins = plugins
        self.settings = settings
        load()
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushPersistIfDownloading()
            }
        }
    }

    // MARK: - 查询

    func episode(recordKey: String, number: Int) -> DownloadEpisode? {
        records.first { $0.id == recordKey }?.episodes.first { $0.number == number }
    }

    func record(bangumiID: Int, pluginName: String, road: Int) -> DownloadRecord? {
        records.first { $0.id == DownloadRecord.key(bangumiID: bangumiID, pluginName: pluginName, road: road) }
    }

    /// 已下载完的集数（格子右上角那颗勾）。
    func downloadedNumbers(recordKey: String) -> Set<Int> {
        guard let record = records.first(where: { $0.id == recordKey }) else { return [] }
        return Set(record.episodes.filter(\.isPlayableOffline).map(\.number))
    }

    /// 正在下的集数。
    func downloadingNumbers(recordKey: String) -> Set<Int> {
        activeNumbers[recordKey] ?? []
    }

    /// 在排队、还没开始的集数（格子右上角那颗钟）。
    func queuedNumbers(recordKey: String) -> Set<Int> {
        Set(queue.filter { $0.recordKey == recordKey }.map(\.episodeNumber))
    }

    /// 一次性按记录分组统计排队中的集号，避免在外层循环里重复扫描整个队列。
    private func queuedNumbersByRecord() -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for item in queue {
            result[item.recordKey, default: []].insert(item.episodeNumber)
        }
        return result
    }

    nonisolated static func episodeKey(recordKey: String, number: Int) -> String {
        "\(recordKey)#\(number)"
    }

    /// 取某一集独立的实时进度观察对象（供 `DownloadEpisodeRowView` 精准订阅）。
    func progressState(recordKey: String, episode: DownloadEpisode) -> EpisodeProgressState {
        let key = Self.episodeKey(recordKey: recordKey, number: episode.number)
        if let existing = progressStates[key] {
            return existing
        }
        let state = EpisodeProgressState(
            progress: episode.progress,
            downloadedBytes: episode.downloadedBytes,
            totalBytes: episode.totalBytes
        )
        progressStates[key] = state
        return state
    }

    /// 一集的显示状态，界面按这个画格子。
    func liteStatus(recordKey: String, number: Int) -> DownloadLiteStatus {
        if let episode = episode(recordKey: recordKey, number: number) {
            if episode.isPlayableOffline { return .downloaded }
            if episode.status == .failed { return .failed }
            // 记录说下完、文件却不在：当没下过，让格子回到初始样子、允许重下。
            if episode.status == .completed && episode.fileName == nil { return .normal }
            // LP 5193：只要加进下载就给「在下载」那个符号，不管是在下、排队还是暂停。
            let key = Self.episodeKey(recordKey: recordKey, number: number)
            let liveProgress = progressStates[key]?.progress ?? episode.progress
            return .downloading(liveProgress)
        }
        // 还在队列里没建记录的同理。
        if queuedNumbers(recordKey: recordKey).contains(number) { return .downloading(0) }
        return .normal
    }

    // MARK: - 加入 / 取消 / 删除

    /// 加入下载。已经在队列或已下完的会跳过。
    func enqueue(
        bangumiID: Int,
        title: String,
        coverURL: String,
        pluginName: String,
        road: Int,
        itemSource: String = "",
        episodes: [(number: Int, title: String, pageURL: String)]
    ) {
        guard !episodes.isEmpty else { return }
        let key = DownloadRecord.key(bangumiID: bangumiID, pluginName: pluginName, road: road)
        var record = records.first { $0.id == key } ?? DownloadRecord(
            bangumiID: bangumiID,
            title: title,
            coverURL: coverURL,
            pluginName: pluginName,
            road: road,
            episodes: [],
            createdAt: Date()
        )

        // 条目身份（接口模式当 vod_id）：老记录里没有，这次入队能拿到就补上，
        // 回放时才不用拿剧集地址去凑（LP 5508）。
        if !itemSource.isEmpty { record.itemSource = itemSource }

        var queued = queuedNumbers(recordKey: key)
        var added: [QueueItem] = []
        for item in episodes {
            if let index = record.episodes.firstIndex(where: { $0.number == item.number }) {
                let existing = record.episodes[index]
                // 已下完、正在下、已经在排队的，不重复加；失败过的允许重来。
                if existing.isPlayableOffline || existing.status.isActive { continue }
                if queued.contains(item.number) { continue }
                // 暂停/取消过的集重新入队时，要把「取消之后才轮到」的标记清掉：
                // 不清的话 pump() 出队时会把它当已取消跳过，界面永远停在排队中。
                cancelledBeforeStart.remove("\(key)#\(item.number)")
                if existing.status != .paused {
                    record.episodes[index].progress = 0
                    record.episodes[index].downloadedBytes = 0
                    record.episodes[index].totalBytes = 0
                    syncProgressState(recordKey: key, number: item.number, progress: 0, downloadedBytes: 0, totalBytes: 0)
                }
                record.episodes[index].status = .pending
                record.episodes[index].errorMessage = nil
            } else {
                if queued.contains(item.number) { continue }
                record.episodes.append(DownloadEpisode(
                    number: item.number,
                    title: item.title,
                    pageURL: item.pageURL,
                    status: .pending
                ))
            }
            queued.insert(item.number)
            added.append(QueueItem(recordKey: key, episodeNumber: item.number))
        }

        guard !added.isEmpty else { return }
        record.episodes.sort { $0.number < $1.number }
        upsert(record)
        queue.append(contentsOf: added)
        KazumiLogBuffer.network("加入下载 \(added.count) 集（\(pluginName) 线路 \(road)）")
        persist()
        pump()
    }

    /// 是否存在可开始或恢复的下载任务（已暂停、失败、丢失文件或尚未激活的排队项）。
    var hasStartableEpisodes: Bool {
        let queuedByRecord = queuedNumbersByRecord()
        for record in records {
            let active = activeNumbers[record.id] ?? []
            let queued = queuedByRecord[record.id] ?? []
            for episode in record.episodes {
                switch episode.status {
                case .paused, .failed:
                    return true
                case .completed where episode.fileName == nil:
                    return true
                case .pending where !active.contains(episode.number) && !queued.contains(episode.number):
                    return true
                default:
                    break
                }
            }
        }
        return false
    }

    /// 是否存在正在进行或排队中的下载任务（供「全部暂停」判可用状态）。
    var hasActiveEpisodes: Bool {
        if !queue.isEmpty { return true }
        return records.contains { record in
            record.episodes.contains { $0.status.isActive }
        }
    }

    /// 全部开始：恢复并排队所有已暂停、失败或等待中的下载任务。
    func startAll() {
        var didChange = false
        let queuedByRecord = queuedNumbersByRecord()
        for record in records {
            let active = activeNumbers[record.id] ?? []
            let queued = queuedByRecord[record.id] ?? []
            var toEnqueue: [(number: Int, title: String, pageURL: String)] = []

            for episode in record.episodes {
                switch episode.status {
                case .paused, .failed:
                    toEnqueue.append((episode.number, episode.title, episode.pageURL))
                case .completed where episode.fileName == nil:
                    toEnqueue.append((episode.number, episode.title, episode.pageURL))
                case .pending where !active.contains(episode.number) && !queued.contains(episode.number):
                    let item = QueueItem(recordKey: record.id, episodeNumber: episode.number)
                    cancelledBeforeStart.remove(item.id)
                    queue.append(item)
                    didChange = true
                default:
                    break
                }
            }

            if !toEnqueue.isEmpty {
                enqueue(
                    bangumiID: record.bangumiID,
                    title: record.title,
                    coverURL: record.coverURL,
                    pluginName: record.pluginName,
                    road: record.road,
                    itemSource: record.itemSource,
                    episodes: toEnqueue
                )
            }
        }
        if didChange {
            persist()
        }
        pump()
    }

    /// 全部暂停：清空等待队列并暂停所有正在解析或下载中的任务（不触发队列补位）。
    func pauseAll() {
        for item in queue {
            cancelledBeforeStart.insert(item.id)
        }
        queue.removeAll()

        for flag in cancellationFlags.values {
            flag.cancel()
        }

        var modified = false
        for recordIndex in records.indices {
            let recordKey = records[recordIndex].id
            var episodes = records[recordIndex].episodes
            var recordChanged = false
            for index in episodes.indices where episodes[index].status.isActive {
                syncProgressToEpisode(&episodes[index], recordKey: recordKey)
                episodes[index].status = .paused
                recordChanged = true
            }
            if recordChanged {
                records[recordIndex].episodes = episodes
                modified = true
            }
        }
        if modified {
            persist()
        }
    }

    /// 取消。正在下的会停掉，排队的直接拿掉；已下完的不动。
    func cancel(recordKey: String, numbers: [Int]) {
        let targets = Set(numbers)
        for item in queue where item.recordKey == recordKey && targets.contains(item.episodeNumber) {
            cancelledBeforeStart.insert(item.id)
        }
        queue.removeAll { $0.recordKey == recordKey && targets.contains($0.episodeNumber) }

        for number in targets {
            let id = "\(recordKey)#\(number)"
            cancellationFlags[id]?.cancel()
        }

        updateMany(recordKey: recordKey, numbers: targets) { episodes, number in
            guard let index = episodes.firstIndex(where: { $0.number == number }) else { return }
            if episodes[index].status.isActive {
                syncProgressToEpisode(&episodes[index], recordKey: recordKey)
                episodes[index].status = .paused
            }
        }
        persist()
        pump()
    }

    /// 清掉某一部的失败痕迹（LP 5115：重新拉一遍剧集列表就该没了）。
    /// 失败的那几集根本不存在可播的文件，直接从记录里描掉，格子回到「没下过」。
    func clearFailures(recordKey: String) {
        guard let index = records.firstIndex(where: { $0.id == recordKey }) else { return }
        let failedNumbers = Set(records[index].episodes.filter { $0.status == .failed }.map(\.number))
        guard !failedNumbers.isEmpty else { return }
        records[index].episodes.removeAll { $0.status == .failed }
        removeProgressStates(recordKey: recordKey, numbers: failedNumbers)
        // 一集都没剩就别留个空壳。
        if records[index].episodes.isEmpty {
            records.remove(at: index)
        }
        persist()
    }

    /// 删掉一份记录连同它的文件：先更新内存并持久化，再把文件删除丢到后台执行。
    func removeRecord(_ record: DownloadRecord) {
        cancel(recordKey: record.id, numbers: record.episodes.map(\.number))
        let foldersToRemove = recordFolders(for: record).filter {
            !isFolderReferenced($0, excluding: record.id)
        }
        records.removeAll { $0.id == record.id }
        activeNumbers[record.id] = nil
        removeProgressStates(recordKey: record.id)
        persist()

        if !foldersToRemove.isEmpty {
            Task.detached(priority: .utility) {
                for folder in foldersToRemove {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }

    /// 删掉某一集。
    func removeEpisode(recordKey: String, number: Int) {
        removeEpisodes(recordKey: recordKey, numbers: [number])
    }

    /// 清掉全部离线下载（设置页那颗红色按钮用）：记录和文件一起删。
    func removeAllRecords() {
        let keys = records.map(\.id)
        for key in keys {
            if let record = records.first(where: { $0.id == key }) {
                removeRecord(record)
            }
        }
        records.removeAll()
        activeNumbers.removeAll()
        cancelledBeforeStart.removeAll()
        progressStates.removeAll()
        persist()
    }

    /// 离线下载总共占了多少字节（文件真的在盘上的才算），在后台线程枚举文件大小。
    func totalBytes() async -> Int64 {
        var seen = Set<String>()
        let uniqueFolders = records
            .flatMap { recordFolders(for: $0) }
            .filter { seen.insert($0.path).inserted }
        return await Task.detached(priority: .utility) {
            var total: Int64 = 0
            for folder in uniqueFolders {
                let url = URL(filePath: folder.path)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true,
                      let files = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: [.skipsHiddenFiles]
                      )
                else { continue }
                for file in files {
                    guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                    total += Int64(size)
                }
            }
            return total
        }.value
    }

    /// 一次删多集（多选删除用）：先更新内存并持久化，再把文件删除丢到后台执行。
    func removeEpisodes(recordKey: String, numbers: [Int]) {
        guard let record = records.first(where: { $0.id == recordKey }), !numbers.isEmpty else { return }
        let targetSet = Set(numbers)
        let targets = record.episodes.filter { targetSet.contains($0.number) }
        let deletionTasks: [(folders: [URL], fileName: String?, number: Int)] = targets.map { episode in
            (folders: folders(for: record, episode: episode), fileName: episode.fileName, number: episode.number)
        }

        cancel(recordKey: recordKey, numbers: numbers)
        updateMany(recordKey: recordKey, numbers: targetSet, persistNow: false) { episodes, number in
            episodes.removeAll { $0.number == number }
        }
        removeProgressStates(recordKey: recordKey, numbers: targetSet)

        // 集全删光了就整条记录一起走（LP 5482）：不然下载管理里留一个空番剧名，
        // 点进去什么都没有，删也删不掉。
        if let updated = records.first(where: { $0.id == recordKey }), updated.episodes.isEmpty {
            // `removeRecord` 自己会停任务、删文件夹、落盘。
            removeRecord(updated)
        } else {
            persist()
        }

        if !deletionTasks.isEmpty {
            Task.detached(priority: .utility) {
                var listings: [String: [URL]] = [:]
                for task in deletionTasks {
                    for folder in task.folders {
                        let items: [URL]
                        if let cached = listings[folder.path] {
                            items = cached
                        } else {
                            items = (try? FileManager.default.contentsOfDirectory(
                                at: folder,
                                includingPropertiesForKeys: nil
                            )) ?? []
                            listings[folder.path] = items
                        }
                        if let file = task.fileName {
                            // 分片一起删：本地播放列表指向它们，留下就是垃圾。
                            try? FileManager.default.removeItem(at: folder.appending(path: file))
                        }
                        let danmakuURL = folder.appending(path: "ep-\(task.number).danmaku.json")
                        try? FileManager.default.removeItem(at: danmakuURL)
                        Self.removeSegments(in: folder, prefix: "ep-\(task.number)", items: items)
                    }
                }
            }
        }
    }

    /// 离线播放用的本地地址。
    func localURL(recordKey: String, number: Int) -> URL? {
        guard let record = records.first(where: { $0.id == recordKey }),
              let episode = record.episodes.first(where: { $0.number == number }),
              let file = episode.fileName
        else { return nil }
        for folder in folders(for: record, episode: episode) {
            let url = folder.appending(path: file)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 同上，但只按番剧 + 规则名找，不管线路（Colo 5174）。
    /// 播放器从详情页、历史、下载管理页都可能进来，线路编号不一定对得上；
    /// 对用户来说「这集我下过」就是能放。文件不在盘上就返回 nil，退回在线解析。
    func localURL(bangumiID: Int, pluginName: String, number: Int) -> URL? {
        for record in records where record.bangumiID == bangumiID && record.pluginName == pluginName {
            if let url = localURL(recordKey: record.id, number: number) { return url }
        }
        return nil
    }

    /// 按番剧 + 规则名取「已下好、文件还在盘上」的集号，升序。
    /// 在线列表抓不到时，播放器的选集就退回这一份（Colo v3 第 9 条）。
    func downloadedNumbers(bangumiID: Int, pluginName: String) -> [Int] {
        var numbers: Set<Int> = []
        for record in records where record.bangumiID == bangumiID && record.pluginName == pluginName {
            for episode in record.episodes where localURL(recordKey: record.id, number: episode.number) != nil {
                numbers.insert(episode.number)
            }
        }
        return numbers.sorted()
    }

    /// 这一集加进了下载但还没下完（Camo 5208）：播放时走在线解析，画面要说一句。
    func isEpisodeIncomplete(bangumiID: Int, pluginName: String, number: Int) -> Bool {
        for record in records where record.bangumiID == bangumiID && record.pluginName == pluginName {
            guard let episode = record.episodes.first(where: { $0.number == number }) else { continue }
            if !episode.isPlayableOffline { return true }
        }
        return false
    }

    // MARK: - 调度

    /// 按设置里的「同时下载集数」把队列推起来。
    private func pump() {
        let limit = max(1, min(5, settings.downloadParallelEpisodes))

        while activeEpisodeCount < limit, !queue.isEmpty {
            let item = queue.removeFirst()
            if cancelledBeforeStart.remove(item.id) != nil { continue }
            guard let record = records.first(where: { $0.id == item.recordKey }),
                  let episode = record.episodes.first(where: { $0.number == item.episodeNumber })
            else { continue }

            let flag = CancellationFlag()
            cancellationFlags[item.id] = flag
            activeNumbers[item.recordKey, default: []].insert(item.episodeNumber)
            activeEpisodeCount += 1
            beginBackgroundTaskIfNeeded()

            Task { [weak self] in
                guard let self else { return }
                await self.run(item: item, record: record, episode: episode, cancellation: flag)
                self.activeEpisodeCount -= 1
                self.pump()
                if self.activeEpisodeCount == 0, self.queue.isEmpty {
                    self.endBackgroundTaskIfNeeded()
                }
            }
        }
        if activeEpisodeCount == 0, queue.isEmpty {
            endBackgroundTaskIfNeeded()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "KazumiDownload") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func run(
        item: QueueItem,
        record: DownloadRecord,
        episode: DownloadEpisode,
        cancellation: CancellationFlag
    ) async {
        defer {
            cancellationFlags[item.id] = nil
            activeNumbers[item.recordKey]?.remove(item.episodeNumber)
            if activeNumbers[item.recordKey]?.isEmpty == true {
                activeNumbers[item.recordKey] = nil
            }
        }

        do {
            try await process(item: item, record: record, episode: episode, cancellation: cancellation)
        } catch {
            let wasCancelled = cancellation.isCancelled
                || error is CancellationError
                || (error as? DownloadEngineError) == .cancelled
                || (error as? DownloadError).map { if case .cancelled = $0 { return true } else { return false } } == true
            if wasCancelled {
                update(item) { episode in
                    syncProgressToEpisode(&episode, recordKey: item.recordKey)
                    episode.status = .paused
                }
            } else {
                update(item) { episode in
                    syncProgressToEpisode(&episode, recordKey: item.recordKey)
                    episode.status = .failed
                    episode.errorMessage = error.localizedDescription
                }
                // 一律说一句「第 N 集下载失败：原因」，用户才知道发生了什么（LP 5115）。
                let title = episode.title.isEmpty ? String(localized: "第 \(String(describing: item.episodeNumber)) 集") : episode.title
                failureNotice = String(localized: "「\(String(describing: title))」下载失败：\(String(describing: error.localizedDescription))")
                KazumiLogBuffer.network("下载失败：第 \(item.episodeNumber) 集 \(error.localizedDescription)")
            }
            persist()
        }
    }

    private func process(
        item: QueueItem,
        record: DownloadRecord,
        episode: DownloadEpisode,
        cancellation: CancellationFlag
    ) async throws {
        guard let plugin = plugins?.plugin(named: record.pluginName) else {
            throw DownloadError.pluginMissing(record.pluginName)
        }

        // 第一步：嗅真实地址。之前嗅到过的直接用；受独立限流器约束最多同时 2 个 WebView 并发。
        var mediaURL = episode.mediaURL
        if mediaURL.isEmpty {
            update(item) { $0.status = .resolving }
            persist()

            let resolved = try await resolveWithLimit(
                pageURL: episode.pageURL,
                useLegacyParser: plugin.useLegacyParser,
                pluginName: record.pluginName,
                cancellation: cancellation
            )
            mediaURL = resolved.url
            update(item) { $0.mediaURL = mediaURL }
            persist()
            if cancellation.isCancelled { throw DownloadError.cancelled }
        }

        update(item) { $0.status = .downloading }

        // 第二步：落盘。
        let folder = folderURL(for: record, episode: episode)
        let referer = plugin.referer.isEmpty ? plugin.baseUrl : plugin.referer
        // 规则的会话跟着规则走：登录过就用登录那个 UA，媒体请求也带上它的 Cookie。
        let loginUA = PluginCookieStore.shared.userAgent(for: record.pluginName)
        let userAgent = (loginUA?.isEmpty == false ? loginUA! : plugin.userAgent)
        let pluginName = record.pluginName
        let epPrefix = "ep-\(item.episodeNumber)"
        let target = try await engine.download(
            mediaURL: mediaURL,
            referer: referer,
            userAgent: userAgent,
            cookieForURL: { url in
                let header = PluginCookieStore.shared.cookieHeader(pluginName: pluginName, url: url.absoluteString)
                return header.isEmpty ? nil : header
            },
            to: folder,
            baseName: epPrefix,
            segmentConcurrency: settings.downloadParallelSegments,
            cancellation: cancellation,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.applyProgress(item: item, progress: progress)
                }
            }
        )

        // HLS 的 `target` 只是那份指向本地分片的播放列表（几百字节到几 KB），
        // 真正的体积在分片里。只算播放列表会显示成「11 KB」（LP 5112 看到的那样），统计移出主线程执行。
        let size = await Task.detached(priority: .utility) {
            Self.episodeBytes(folder: folder, prefix: epPrefix, target: target)
        }.value
        syncProgressState(
            recordKey: item.recordKey,
            number: item.episodeNumber,
            progress: 1,
            downloadedBytes: size,
            totalBytes: size
        )
        update(item) { episode in
            episode.status = .completed
            episode.progress = 1
            episode.fileName = target.lastPathComponent
            episode.directoryPath = folder.path
            episode.downloadedBytes = size
            episode.totalBytes = size
            episode.updatedAt = Date()
        }
        persist()
        KazumiLogBuffer.network("下载完成：第 \(item.episodeNumber) 集 \(size / 1024 / 1024) MB")

        // 离线下载弹幕：保存弹幕到同一集目录下，离线/飞行模式下可直接加载
        if record.bangumiID > 0 {
            let episodeNum = item.episodeNumber
            let bangumiID = record.bangumiID
            Task.detached(priority: .utility) {
                let result = await DanmakuAPI.fetch(bangumiID: bangumiID, episode: episodeNum)
                if case .success(let comments) = result, !comments.isEmpty {
                    let fileURL = folder.appending(path: "ep-\(episodeNum).danmaku.json")
                    if let data = try? JSONEncoder().encode(comments) {
                        try? data.write(to: fileURL, options: .atomic)
                        KazumiLogBuffer.storage("离线弹幕下载成功：第 \(episodeNum) 集保存 \(comments.count) 条弹幕")
                    }
                }
            }
        }
    }

    private func resolveWithLimit(
        pageURL: String,
        useLegacyParser: Bool,
        pluginName: String,
        cancellation: CancellationFlag
    ) async throws -> EpisodeMediaResolver.Result {
        try await resolveLimiter.acquire(cancellation: cancellation)
        defer { resolveLimiter.release() }
        return try await resolver.resolve(
            pageURL: pageURL,
            useLegacyParser: useLegacyParser,
            pluginName: pluginName,
            cancellation: cancellation
        )
    }

    /// 一集真正占了多少地方：本地播放列表 + 它的全部分片。
    /// 直链下载那就只有一份文件，跟播放列表同名规则也适用。
    nonisolated private static func episodeBytes(folder: URL, prefix: String, target: URL) -> Int64 {
        let targetSize = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
        guard target.pathExtension == "m3u8" else { return targetSize }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var total = targetSize
        for item in items where item.lastPathComponent.hasPrefix(prefix + "-") {
            total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        }
        return total
    }

    // MARK: - 记录读写

    private func applyProgress(item: QueueItem, progress: DownloadProgress) {
        // 已经跑完 / 被取消的那几集，晚到的进度回调不要覆盖状态。
        guard activeNumbers[item.recordKey]?.contains(item.episodeNumber) == true,
              let episode = episode(recordKey: item.recordKey, number: item.episodeNumber),
              episode.status == .downloading || episode.status == .resolving
        else { return }

        // 只更新独立进度对象，不写回值类型 `records`，避免单集进度变化触发整页列表重绘。
        let state = progressState(recordKey: item.recordKey, episode: episode)
        if progress.receivedBytes > 0 || state.downloadedBytes == 0 {
            state.downloadedBytes = progress.receivedBytes
        }
        if progress.totalBytes > 0 {
            state.totalBytes = progress.totalBytes
        }
        if progress.fraction >= 0 {
            state.progress = min(1, progress.fraction)
        }

        // 每 2 秒节流落盘一次进度，避免强杀 App 后重启回退到上次暂停/继续前的旧进度。
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressPersistUptime >= 2.0 {
            lastProgressPersistUptime = now
            persist()
        }
    }

    private func syncProgressToEpisode(_ episode: inout DownloadEpisode, recordKey: String) {
        let key = Self.episodeKey(recordKey: recordKey, number: episode.number)
        guard let state = progressStates[key] else { return }
        episode.progress = state.progress
        episode.downloadedBytes = state.downloadedBytes
        episode.totalBytes = state.totalBytes
    }

    private func syncProgressState(
        recordKey: String,
        number: Int,
        progress: Double,
        downloadedBytes: Int64,
        totalBytes: Int64
    ) {
        let key = Self.episodeKey(recordKey: recordKey, number: number)
        guard let state = progressStates[key] else { return }
        state.progress = progress
        state.downloadedBytes = downloadedBytes
        state.totalBytes = totalBytes
    }

    private func removeProgressStates(recordKey: String, numbers: Set<Int>? = nil) {
        if let numbers {
            for number in numbers {
                progressStates.removeValue(forKey: Self.episodeKey(recordKey: recordKey, number: number))
            }
        } else {
            let prefix = "\(recordKey)#"
            progressStates = progressStates.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    /// 持久化前将内存中的实时 `progressStates` 合并进快照副本，不回写 `self.records`。
    private func snapshotRecordsWithLiveProgress() -> [DownloadRecord] {
        guard !progressStates.isEmpty else { return records }
        return records.map { record in
            var copy = record
            for index in copy.episodes.indices {
                let key = Self.episodeKey(recordKey: copy.id, number: copy.episodes[index].number)
                if let state = progressStates[key] {
                    copy.episodes[index].progress = state.progress
                    copy.episodes[index].downloadedBytes = state.downloadedBytes
                    copy.episodes[index].totalBytes = state.totalBytes
                }
            }
            return copy
        }
    }

    private func upsert(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
    }

    private func update(_ item: QueueItem, persistNow: Bool = true, _ body: (inout DownloadEpisode) -> Void) {
        updateMany(recordKey: item.recordKey, numbers: [item.episodeNumber], persistNow: persistNow) { episodes, number in
            guard let index = episodes.firstIndex(where: { $0.number == number }) else { return }
            body(&episodes[index])
        }
    }

    private func updateMany(
        recordKey: String,
        numbers: Set<Int>,
        persistNow: Bool = true,
        _ body: (inout [DownloadEpisode], Int) -> Void
    ) {
        guard let recordIndex = records.firstIndex(where: { $0.id == recordKey }) else { return }
        var episodes = records[recordIndex].episodes
        for number in numbers {
            body(&episodes, number)
        }
        records[recordIndex].episodes = episodes
        if persistNow { persist() }
    }

    nonisolated private static func folderURL(for record: DownloadRecord, directoryURL: URL) -> URL {
        let name = "\(record.bangumiID)-\(record.pluginName)-\(record.road)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directoryURL.appending(path: name, directoryHint: .isDirectory)
    }

    nonisolated private static func legacyFolderURL(for record: DownloadRecord, directoryURL: URL) -> URL {
        let name = "\(record.bangumiID)-\(record.pluginName)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directoryURL.appending(path: name, directoryHint: .isDirectory)
    }

    nonisolated private static func rebaseSandboxPath(_ path: String) -> URL? {
        let docMarker = "/Documents/"
        if let range = path.range(of: docMarker) {
            let rel = String(path[range.upperBound...])
            let docRoot = AppEnvironment.downloadRoot.deletingLastPathComponent()
            return docRoot.appending(path: rel, directoryHint: .isDirectory)
        }
        let supportMarker = "/Application Support/Kazumi/"
        if let range = path.range(of: supportMarker) {
            let rel = String(path[range.upperBound...])
            return AppEnvironment.storageRoot.appending(path: rel, directoryHint: .isDirectory)
        }
        return nil
    }

    nonisolated private static func folders(
        for record: DownloadRecord,
        episode: DownloadEpisode,
        directoryURL: URL
    ) -> [URL] {
        var candidates: [URL] = []
        if let path = episode.directoryPath, !path.isEmpty {
            let exact = URL(fileURLWithPath: path, isDirectory: true)
            candidates.append(exact)
            if let rebased = rebaseSandboxPath(path) {
                candidates.append(rebased)
            }
        }
        let currentFolder = folderURL(for: record, directoryURL: directoryURL)
        let legacyFolder = legacyFolderURL(for: record, directoryURL: directoryURL)
        candidates.append(currentFolder)
        if currentFolder.path != legacyFolder.path {
            candidates.append(legacyFolder)
        }
        let folderName = currentFolder.lastPathComponent
        let legacyFolderName = legacyFolder.lastPathComponent
        for root in AppEnvironment.legacyDownloadRoots {
            candidates.append(root.appending(path: folderName, directoryHint: .isDirectory))
            if folderName != legacyFolderName {
                candidates.append(root.appending(path: legacyFolderName, directoryHint: .isDirectory))
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private func folderURL(for record: DownloadRecord) -> URL {
        Self.folderURL(for: record, directoryURL: directory.directoryURL)
    }

    private func legacyFolderURL(for record: DownloadRecord) -> URL {
        Self.legacyFolderURL(for: record, directoryURL: directory.directoryURL)
    }

    private func folderURL(for record: DownloadRecord, episode: DownloadEpisode) -> URL {
        if let path = episode.directoryPath, !path.isEmpty {
            let original = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: original.path) {
                return original
            }
            if let rebased = Self.rebaseSandboxPath(path), FileManager.default.fileExists(atPath: rebased.path) {
                return rebased
            }
        }
        return folderURL(for: record)
    }

    private func folders(for record: DownloadRecord, episode: DownloadEpisode) -> [URL] {
        Self.folders(for: record, episode: episode, directoryURL: directory.directoryURL)
    }

    private func recordFolders(for record: DownloadRecord) -> [URL] {
        var candidates = record.episodes.flatMap { folders(for: record, episode: $0) }
        candidates.append(folderURL(for: record))
        candidates.append(legacyFolderURL(for: record))
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private func isFolderReferenced(_ folder: URL, excluding recordID: String) -> Bool {
        records.contains { other in
            guard other.id != recordID else { return false }
            if folderURL(for: other).path == folder.path || legacyFolderURL(for: other).path == folder.path {
                return true
            }
            return other.episodes.contains { $0.directoryPath == folder.path }
        }
    }

    /// 删掉一集的所有分片（`ep-3-seg-00000.ts`、`ep-3.m3u8`、`ep-3-init.mp4` 之类）。
    nonisolated private static func removeSegments(in folder: URL, prefix: String, items: [URL]? = nil) {
        guard let items = items ?? (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix + ".") || item.lastPathComponent.hasPrefix(prefix + "-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - 持久化

    nonisolated private static var storeURL: URL {
        AppEnvironment.storageRoot.appending(path: "downloads.json")
    }

    private struct MissingFileCheckResult: Sendable {
        struct AdoptedDirectory: Sendable {
            let recordID: String
            let episodeNumber: Int
            let directoryPath: String
        }

        struct RecoveredEpisode: Sendable {
            let recordID: String
            let episodeNumber: Int
            let fileName: String
            let directoryPath: String
            let size: Int64
        }

        struct DroppedEpisode: Sendable {
            let recordID: String
            let episodeNumber: Int
        }

        var adoptedDirectories: [AdoptedDirectory] = []
        var recoveredEpisodes: [RecoveredEpisode] = []
        var droppedEpisodes: [DroppedEpisode] = []
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return }
        // 上次没跑完的：队列在内存里，重启就没了，一律退回暂停，但保留已下进度与已下字节。
        records = decoded.map { record in
            var mutable = record
            for index in mutable.episodes.indices where mutable.episodes[index].status.isActive {
                mutable.episodes[index].status = .paused
            }
            return mutable
        }
        // 记录说下完、盘上却没有文件的：把文件名清掉，当这集没下过。
        //
        // 不清的话是一套自相矛盾的状态：下载管理页按 `isPlayableOffline` 算它已下完
        // （勾还在、存储页数着它），点进去 `localURL` 查了文件返回 nil、退回在线解析，
        // 想重下又被 `enqueue` 的同一个判据挡住——勾还在、放不了、也重下不了
        // （Fuck 5263）。将磁盘文件校验移入后台线程执行，完成后再回主线程应用。
        let snapshot = records
        let directoryURL = directory.directoryURL
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.scanMissingFiles(records: snapshot, directoryURL: directoryURL)
            await self?.applyMissingFileCheckResult(result)
        }
    }

    /// 在后台线程核对磁盘上的已下载文件，收集目录修正、自动恢复和缺失清理项。
    nonisolated private static func scanMissingFiles(
        records: [DownloadRecord],
        directoryURL: URL
    ) -> MissingFileCheckResult {
        var result = MissingFileCheckResult()
        for record in records {
            for episode in record.episodes {
                guard episode.status == .completed else { continue }
                let candidateFolders = folders(for: record, episode: episode, directoryURL: directoryURL)

                // 1. 若带有文件名，先在候选文件夹中查找
                if let fileName = episode.fileName {
                    if let folder = candidateFolders.first(where: {
                        FileManager.default.fileExists(atPath: $0.appending(path: fileName).path)
                    }) {
                        if episode.directoryPath != folder.path {
                            result.adoptedDirectories.append(.init(
                                recordID: record.id,
                                episodeNumber: episode.number,
                                directoryPath: folder.path
                            ))
                        }
                        continue
                    }
                }

                // 2. 自动恢复（修复 3.0.8 升级后因绝对路径变动导致文件名被误清的问题）：
                // 在候选文件夹内探查是否有符合该集前缀的已下完文件（.mp4 或 .m3u8）
                let epPrefix = "ep-\(episode.number)"
                var recoveredTarget: URL?
                var recoveredFolder: URL?
                for folder in candidateFolders {
                    let mp4 = folder.appending(path: "\(epPrefix).mp4")
                    let m3u8 = folder.appending(path: "\(epPrefix).m3u8")
                    if FileManager.default.fileExists(atPath: mp4.path) {
                        recoveredTarget = mp4
                        recoveredFolder = folder
                        break
                    } else if FileManager.default.fileExists(atPath: m3u8.path) {
                        recoveredTarget = m3u8
                        recoveredFolder = folder
                        break
                    }
                }

                if let target = recoveredTarget, let folder = recoveredFolder {
                    let size = episodeBytes(folder: folder, prefix: epPrefix, target: target)
                    result.recoveredEpisodes.append(.init(
                        recordID: record.id,
                        episodeNumber: episode.number,
                        fileName: target.lastPathComponent,
                        directoryPath: folder.path,
                        size: size
                    ))
                    continue
                }

                // 3. 所有候选目录确实都找不到该集文件，才按未下载处理
                guard episode.directoryPath?.isEmpty == false || episode.fileName != nil else { continue }
                result.droppedEpisodes.append(.init(
                    recordID: record.id,
                    episodeNumber: episode.number
                ))
            }
        }
        return result
    }

    /// 将后台 `scanMissingFiles` 校验结果回主线程应用到 `records`。
    private func applyMissingFileCheckResult(_ result: MissingFileCheckResult) {
        var dropped = 0
        var adopted = false

        for item in result.adoptedDirectories {
            guard let rIndex = records.firstIndex(where: { $0.id == item.recordID }),
                  let eIndex = records[rIndex].episodes.firstIndex(where: { $0.number == item.episodeNumber }),
                  records[rIndex].episodes[eIndex].status == .completed
            else { continue }
            if records[rIndex].episodes[eIndex].directoryPath != item.directoryPath {
                records[rIndex].episodes[eIndex].directoryPath = item.directoryPath
                adopted = true
            }
        }

        for item in result.recoveredEpisodes {
            guard let rIndex = records.firstIndex(where: { $0.id == item.recordID }),
                  let eIndex = records[rIndex].episodes.firstIndex(where: { $0.number == item.episodeNumber }),
                  records[rIndex].episodes[eIndex].status == .completed
            else { continue }
            records[rIndex].episodes[eIndex].status = .completed
            records[rIndex].episodes[eIndex].progress = 1
            records[rIndex].episodes[eIndex].fileName = item.fileName
            records[rIndex].episodes[eIndex].directoryPath = item.directoryPath
            records[rIndex].episodes[eIndex].downloadedBytes = item.size
            records[rIndex].episodes[eIndex].totalBytes = item.size
            records[rIndex].episodes[eIndex].updatedAt = Date()
            syncProgressState(
                recordKey: item.recordID,
                number: item.episodeNumber,
                progress: 1,
                downloadedBytes: item.size,
                totalBytes: item.size
            )
            adopted = true
            KazumiLogBuffer.storage("下载记录：自动恢复第 \(item.episodeNumber) 集文件 \(item.fileName)")
        }

        for item in result.droppedEpisodes {
            guard let rIndex = records.firstIndex(where: { $0.id == item.recordID }),
                  let eIndex = records[rIndex].episodes.firstIndex(where: { $0.number == item.episodeNumber }),
                  records[rIndex].episodes[eIndex].status == .completed
            else { continue }
            records[rIndex].episodes[eIndex].fileName = nil
            records[rIndex].episodes[eIndex].directoryPath = nil
            records[rIndex].episodes[eIndex].downloadedBytes = 0
            records[rIndex].episodes[eIndex].updatedAt = Date()
            syncProgressState(
                recordKey: item.recordID,
                number: item.episodeNumber,
                progress: records[rIndex].episodes[eIndex].progress,
                downloadedBytes: 0,
                totalBytes: records[rIndex].episodes[eIndex].totalBytes
            )
            dropped += 1
        }

        if dropped > 0 {
            KazumiLogBuffer.storage("下载记录：\(dropped) 集的文件不在，按未下载处理")
        }
        if dropped > 0 || adopted {
            persist()
        }
    }

    private var saveTask: Task<Void, Never>?

    /// 切出前台 / 进入多任务视图时立即派发后台串行刷盘，确保强杀 App 前最新下载进度已写入 `downloads.json`。
    private func flushPersistIfDownloading() {
        guard activeEpisodeCount > 0 || saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        lastProgressPersistUptime = ProcessInfo.processInfo.systemUptime
        let snapshot = snapshotRecordsWithLiveProgress()
        let storeURL = Self.storeURL
        let actor = persistenceActor
        Task {
            await actor.writeSnapshot(snapshot, to: storeURL)
        }
    }

    /// 落盘。进度回调很密，攒一下再交由后台串行 `DownloadPersistenceActor` 编码写盘，不阻塞主线程。
    private func persist() {
        saveTask?.cancel()
        let snapshot = snapshotRecordsWithLiveProgress()
        let storeURL = Self.storeURL
        let actor = persistenceActor
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await actor.writeSnapshot(snapshot, to: storeURL)
        }
    }
}

/// 格子上要画的状态。
enum DownloadLiteStatus: Equatable, Sendable {
    case normal
    case queued
    case downloading(Double)
    case downloaded
    case failed

    /// 「已经加进下载」——下载中、排队、暂停都算，只是进度不同。
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
