//
//  LibraryStore.swift
//  Kazumi
//
//  追番 / 历史 / 播放进度的内存索引（替代 CollectController / HistoryController）。
//  真正的持久化由 Step 3 的 StorageRepository 负责；这里只持有 UI 直接读取的快照，
//  保证 Step 1 即可编译、Step 3 之后无需改动调用方。
//

import Foundation
import Observation

/// 收藏类型，数值与 lib/modules/collect/collect_type.dart 逐一对应，
/// 保证导出 / WebDAV 备份与 Flutter 版互通（watching = 1，planToWatch(想看) = 2）。
enum CollectType: Int, Codable, CaseIterable, Sendable, Identifiable {
    case none = 0
    case watching = 1
    case wish = 2
    case onHold = 3
    case watched = 4
    case dropped = 5

    var id: Int { rawValue }

    /// 可选的收藏状态（排除「未收藏」）。
    static var enabledCases: [CollectType] { [.watching, .wish, .onHold, .watched, .dropped] }

    /// 收藏状态名，对应 lib/modules/collect/collect_type.dart 的 CollectType.label。
    /// 收藏库卡片、收藏库筛选栏用的是这一套（未收藏 / 在看 / 想看 / 搁置 / 看过 / 抛弃）。
    var title: String {
        switch self {
        case .none: String(localized: "未收藏")
        case .watching: String(localized: "在看")
        case .wish: String(localized: "想看")
        case .onHold: String(localized: "搁置")
        case .watched: String(localized: "看过")
        case .dropped: String(localized: "抛弃")
        }
    }

    /// 详情页追番按钮与下拉菜单的文案，对应
    /// lib/bean/widget/collect_button.dart 的 getTypeStringByInt：
    /// 未追 / 在看 / 想看 / 搁置 / 看过 / 抛弃。
    ///
    /// 与 [title] 只差「未追」这一档：按钮上的未收藏状态叫「未追」，
    /// 收藏库里的分类仍叫「未收藏」，两处不要混用。
    /// 追番状态的图标，1:1 翻自原版 `lib/bean/widget/collect_button.dart:83-97`
    /// 的 `getIconByInt`（Material → SF Symbols）：
    /// 在看 heart.fill、想看 star.fill、搁置 hourglass、看过 checkmark、
    /// 抛弃 heart.slash.fill、未收藏 heart。
    var statusSymbol: String {
        switch self {
        case .watching: "heart.fill"
        case .wish: "star.fill"
        case .onHold: "hourglass"
        case .watched: "checkmark"
        case .dropped: "heart.slash.fill"
        case .none: "heart"
        }
    }

    var buttonTitle: String {
        switch self {
        case .none: String(localized: "未追")
        case .watching: String(localized: "在看")
        case .wish: String(localized: "想看")
        case .onHold: String(localized: "搁置")
        case .watched: String(localized: "看过")
        case .dropped: String(localized: "抛弃")
        }
    }

    /// 对应 collect_type_mapper.dart 的 toBangumiCollectionType：
    /// Bangumi 的收藏类型编号与本地编号不同（本地 1=在看，Bangumi 3=在看）。
    /// 写回收藏状态时要用这一套。
    var bangumiCollectionType: Int? {
        switch self {
        case .none: nil
        case .watching: 3
        case .wish: 1
        case .onHold: 4
        case .watched: 2
        case .dropped: 5
        }
    }

}


/// 追番条目（对应原项目 BangumiItem 中 UI 需要的字段子集）。
struct LibraryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var type: Int
    var name: String
    var nameCn: String
    var summary: String
    var airDate: String
    var imageURL: String
    var rating: Double
    var rank: Int
    var tags: [String]
    var totalEpisodes: Int
    var currentEpisode: Int
    var addedAt: Date
    var updatedAt: Date

    var displayName: String { nameCn.isEmpty ? name : nameCn }

    var collectType: CollectType { CollectType(rawValue: type) ?? .none }
}

/// 单集进度：一集一条，自己带线路号。
///
/// 对应 main 的 `Progress`（lib/modules/history/history_module.dart）：
/// episode / road / progressMs / updatedAtMs。main 那边一条历史按
/// 「规则名 + 番剧」存，`progresses` 里装着看过的每一集；本端照抄这套形状，
/// 云盘上那份 `history/snapshot.json` 才能两边互读（见 `WebDAVLegacy`）。
struct EpisodeProgress: Codable, Hashable, Sendable {
    var episode: Int
    var road: Int
    var progressSeconds: Double
    var updatedAt: Date
}

