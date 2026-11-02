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
//  `DownloadEngine` 落盘。嗅地址很重（一个 WebView 一个进程），所以它跟着集数
//  并发走，不额外放宽。
//
//  记录存 Application Support/downloads.json；文件落在下载目录
//  `<番剧ID>-<规则名>/` 下，离线播放直接喂本地播放列表。
//

import Foundation
import Observation

@MainActor
@Observable
final class DownloadCenter {
    /// 所有记录，最近下的在前面。
    private(set) var records: [DownloadRecord] = []

    /// 正在跑的那几集（界面画「下载中」用）。
    private(set) var activeNumbers: [String: Set<Int>] = [:]

    /// 最近一次失败的一句话，给界面弹一下（LP 5115：失败要说，不能只画个红点）。
    /// 界面拿来当 toast 显示完就把 `notice` 清掉，所以它不会自己一直在。
    var failureNotice: String?

    private let resolver = EpisodeMediaResolver()
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

    /// 一集的显示状态，界面按这个画格子。
    func liteStatus(recordKey: String, number: Int) -> DownloadLiteStatus {
        if let episode = episode(recordKey: recordKey, number: number) {
            if episode.isPlayableOffline { return .downloaded }
            if episode.status == .failed { return .failed }
            // 记录说下完、文件却不在：当没下过，让格子回到初始样子、允许重下。
            if episode.status == .completed && episode.fileName == nil { return .normal }
            // LP 5193：只要加进下载就给「在下载」那个符号，不管是在下、排队还是暂停。
            return .downloading(episode.progress)
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

        var added: [QueueItem] = []
        for item in episodes {
            if let index = record.episodes.firstIndex(where: { $0.number == item.number }) {
                let existing = record.episodes[index]
                // 已下完、正在下、已经在排队的，不重复加；失败过的允许重来。
                if existing.isPlayableOffline || existing.status.isActive { continue }
                if queuedNumbers(recordKey: key).contains(item.number) { continue }
                // 暂停/取消过的集重新入队时，要把「取消之后才轮到」的标记清掉：
                // 不清的话 pump() 出队时会把它当已取消跳过，界面永远停在排队中。
                cancelledBeforeStart.remove("\(key)#\(item.number)")
                record.episodes[index].status = .pending
                record.episodes[index].errorMessage = nil
                record.episodes[index].progress = 0
            } else {
                record.episodes.append(DownloadEpisode(
                    number: item.number,
                    title: item.title,
                    pageURL: item.pageURL,
                    status: .pending
                ))
            }
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
                episodes[index].status = .paused
                episodes[index].progress = 0
            }
        }
        persist()
        pump()
    }

    /// 清掉某一部的失败痕迹（LP 5115：重新拉一遍剧集列表就该没了）。
    /// 失败的那几集根本不存在可播的文件，直接从记录里描掉，格子回到「没下过」。
    func clearFailures(recordKey: String) {
        guard let index = records.firstIndex(where: { $0.id == recordKey }) else { return }
        let before = records[index].episodes.count
        records[index].episodes.removeAll { $0.status == .failed }
        guard records[index].episodes.count != before else { return }
        // 一集都没剩就别留个空壳。
        if records[index].episodes.isEmpty {
            records.remove(at: index)
        }
        persist()
    }

    /// 删掉一份记录连同它的文件。
    func removeRecord(_ record: DownloadRecord) {
        cancel(recordKey: record.id, numbers: record.episodes.map(\.number))
        for folder in recordFolders(for: record) where !isFolderReferenced(folder, excluding: record.id) {
            try? FileManager.default.removeItem(at: folder)
        }
        records.removeAll { $0.id == record.id }
        activeNumbers[record.id] = nil
        persist()
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
        persist()
    }

