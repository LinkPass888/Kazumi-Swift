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
        case .none: "未收藏"
        case .watching: "在看"
        case .wish: "想看"
        case .onHold: "搁置"
        case .watched: "看过"
        case .dropped: "抛弃"
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
        case .none: "未追"
        case .watching: "在看"
        case .wish: "想看"
        case .onHold: "搁置"
        case .watched: "看过"
        case .dropped: "抛弃"
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

    init(
        bangumiID: Int,
        bangumiName: String,
        imageURL: String,
        sourceRuleName: String,
        episodeTitle: String,
        episodeNumber: Int,
        durationSeconds: Double,
        updatedAt: Date,
        progresses: [String: EpisodeProgress] = [:]
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
        return "看到 " + WatchRecord.clock(progressSeconds)
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
    }

    private enum CodingKeys: String, CodingKey {
        case bangumiID, bangumiName, imageURL, sourceRuleName
        case episodeTitle, episodeNumber, durationSeconds, updatedAt, progresses
        /// 老格式平铺的两个字段，只为读；写出去的键里没有它们。
        case legacyProgressSeconds = "progressSeconds"
        case legacyRoadIndex = "roadIndex"
    }

    /// 写出去的键跟合成实现完全一样（多出来的两个老格式键只进读、不进写）。
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
@MainActor
@Observable
final class LibraryStore {
    /// 落盘用的容器；`version` 与 WebDAV 备份一样从 1 起。
    private struct Snapshot: Codable, Sendable {
        var version: Int = 1
        var savedAt: Date = Date()
        var entries: [LibraryEntry]
        var history: [WatchRecord]
        var removedEntries: [RemovedEntry]?
    }

    /// 追番 / 观看历史的存储文件：Application Support/Kazumi/library.json。
    static var defaultFileURL: URL {
        AppEnvironment.storageRoot.appending(path: "library.json")
    }