/// 观看记录（对应 main 的 `History`：一条 = 一个规则 + 一部番）。
///
/// 主键是「规则名 + 番剧 ID」（`id`），不是番剧 ID：同一部番在不同规则下
/// 集数编号不一定一样，各自记一份（LP 4844「续播按 main 的方法」）。
/// 每一集的进度在 `progresses` 里，各带自己的线路号——换线路看同一集时
/// 线路号跟着这一集走，不像老格式那样整条记录只有一个 `roadIndex`。
struct WatchRecord: Identifiable, Codable, Hashable, Sendable {
    /// 跟 main 的 `History.scopedKey` 同一个写法：`<规则名><番剧ID>::online`。
    var id: String { "\(sourceRuleName)\(bangumiID)::online" }
    var bangumiID: Int
    var bangumiName: String
    var imageURL: String
    var sourceRuleName: String
    var episodeTitle: String
    var episodeNumber: Int
    var durationSeconds: Double
    var updatedAt: Date
    /// 集号 → 那一集的进度。键是 `String(episode)`，跟 main 的快照里
    /// `progresses` 的键一致，这样同一份 JSON 两边都能读。
    var progresses: [String: EpisodeProgress]
    /// 仅「我的」页观看历史下方最近 3 部番剧的最新来源记录保留详情页地址，
    /// 供续播跳过全源搜索秒进章节解析；其余记录自动裁剪为 nil（U1）。
    var detailURL: String?

    init(
        bangumiID: Int,
        bangumiName: String,
        imageURL: String,
        sourceRuleName: String,
        episodeTitle: String,
        episodeNumber: Int,
        durationSeconds: Double,
        updatedAt: Date,
        progresses: [String: EpisodeProgress] = [:],
        detailURL: String? = nil
    ) {
        self.bangumiID = bangumiID
        self.bangumiName = bangumiName
        self.imageURL = imageURL
        self.sourceRuleName = sourceRuleName
        self.episodeTitle = episodeTitle
        self.episodeNumber = episodeNumber
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
        self.progresses = progresses
        self.detailURL = detailURL
    }

    /// 上次看的那一集走的是第几条线路；老数据没记就是第一条。
    var roadIndex: Int { progresses[String(episodeNumber)]?.road ?? 0 }

    /// 上次看的那一集停在多少秒。
    var progressSeconds: Double { progresses[String(episodeNumber)]?.progressSeconds ?? 0 }

    var fraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(progressSeconds / durationSeconds, 0), 1)
    }

    var isFinished: Bool {
        durationSeconds > 0 && durationSeconds - progressSeconds <= 5
    }

    /// 「看到 8:21」这样具体的位置，照 main 的写法
    /// （`lib/pages/history/history_record_tile.dart` 的 `_position`）。
    /// 一集都没看下去就没有这一行。
    var positionText: String? {
        guard progressSeconds > 0 else { return nil }
        return String(localized: "看到 ") + WatchRecord.clock(progressSeconds)
    }

    /// 时长写法：`8:21`，过一小时才带小时（`1:02:34`）。
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, rest) }
        return String(format: "%d:%02d:%02d", hours, minutes, rest)
    }

    /// 读回时兼容两种形状：
    /// * 新格式有 `progresses`，直接用；
    /// * 老格式（本端旧文件、旧备份）只有 `episodeNumber` / `progressSeconds` /
    ///   `roadIndex` 三个平铺字段，这里现造一条 `EpisodeProgress` 出来，
    ///   进度不会在读回的那一刻丢掉。
    ///
    /// 编码仍走合成实现（`progresses` 一起写），老版本读不了新文件是预期的。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bangumiID = try container.decodeIfPresent(Int.self, forKey: .bangumiID) ?? 0
        bangumiName = try container.decodeIfPresent(String.self, forKey: .bangumiName) ?? ""
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        sourceRuleName = try container.decodeIfPresent(String.self, forKey: .sourceRuleName) ?? ""
        episodeTitle = try container.decodeIfPresent(String.self, forKey: .episodeTitle) ?? ""
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber) ?? 0
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date.distantPast
        var map = try container.decodeIfPresent([String: EpisodeProgress].self, forKey: .progresses) ?? [:]
        let legacyRoad = try container.decodeIfPresent(Int.self, forKey: .legacyRoadIndex) ?? 0
        let legacySeconds = try container.decodeIfPresent(Double.self, forKey: .legacyProgressSeconds) ?? 0
        if map[String(episodeNumber)] == nil, episodeNumber > 0, legacySeconds > 0 || legacyRoad > 0 {
            map[String(episodeNumber)] = EpisodeProgress(
                episode: episodeNumber,
                road: legacyRoad,
                progressSeconds: legacySeconds,
                updatedAt: updatedAt
            )
        }
        progresses = map
        detailURL = try container.decodeIfPresent(String.self, forKey: .detailURL)
    }

    private enum CodingKeys: String, CodingKey {
        case bangumiID, bangumiName, imageURL, sourceRuleName
        case episodeTitle, episodeNumber, durationSeconds, updatedAt, progresses
        case detailURL
        /// 老格式平铺的两个字段，只为读；写出去的键里没有它们。
        case legacyProgressSeconds = "progressSeconds"
        case legacyRoadIndex = "roadIndex"
    }

    /// 写出去的键跟合成实现完全一样（多出来的两个老格式键只进读、不进写）；
    /// `detailURL` 仅在非空时写出，保持旧格式兼容与体积精简。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bangumiID, forKey: .bangumiID)
        try container.encode(bangumiName, forKey: .bangumiName)
        try container.encode(imageURL, forKey: .imageURL)
        try container.encode(sourceRuleName, forKey: .sourceRuleName)
        try container.encode(episodeTitle, forKey: .episodeTitle)
        try container.encode(episodeNumber, forKey: .episodeNumber)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(progresses, forKey: .progresses)
        try container.encodeIfPresent(detailURL, forKey: .detailURL)
    }
}