    /// 离线下载总共占了多少字节（文件真的在盘上的才算）。
    func totalBytes() -> Int64 {
        records.reduce(Int64(0)) { total, record in
            var sum: Int64 = 0
            for folder in recordFolders(for: record) {
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
                    sum += Int64(size)
                }
            }
            return total + sum
        }
    }

    /// 一次删多集（多选删除用）。
    func removeEpisodes(recordKey: String, numbers: [Int]) {
        guard let record = records.first(where: { $0.id == recordKey }), !numbers.isEmpty else { return }
        let targets = record.episodes.filter { numbers.contains($0.number) }
        cancel(recordKey: recordKey, numbers: numbers)
        var listings: [String: [URL]] = [:]
        for episode in targets {
            for folder in folders(for: record, episode: episode) {
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
                if let file = episode.fileName {
                    // 分片一起删：本地播放列表指向它们，留下就是垃圾。
                    try? FileManager.default.removeItem(at: folder.appending(path: file))
                }
                removeSegments(in: folder, prefix: "ep-\(episode.number)", items: items)
            }
        }
        updateMany(recordKey: recordKey, numbers: Set(numbers)) { episodes, number in
            episodes.removeAll { $0.number == number }
        }
        // 集全删光了就整条记录一起走（LP 5482）：不然下载管理里留一个空番剧名，
        // 点进去什么都没有，删也删不掉。
        if let updated = records.first(where: { $0.id == recordKey }), updated.episodes.isEmpty {
            // `removeRecord` 自己会停任务、删文件夹、落盘。
            removeRecord(updated)
            return
        }
        persist()
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

            Task { [weak self] in
                guard let self else { return }
                await self.run(item: item, record: record, episode: episode, cancellation: flag)
                self.activeEpisodeCount -= 1
                self.pump()
            }
        }
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
                    episode.status = .paused
                    episode.progress = 0
                }
            } else {
                update(item) { episode in
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

        // 第一步：嗅真实地址。之前嗅到过的直接用。
        var mediaURL = episode.mediaURL
        if mediaURL.isEmpty {
            update(item) { $0.status = .resolving }
            persist()

            let resolved = try await resolver.resolve(
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
        let engine = DownloadEngine(cookieForURL: { url in
            let header = PluginCookieStore.shared.cookieHeader(pluginName: pluginName, url: url.absoluteString)
            return header.isEmpty ? nil : header
        })
        let target = try await engine.download(
            mediaURL: mediaURL,
            referer: referer,
            userAgent: userAgent,
            to: folder,
            baseName: "ep-\(item.episodeNumber)",
            segmentConcurrency: settings.downloadParallelSegments,
            cancellation: cancellation,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.applyProgress(item: item, progress: progress)
                }
            }
        )

        // HLS 的 `target` 只是那份指向本地分片的播放列表（几百字节到几 KB），
        // 真正的体积在分片里。只算播放列表会显示成「11 KB」（LP 5112 看到的那样）。
        let size = Self.episodeBytes(folder: folder, prefix: "ep-\(item.episodeNumber)", target: target)
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
    }

    /// 一集真正占了多少地方：本地播放列表 + 它的全部分片。
    /// 直链下载那就只有一份文件，跟播放列表同名规则也适用。
    private static func episodeBytes(folder: URL, prefix: String, target: URL) -> Int64 {
        let targetSize = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
        guard target.pathExtension == "m3u8" else { return targetSize }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var total = targetSize
        for item in items where item.lastPathComponent.hasPrefix(prefix + "-") {
            total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0 ?? 0) } ?? 0
        }
        return total
    }

    // MARK: - 记录读写

    private func applyProgress(item: QueueItem, progress: DownloadProgress) {
        // 已经跑完 / 被取消的那几集，晚到的进度回调不要覆盖状态。
        guard activeNumbers[item.recordKey]?.contains(item.episodeNumber) == true else { return }
        update(item, persistNow: false) { episode in
            guard episode.status == .downloading || episode.status == .resolving else { return }
            episode.status = .downloading
            episode.downloadedBytes = progress.receivedBytes
            if progress.totalBytes > 0 { episode.totalBytes = progress.totalBytes }
            episode.progress = progress.fraction < 0 ? 0 : min(1, progress.fraction)
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

    private func folderURL(for record: DownloadRecord) -> URL {
        let name = "\(record.bangumiID)-\(record.pluginName)-\(record.road)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.directoryURL.appending(path: name, directoryHint: .isDirectory)
    }

    private func legacyFolderURL(for record: DownloadRecord) -> URL {
        let name = "\(record.bangumiID)-\(record.pluginName)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.directoryURL.appending(path: name, directoryHint: .isDirectory)
    }

    private func folderURL(for record: DownloadRecord, episode: DownloadEpisode) -> URL {
        if let path = episode.directoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return folderURL(for: record)
    }

    private func folders(for record: DownloadRecord, episode: DownloadEpisode) -> [URL] {
        if episode.directoryPath?.isEmpty == false {
            return [folderURL(for: record, episode: episode)]
        }
        let folder = folderURL(for: record)
        let legacy = legacyFolderURL(for: record)
        return folder.path == legacy.path ? [folder] : [folder, legacy]
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
    private func removeSegments(in folder: URL, prefix: String, items: [URL]? = nil) {
        guard let items = items ?? (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix + ".") || item.lastPathComponent.hasPrefix(prefix + "-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - 持久化

    private static var storeURL: URL {
        AppEnvironment.storageRoot.appending(path: "downloads.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return }
        // 上次没跑完的：队列在内存里，重启就没了，一律退回暂停。
        records = decoded.map { record in
            var mutable = record
            for index in mutable.episodes.indices where mutable.episodes[index].status.isActive {
                mutable.episodes[index].status = .paused
                mutable.episodes[index].progress = 0
            }
            return mutable
        }
        // 记录说下完、盘上却没有文件的：把文件名清掉，当这集没下过。
        //
        // 不清的话是一套自相矛盾的状态：下载管理页按 `isPlayableOffline` 算它已下完
        // （勾还在、存储页数着它），点进去 `localURL` 查了文件返回 nil、退回在线解析，
        // 想重下又被 `enqueue` 的同一个判据挡住——勾还在、放不了、也重下不了
        // （Fuck 5263）。清掉文件名之后，勾、计数、重下三处一起回到真话。
        dropMissingFiles()
    }

    /// 把「记录说下完、文件却不在」的集清成没下过。返回清掉了多少集。
    @discardableResult
    private func dropMissingFiles() -> Int {
        var dropped = 0
        var adopted = false
        for recordIndex in records.indices {
            let record = records[recordIndex]
            for index in record.episodes.indices {
                let episode = record.episodes[index]
                guard episode.status == .completed,
                      let fileName = episode.fileName
                else { continue }
                if let folder = folders(for: record, episode: episode).first(where: {
                    FileManager.default.fileExists(atPath: $0.appending(path: fileName).path)
                }) {
                    if records[recordIndex].episodes[index].directoryPath != folder.path {
                        records[recordIndex].episodes[index].directoryPath = folder.path
                        adopted = true
                    }
                    continue
                }
                guard episode.directoryPath?.isEmpty == false else { continue }
                records[recordIndex].episodes[index].fileName = nil
                records[recordIndex].episodes[index].directoryPath = nil
                records[recordIndex].episodes[index].downloadedBytes = 0
                records[recordIndex].episodes[index].updatedAt = Date()
                dropped += 1
            }
        }
        if dropped > 0 {
            KazumiLogBuffer.storage("下载记录：\(dropped) 集的文件不在，按未下载处理")
        }
        if dropped > 0 || adopted {
            persist()
        }
        return dropped
    }

    private var saveTask: Task<Void, Never>?

    /// 落盘。进度回调很密，攒一下再写，别把主线程拖住。
    private func persist() {
        saveTask?.cancel()
        let snapshot = records
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: Self.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.storeURL, options: .atomic)
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