    private(set) var entries: [LibraryEntry] = []
    private(set) var history: [WatchRecord] = []
    /// 取消过的收藏（ID + 时刻）。旧版没有这份记录，取消会被云盘「复活」，所以要自己记。
    private(set) var removedEntries: [RemovedEntry] = []

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
        entries.first { $0.id == bangumiID }
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
        history.filter { $0.bangumiID == bangumiID }.max { $0.updatedAt < $1.updatedAt }
    }

    /// 这部剧在这条规则上的那一份记录。
    func record(for bangumiID: Int, pluginName: String) -> WatchRecord? {
        history.first { $0.bangumiID == bangumiID && $0.sourceRuleName == pluginName }
    }

    /// 写一次播放进度（播放器唯一该用的入口）。
    ///
    /// 找到（或新建）「这条规则 + 这部番」那一份记录：
    /// * 这一集的进度按 `updatedAt` 比，新的才盖（换集重播时写回来的旧事件不盖掉新进度）；
    /// * 最后看的那一集、集数、集标题、时间、时长跟着这次写；
    /// * 番剧名 / 封面只在还空着的时候填（Colo 3554：不拿空的把已有值冲掉）。
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
        at date: Date = Date()
    ) {
        let slot = String(episodeNumber)
        // 先找「这条规则 + 这部番」那一份。
        var storedIndex = history.firstIndex {
            $0.bangumiID == bangumiID && $0.sourceRuleName == pluginName
        }
        if storedIndex == nil, !pluginName.isEmpty {
            // 迁移过来的老格式记录没存来源规则（空串）。这次播放用的规则就是它的来源，
            // 认下来沿用那一份；不认的话同一部番会在历史列表里出现两遍。
            let emptyRule = history.indices.filter {
                history[$0].bangumiID == bangumiID && history[$0].sourceRuleName.isEmpty
            }
            if emptyRule.count == 1 { storedIndex = emptyRule[0] }
        }
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
        if let storedIndex {
            history[storedIndex] = record
        } else if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index] = record
        } else {
            history.insert(record, at: 0)
        }
        save()
    }

    // MARK: - 持久化

    /// 启动时读回上次的追番与历史；文件不存在或损坏时保持空表。
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            entries = []
            history = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try Self.decoder().decode(Snapshot.self, from: data)
            // 读回时就收敛重复 ID：旧版本可能已经写进过重复记录，
            // 展示层拿到的必须是一份干净的、ID 唯一的数据。
            entries = Self.deduplicated(snapshot.entries)
            history = Self.deduplicated(snapshot.history)
            removedEntries = snapshot.removedEntries ?? []
            KazumiLog.storage.info(
                "Library: 载入 \(self.entries.count, privacy: .public) 条追番 / \(self.history.count, privacy: .public) 条历史"
            )
        } catch {
            // 文件损坏时不阻塞启动：从空表开始，下次写入会覆盖掉坏文件。
            KazumiLog.storage.error(
                "Library: 读取失败 \(error.localizedDescription, privacy: .public)"
            )
            entries = []
            history = []
        }
    }

    /// 写回磁盘。数据量很小（几百条），同步写 + `.atomic` 足够快，
    /// 也不用担心后台任务还没落地就被系统杀掉。
    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = Snapshot(entries: entries, history: history, removedEntries: removedEntries)
            try Self.encoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            KazumiLog.storage.error(
                "Library: 写入失败 \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - 变更

    func replace(entries: [LibraryEntry], history: [WatchRecord]) {
        self.entries = Self.deduplicated(entries)
        self.history = Self.deduplicated(history)
        save()
    }

    /// 同步把合并后的取消记录写回本机。收藏重新加回来的那些不再需要记着。
    func replaceRemovals(_ removals: [RemovedEntry]) {
        let collected = Set(entries.map(\.id))
        removedEntries = removals.filter { !collected.contains($0.id) }
        save()
    }

    func upsert(_ entry: LibraryEntry) {
        // 重新收藏回来了：之前那条取消记录作废。
        if removedEntries.contains(where: { $0.id == entry.id }) {
            removedEntries.removeAll { $0.id == entry.id }
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            // 同一部番如果因为合并 / 恢复被写进多份，这里顺手并掉多余的几份：
            // `ForEach` 遇到重复 ID 会直接崩溃，列表里也会出现两张一样的卡片。
            entries = Self.deduplicated(entries)
        } else {
            entries.append(entry)
        }
        save()
    }

    func remove(bangumiID: Int) {
        entries.removeAll { $0.id == bangumiID }
        // 记下取消的时刻：不带这一条，下次同步就会从云盘把它加回来。
        removedEntries.removeAll { $0.id == bangumiID }
        removedEntries.append(RemovedEntry(id: bangumiID, removedAt: Date()))
        save()
    }

    /// 写一条观看记录。同一条（规则 + 番剧）已经有一份时并起来：
    /// `progresses` 求并集、同一集新的赢，最后看的那一集取 `updatedAt` 新的那整条；
    /// 不是拿新的整条盖掉旧的——那样会把这部番看过的其它集的进度抹了
    /// （main 那边一条记录里就装着每一集的进度）。
    func upsert(_ record: WatchRecord) {
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index] = Self.merged(history[index], record)
        } else {
            history.insert(record, at: 0)
        }
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
        save()
    }

    func removeHistory(recordIDs: Set<String>) {
        history.removeAll { recordIDs.contains($0.id) }
        save()
    }

    /// 删掉这部剧的全部记录（不分规则）。
    func removeHistory(bangumiID: Int) {
        history.removeAll { $0.bangumiID == bangumiID }
        save()
    }

    // MARK: - 去重

    /// 按 ID 去重，保留更新时间较新的那一条（顺序取首次出现的位置）。
    ///
    /// 追番与历史都是以番剧 ID 为主键的表：WebDAV 恢复、Bangumi 同步与本地写入
    /// 三条路径都可能带进同一 ID 的两条记录。SwiftUI 的 `ForEach` 用 ID 做
    /// 身份，重复 ID 会让列表的差量更新错乱（表现为切换筛选后闪退），
    /// 因此在数据进入 store 的那一刻就收敛掉。
    static func deduplicated(_ entries: [LibraryEntry]) -> [LibraryEntry] {
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

    static func deduplicated(_ history: [WatchRecord]) -> [WatchRecord] {
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
    static func merged(_ lhs: WatchRecord, _ rhs: WatchRecord) -> WatchRecord {
        let (base, other) = lhs.updatedAt > rhs.updatedAt ? (lhs, rhs) : (rhs, lhs)
        var record = base
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

    /// 与 WebDAV 备份保持同一套日期编码（ISO 8601），
    /// 这样本地文件与备份文件可以互相替换、也能人工查看。
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