/// 追番列表与历史的可观察快照。
/// 本端取消过的收藏：番剧 ID + 取消时刻。
///
/// 合并时按时间比：取消比收藏晚就删掉，云盘上还留着的那条不会把收藏「复活」。
/// 跟着 WebDAV 备份一起走，别的设备也能看到这次取消。
struct RemovedEntry: Codable, Hashable, Sendable {
    var id: Int
    var removedAt: Date
}

///
/// 持久化对应原版的 Hive box（`collect` / `history`）：这里换成
/// Application Support/Kazumi/library.json 这一个文件，字段与
/// WebDAV 备份（`WebDAVClient.Payload`）保持一致，备份恢复时直接覆盖即可。
/// 落盘用的容器；`version` 与 WebDAV 备份一样从 1 起。
private struct LibrarySnapshot: Codable, Sendable {
    var version: Int = 1
    var savedAt: Date = Date()
    var entries: [LibraryEntry]
    var history: [WatchRecord]
    var removedEntries: [RemovedEntry]?
}

/// 后台串行落盘执行器：复用单个 `JSONEncoder` 并在独立 actor 上执行原子写盘，
/// 避免主线程承担整份追番/历史 JSON 编码与同步磁盘 I/O。
private actor LibraryPersistenceActor {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private var ensuredDirectory: URL?
    private var lastWrittenGeneration: UInt64 = 0

    func write(_ snapshot: LibrarySnapshot, to fileURL: URL, generation: UInt64) {
        guard generation >= lastWrittenGeneration else { return }
        lastWrittenGeneration = generation
        do {
            let directory = fileURL.deletingLastPathComponent()
            if ensuredDirectory != directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                ensuredDirectory = directory
            }
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            ensuredDirectory = nil
            KazumiLog.storage.error(
                "Library: 写入失败 \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

@MainActor
@Observable
final class LibraryStore {
    private struct DecodedPayload: Sendable {
        let entries: [LibraryEntry]
        let history: [WatchRecord]
        let removedEntries: [RemovedEntry]
    }

    /// 追番 / 观看历史的存储文件：Application Support/Kazumi/library.json。
    static var defaultFileURL: URL {
        AppEnvironment.storageRoot.appending(path: "library.json")
    }

    private(set) var entries: [LibraryEntry] = []
    private(set) var history: [WatchRecord] = []
    /// 取消过的收藏（ID + 时刻）。旧版没有这份记录，取消会被云盘「复活」，所以要自己记。
    private(set) var removedEntries: [RemovedEntry] = []

    /// 「在看」列表变动时的回调，用于自动重排本地更新提醒。
    @ObservationIgnored var onWatchingChanged: (() -> Void)?

    // MARK: - 辅助索引（O(1) 查询）
    @ObservationIgnored private var entryIndexByID: [Int: Int] = [:]
    @ObservationIgnored private var historyIndexByID: [String: Int] = [:]
    @ObservationIgnored private var latestHistoryByBangumiID: [Int: WatchRecord] = [:]

    // MARK: - 异步加载与串行落盘状态
    @ObservationIgnored private let persistence = LibraryPersistenceActor()
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
    @ObservationIgnored private var latestSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveGeneration: UInt64 = 0
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private let fileURL: URL

    init(fileURL: URL = LibraryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// 正在追的番（对应 main.dart 的 _watchingBangumis）。
    var watchingEntries: [LibraryEntry] {
        entries.filter { $0.collectType == .watching }
    }

    /// 继续观看：按更新时间倒序、去掉已看完的记录。
    var upNext: [WatchRecord] {
        history
            .filter { !$0.isFinished && $0.progressSeconds > 5 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func entry(for bangumiID: Int) -> LibraryEntry? {
        // 先触达被观察属性 `entries`，确保目标尚未收藏（索引返回 nil）或异步加载完成前，
        // SwiftUI 视图仍能注册 Observation 依赖，收藏状态变化时立即刷新（如详情页追番胶囊）。
        let currentEntries = entries
        guard let index = entryIndexByID[bangumiID], index < currentEntries.count else { return nil }
        return currentEntries[index]
    }

    /// 这部剧在这条规则上接着看的位置：第几集 + 第几条线路。没有记录就是 nil。
    ///
    /// 键是「这部剧 + 这条规则名」，跟 main 的 `lastWatching(bangumiItem, adapterName)`
    /// 一致（LP 4844「续播按 main 的方法」）：不同源的集数编号不一定一样，不跨源记。
    /// 越界（线路不够、集数超过那条线路的长度）由播放器判，判不成立就整条不用。
    func resumePoint(for bangumiID: Int, pluginName: String) -> (episode: Int, road: Int)? {
        guard let record = self.record(for: bangumiID, pluginName: pluginName),
              record.episodeNumber > 0 else { return nil }
        return (record.episodeNumber, record.roadIndex)
    }

    /// 这部剧最近看的那一条记录（跨规则取 `updatedAt` 最新的那一份）。
    ///
    /// 详情页 / 播放器只关心「这部剧看到哪儿了」，规则名不同就比不出来，
    /// 所以这里不限定规则，跟老格式「一部番只有一条记录」时的结果一致。
    func record(for bangumiID: Int) -> WatchRecord? {
        // 先触达 `history` 注册 Observation 依赖，避免只读 @ObservationIgnored 索引导致视图不刷新。
        _ = history
        return latestHistoryByBangumiID[bangumiID]
    }

    /// 这部剧在这条规则上的那一份记录。
    func record(for bangumiID: Int, pluginName: String) -> WatchRecord? {
        let currentHistory = history
        let key = "\(pluginName)\(bangumiID)::online"
        guard let index = historyIndexByID[key], index < currentHistory.count else { return nil }
        return currentHistory[index]
    }

    /// 最近看过的 N 部番剧（与「我的」页观看历史卡片同一口径：按 `updatedAt` 倒序、按 `bangumiID` 去重）。
    /// 单趟 O(M) Top-K 扫描，避免每次访问都全量排序。
    func recentTopRecords(limit: Int = 3) -> [WatchRecord] {
        _ = history
        guard limit > 0, !latestHistoryByBangumiID.isEmpty else { return [] }
        var picked: [WatchRecord] = []
        picked.reserveCapacity(min(limit, latestHistoryByBangumiID.count))
        for record in latestHistoryByBangumiID.values {
            if picked.count == limit, let tail = picked.last, record.updatedAt <= tail.updatedAt {
                continue
            }
            var insertAt = picked.count
            while insertAt > 0, record.updatedAt > picked[insertAt - 1].updatedAt {
                insertAt -= 1
            }
            if insertAt < limit {
                picked.insert(record, at: insertAt)
                if picked.count > limit {
                    picked.removeLast()
                }
            }
        }
        return picked
    }

    /// 严格约束（U1）：只保留「我的」页观看历史下方最近 3 部番剧各自最新观看来源的 `detailURL`，
    /// 其余记录（含前 3 部番剧的旧来源记录与第 4 部及以后记录）全部清空为 `nil`。
    private func pruneRecentDetailURLs(limit: Int = 3) {
        let keepIDs = Set(recentTopRecords(limit: limit).map(\.id))
        for idx in history.indices {
            if !keepIDs.contains(history[idx].id), history[idx].detailURL != nil {
                history[idx].detailURL = nil
                let updated = history[idx]
                if latestHistoryByBangumiID[updated.bangumiID]?.id == updated.id {
                    latestHistoryByBangumiID[updated.bangumiID] = updated
                }
            }
        }
    }

    // MARK: - 索引维护

    private func rebuildEntryIndex() {
        entryIndexByID = Dictionary(minimumCapacity: entries.count)
        for (idx, entry) in entries.enumerated() {
            entryIndexByID[entry.id] = idx
        }
    }

    private func rebuildHistoryIndices() {
        historyIndexByID = Dictionary(minimumCapacity: history.count)
        latestHistoryByBangumiID = [:]
        for (idx, record) in history.enumerated() {
            historyIndexByID[record.id] = idx
            if let existing = latestHistoryByBangumiID[record.bangumiID] {
                if record.updatedAt > existing.updatedAt {
                    latestHistoryByBangumiID[record.bangumiID] = record
                }
            } else {
                latestHistoryByBangumiID[record.bangumiID] = record
            }
        }
    }

    private func updateLatestHistory(for record: WatchRecord) {
        if let existing = latestHistoryByBangumiID[record.bangumiID] {
            if record.id == existing.id {
                if record.updatedAt >= existing.updatedAt {
                    latestHistoryByBangumiID[record.bangumiID] = record
                } else {
                    recomputeLatestHistory(for: record.bangumiID)
                }
            } else if record.updatedAt > existing.updatedAt {
                latestHistoryByBangumiID[record.bangumiID] = record
            }
        } else {
            latestHistoryByBangumiID[record.bangumiID] = record
        }
    }

    private func recomputeLatestHistory(for bangumiID: Int) {
        var best: WatchRecord?
        for record in history where record.bangumiID == bangumiID {
            if let current = best {
                if record.updatedAt > current.updatedAt { best = record }
            } else {
                best = record
            }
        }
        latestHistoryByBangumiID[bangumiID] = best
    }

    /// 写一次播放进度（播放器唯一该用的入口）。
    ///
    /// 找到（或新建）「这条规则 + 这部番」那一份记录：
    /// * 这一集的进度按 `updatedAt` 比，新的才盖（换集重播时写回来的旧事件不盖掉新进度）；
    /// * 最后看的那一集、集数、集标题、时间、时长跟着这次写；
    /// * 番剧名 / 封面只在还空着的时候填（Colo 3554：不拿空的把已有值冲掉）；
    /// * `detailURL` 仅对「我的」页最近 3 部番剧的最新来源保留，其余自动裁剪。
    /// 老格式那部番在别的规则上留下的记录不受影响，也不删。
    func recordWatch(
        bangumiID: Int,
        bangumiName: String,
        imageURL: String,
        pluginName: String,
        episodeNumber: Int,
        episodeTitle: String,
        road: Int,
        position: Double,
        duration: Double,
        detailURL: String? = nil,
        at date: Date = Date()
    ) {
        let slot = String(episodeNumber)
        let exactKey = "\(pluginName)\(bangumiID)::online"
        // 先找「这条规则 + 这部番」那一份（O(1) 索引查找）。
        var storedIndex: Int? = historyIndexByID[exactKey].flatMap { $0 < history.count ? $0 : nil }
        if storedIndex == nil, !pluginName.isEmpty {
            // 迁移过来的老格式记录没存来源规则（空串）。这次播放用的规则就是它的来源，
            // 认下来沿用那一份；不认的话同一部番会在历史列表里出现两遍。
            let emptyKey = "\(bangumiID)::online"
            if let legacyIndex = historyIndexByID[emptyKey], legacyIndex < history.count {
                storedIndex = legacyIndex
            }
        }
        let previousID = storedIndex.map { history[$0].id }
        var record = storedIndex.map { history[$0] } ?? WatchRecord(
            bangumiID: bangumiID,
            bangumiName: bangumiName,
            imageURL: imageURL,
            sourceRuleName: pluginName,
            episodeTitle: episodeTitle,
            episodeNumber: episodeNumber,
            durationSeconds: duration,
            updatedAt: date,
            progresses: [:]
        )
        if record.sourceRuleName.isEmpty { record.sourceRuleName = pluginName }
        if let existing = record.progresses[slot], existing.updatedAt > date {
            // 这一集已经有更新的进度：这次只是补最后看的那一集 / 时间，不盖进度。
        } else {
            record.progresses[slot] = EpisodeProgress(
                episode: episodeNumber,
                road: road,
                progressSeconds: position,
                updatedAt: date
            )
        }
        record.episodeNumber = episodeNumber
        record.episodeTitle = episodeTitle
        record.updatedAt = date
        record.durationSeconds = duration
        if record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !bangumiName.isEmpty {
            record.bangumiName = bangumiName
        }
        if record.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !imageURL.isEmpty {
            record.imageURL = imageURL
        }
        if let trimmedURL = detailURL?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedURL.isEmpty {
            record.detailURL = trimmedURL
        }
        if let storedIndex {
            history[storedIndex] = record
            if let previousID, previousID != record.id {
                historyIndexByID.removeValue(forKey: previousID)
                historyIndexByID[record.id] = storedIndex
            }
            updateLatestHistory(for: record)
        } else if let index = historyIndexByID[record.id], index < history.count {
            history[index] = record
            updateLatestHistory(for: record)
        } else {
            history.insert(record, at: 0)
            rebuildHistoryIndices()
        }
        pruneRecentDetailURLs(limit: 3)
        save(debounce: true)
    }

    // MARK: - 持久化

    /// 启动时同步读回上次的追番与历史（保留给单测及快捷指令意图调用）；文件不存在或损坏时保持空表。
    func load() {
        hasLoaded = true
        if let decoded = Self.readAndDecodeSnapshot(from: fileURL) {
            entries = decoded.entries
            history = decoded.history
            removedEntries = decoded.removedEntries
            rebuildEntryIndex()
            rebuildHistoryIndices()
            pruneRecentDetailURLs(limit: 3)
            KazumiLog.storage.info(
                "Library: 载入 \(self.entries.count, privacy: .public) 条追番 / \(self.history.count, privacy: .public) 条历史"
            )
        } else {
            entries = []
            history = []
            removedEntries = []
            rebuildEntryIndex()
            rebuildHistoryIndices()
        }
    }

    /// 异步读盘加载：在后台完成读盘、JSON 解码与去重，再切回 `@MainActor` 写入快照并建立索引。
    func loadAsync() async {
        if hasLoaded { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let url = fileURL
        let task = Task { @MainActor [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.readAndDecodeSnapshot(from: url)
            }.value
            guard let self else { return }
            self.hasLoaded = true
            if let decoded {
                // 若异步载入期间本机已有写入，合并而非覆盖用户刚产生的变更。
                if self.entries.isEmpty && self.history.isEmpty && self.removedEntries.isEmpty {
                    self.entries = decoded.entries
                    self.history = decoded.history
                    self.removedEntries = decoded.removedEntries
                } else {
                    self.entries = Self.deduplicated(decoded.entries + self.entries)
                    self.history = Self.deduplicated(decoded.history + self.history)
                    var removalByID: [Int: RemovedEntry] = [:]
                    for item in decoded.removedEntries + self.removedEntries {
                        if let existing = removalByID[item.id], existing.removedAt >= item.removedAt {
                            continue
                        }
                        removalByID[item.id] = item
                    }
                    let collected = Set(self.entries.map(\.id))
                    self.removedEntries = removalByID.values.filter { !collected.contains($0.id) }
                }
                self.rebuildEntryIndex()
                self.rebuildHistoryIndices()
                self.pruneRecentDetailURLs(limit: 3)
                KazumiLog.storage.info(
                    "Library: 载入 \(self.entries.count, privacy: .public) 条追番 / \(self.history.count, privacy: .public) 条历史"
                )
            } else if self.entries.isEmpty && self.history.isEmpty {
                self.entries = []
                self.history = []
                self.rebuildEntryIndex()
                self.rebuildHistoryIndices()
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    nonisolated private static func readAndDecodeSnapshot(from fileURL: URL) -> DecodedPayload? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return DecodedPayload(entries: [], history: [], removedEntries: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder().decode(LibrarySnapshot.self, from: data)
            // 读回时就收敛重复 ID：旧版本可能已经写进过重复记录，
            // 展示层拿到的必须是一份干净的、ID 唯一的数据。
            return DecodedPayload(
                entries: deduplicated(snapshot.entries),
                history: deduplicated(snapshot.history),
                removedEntries: snapshot.removedEntries ?? []
            )
        } catch {
            // 文件损坏时不阻塞启动：从空表开始，下次写入会覆盖掉坏文件。
            KazumiLog.storage.error(
                "Library: 读取失败 \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// 立即将防抖缓冲中的变更投递到后台串行落盘队列（供退后台 / 失活调用，避免 500ms 窗口内丢进度）。
    func flush() {
        guard pendingSaveTask != nil else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveNow()
    }

    /// 立即触发待落盘变更并等待后台串行落盘任务排空完成。
    func flushAndWait() async {
        flush()
        await latestSaveTask?.value
    }

    /// 写回磁盘。默认立即投递后台落盘；高频写入（如播放中定期落进度）支持 500ms 防抖，
    /// 避免密集触发整份 JSON 编码与磁盘 I/O。
    private func save(debounce: Bool = false) {
        if debounce {
            pendingSaveTask?.cancel()
            pendingSaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.pendingSaveTask = nil
                self?.saveNow()
            }
        } else {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            saveNow()
        }
    }

    private func saveNow() {
        saveGeneration &+= 1
        let generation = saveGeneration
        let snapshot = LibrarySnapshot(
            entries: entries,
            history: history,
            removedEntries: removedEntries
        )
        let url = fileURL
        let actor = persistence
        let previous = latestSaveTask
        latestSaveTask = Task.detached(priority: .utility) {
            await previous?.value
            await actor.write(snapshot, to: url, generation: generation)
        }
    }

    // MARK: - 变更

    private struct WatchingSignatureItem: Equatable {
        let id: Int
        let displayName: String
        let airDate: String
        let totalEpisodes: Int
    }

    private var watchingSignature: [WatchingSignatureItem] {
        entries.compactMap { entry in
            guard entry.collectType == .watching else { return nil }
            return WatchingSignatureItem(
                id: entry.id,
                displayName: entry.displayName,
                airDate: entry.airDate,
                totalEpisodes: entry.totalEpisodes
            )
        }
    }

    func replace(
        entries: [LibraryEntry],
        history: [WatchRecord],
        removals: [RemovedEntry]? = nil
    ) {
        let previousWatching = watchingSignature
        self.entries = Self.deduplicated(entries)
        self.history = Self.deduplicated(history)
        rebuildEntryIndex()
        rebuildHistoryIndices()
        pruneRecentDetailURLs(limit: 3)
        if let removals {
            let collected = Set(self.entries.map(\.id))
            self.removedEntries = removals.filter { !collected.contains($0.id) }
        }
        save()
        if watchingSignature != previousWatching {
            onWatchingChanged?()
        }
    }

    /// 同步把合并后的取消记录写回本机。收藏重新加回来的那些不再需要记着。
    func replaceRemovals(_ removals: [RemovedEntry]) {
        let collected = Set(entries.map(\.id))
        removedEntries = removals.filter { !collected.contains($0.id) }
        save()
    }

    func upsert(_ entry: LibraryEntry) {
        let previousWatching = watchingSignature
        // 重新收藏回来了：之前那条取消记录作废。
        if removedEntries.contains(where: { $0.id == entry.id }) {
            removedEntries.removeAll { $0.id == entry.id }
        }
        if let index = entryIndexByID[entry.id], index < entries.count {
            entries[index] = entry
        } else {
            entryIndexByID[entry.id] = entries.count
            entries.append(entry)
        }
        save()
        if watchingSignature != previousWatching {
            onWatchingChanged?()
        }
    }

    /// 批量更新追番条目，只落盘一次，避免上百条记录逐条落盘卡死主线程。
    func upsertMany(_ newEntries: [LibraryEntry]) {
        guard !newEntries.isEmpty else { return }
        let previousWatching = watchingSignature
        let newIDs = Set(newEntries.map(\.id))
        removedEntries.removeAll { newIDs.contains($0.id) }

        var entryMap: [Int: LibraryEntry] = [:]
        for entry in entries {
            entryMap[entry.id] = entry
        }
        for entry in newEntries {
            entryMap[entry.id] = entry
        }

        var result: [LibraryEntry] = []
        var seen = Set<Int>()
        for entry in entries {
            if let updated = entryMap[entry.id], seen.insert(entry.id).inserted {
                result.append(updated)
            }
        }
        for entry in newEntries {
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        self.entries = result
        rebuildEntryIndex()
        save()
        if watchingSignature != previousWatching {
            onWatchingChanged?()
        }
    }

    func remove(bangumiID: Int) {
        let previousWatching = watchingSignature
        entries.removeAll { $0.id == bangumiID }
        rebuildEntryIndex()
        // 记下取消的时刻：不带这一条，下次同步就会从云盘把它加回来。
        removedEntries.removeAll { $0.id == bangumiID }
        removedEntries.append(RemovedEntry(id: bangumiID, removedAt: Date()))
        save()
        if watchingSignature != previousWatching {
            onWatchingChanged?()
        }
    }

    /// 写一条观看记录。同一条（规则 + 番剧）已经有一份时并起来：
    /// `progresses` 求并集、同一集新的赢，最后看的那一集取 `updatedAt` 新的那整条；
    /// 不是拿新的整条盖掉旧的——那样会把这部番看过的其它集的进度抹了
    /// （main 那边一条记录里就装着每一集的进度）。
    func upsert(_ record: WatchRecord) {
        if let index = historyIndexByID[record.id], index < history.count {
            let mergedRecord = Self.merged(history[index], record)
            history[index] = mergedRecord
            updateLatestHistory(for: mergedRecord)
        } else {
            history.insert(record, at: 0)
            rebuildHistoryIndices()
        }
        pruneRecentDetailURLs(limit: 3)
        save()
    }

    /// 只补空着的名字 / 封面，别的字段（进度、集数、时间）一律不动。
    ///
    /// 同一部番在不同规则下可能是好几份记录，名字和封面几份都要补上：
    /// 少补一份，历史列表里就还是有一张空占位框（Colo 3566）。
    func backfillHistoryMeta(bangumiID: Int, name: String, imageURL: String) {
        var changed = false
        for (index, stored) in history.enumerated() where stored.bangumiID == bangumiID {
            var record = stored
            var dirty = false
            if record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.isEmpty {
                record.bangumiName = name
                dirty = true
            }
            if record.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !imageURL.isEmpty {
                record.imageURL = imageURL
                dirty = true
            }
            if dirty {
                history[index] = record
                if latestHistoryByBangumiID[bangumiID]?.id == record.id {
                    latestHistoryByBangumiID[bangumiID] = record
                }
                changed = true
            }
        }
        if changed { save() }
    }

    /// 只删这一份记录（规则 + 番剧那一条）。
    ///
    /// 同一部番在别的规则下那份不该跟着走：用户删的是这一条来源的记录。
    func removeHistory(recordID: String) {
        history.removeAll { $0.id == recordID }
        rebuildHistoryIndices()
        pruneRecentDetailURLs(limit: 3)
        save()
    }

    func removeHistory(recordIDs: Set<String>) {
        history.removeAll { recordIDs.contains($0.id) }
        rebuildHistoryIndices()
        pruneRecentDetailURLs(limit: 3)
        save()
    }

    /// 删掉这部剧的全部记录（不分规则）。
    func removeHistory(bangumiID: Int) {
        history.removeAll { $0.bangumiID == bangumiID }
        rebuildHistoryIndices()
        pruneRecentDetailURLs(limit: 3)
        save()
    }

    // MARK: - 去重

    /// 按 ID 去重，保留更新时间较新的那一条（顺序取首次出现的位置）。
    ///
    /// 追番与历史都是以番剧 ID 为主键的表：WebDAV 恢复、Bangumi 同步与本地写入
    /// 三条路径都可能带进同一 ID 的两条记录。SwiftUI 的 `ForEach` 用 ID 做
    /// 身份，重复 ID 会让列表的差量更新错乱（表现为切换筛选后闪退），
    /// 因此在数据进入 store 的那一刻就收敛掉。
    nonisolated static func deduplicated(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        var indexByID: [Int: Int] = [:]
        var result: [LibraryEntry] = []
        for entry in entries {
            if let index = indexByID[entry.id] {
                if entry.updatedAt > result[index].updatedAt {
                    result[index] = entry
                }
            } else {
                indexByID[entry.id] = result.count
                result.append(entry)
            }
        }
        return result
    }

    nonisolated static func deduplicated(_ history: [WatchRecord]) -> [WatchRecord] {
        var indexByID: [String: Int] = [:]
        var result: [WatchRecord] = []
        for record in history {
            if let index = indexByID[record.id] {
                // 同一「规则 + 番剧」的两份（旧版留下的、恢复备份带进来的）并成一份：
                // 丢一份就等于丢这部番看过的那些集的进度，不能丢。
                result[index] = merged(result[index], record)
            } else {
                indexByID[record.id] = result.count
                result.append(record)
            }
        }
        return result
    }

    /// 两份同「规则 + 番剧」的记录并成一份。
    ///
    /// `progresses` 求并集，同一集里 `updatedAt` 新的那条赢（main 的
    /// `HistorySyncCodec` 也是按每个 progress 的版本单独比的）；
    /// 最后看的那一集（集数、集标题、时间、名字、封面、时长）取自 `updatedAt`
    /// 新的那整条，这样列表上显示的「看到哪儿了」跟用户最后一次看的一致。
    nonisolated static func merged(_ lhs: WatchRecord, _ rhs: WatchRecord) -> WatchRecord {
        let (base, other) = lhs.updatedAt > rhs.updatedAt ? (lhs, rhs) : (rhs, lhs)
        var record = base
        if (record.detailURL ?? "").isEmpty, let otherURL = other.detailURL, !otherURL.isEmpty {
            record.detailURL = otherURL
        }
        for (slot, progress) in other.progresses {
            guard let kept = record.progresses[slot] else {
                record.progresses[slot] = progress
                continue
            }
            if progress.updatedAt > kept.updatedAt {
                record.progresses[slot] = progress
            }
        }
        return record
    }

    // MARK: - 编解码

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
