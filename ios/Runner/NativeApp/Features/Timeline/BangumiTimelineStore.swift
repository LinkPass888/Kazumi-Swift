//
//  BangumiTimelineStore.swift
//  Kazumi
//
//  对应 lib/services/storage/bangumi_timeline_store.dart：
//  详情页里「放送星期」与「是否在时间表展示」的持久化，
//  以及把这两份用户设置合并进 7 天日历的规则。
//
//  存储格式与 Flutter 版逐字节兼容：键名 `bangumiTimelineEntries`，
//  值是 `{"<bangumiID>": {"weekday": 3, "show": true, "custom": true}}`，
//  其中 `custom` 只在用户点选过星期时出现。
//
//  注意：序列化必须走 Codable（键为 String）。早先的实现用
//  `JSONSerialization` 直接写 `[Int: [String: Any]]`，非字符串键会让
//  Foundation 抛 Objective-C 异常，Swift 侧无法捕获 —— 表现就是点一下
//  「在时间表展示」立刻闪退。
//

import Foundation
import Observation

/// 番剧时间表条目（对应 Dart 的 BangumiTimelineEntry）。
struct BangumiTimelineEntry: Codable, Hashable, Sendable {
    /// 放送星期（1 = 周一 ... 7 = 周日）。
    var weekday: Int
    /// 是否在时间表对应放送星期展示。
    var showInTimeline: Bool
    /// 星期是不是用户自己选的。
    ///
    /// 只打开「在时间表展示」时写进来的星期只是当时那部番所在的列，没有
    /// 「换列」的意思；用户点选过星期才会置上这个标记，时间表只按这个标记
    /// 挪番。
    var weekdayCustom: Bool

    init(weekday: Int, showInTimeline: Bool = false, weekdayCustom: Bool = false) {
        self.weekday = Self.normalize(weekday)
        self.showInTimeline = showInTimeline
        self.weekdayCustom = weekdayCustom
    }

    /// 把星期限制在 1...7，非法值按周一处理（对应 normalizeBangumiWeekday）。
    static func normalize(_ weekday: Int) -> Int {
        min(7, max(1, weekday))
    }

    /// 落盘用的键名与 Dart 的 toJson 一致：weekday / show / custom。
    private enum CodingKeys: String, CodingKey {
        case weekday
        case show
        case custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let weekday = try container.decodeIfPresent(Int.self, forKey: .weekday) ?? 1
        self.weekday = Self.normalize(weekday)
        self.showInTimeline = try container.decodeIfPresent(Bool.self, forKey: .show) ?? false
        self.weekdayCustom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weekday, forKey: .weekday)
        try container.encode(showInTimeline, forKey: .show)
        // 与 Dart 一致：没选过星期就不写这个键。
        if weekdayCustom {
            try container.encode(true, forKey: .custom)
        }
    }
}

/// 时间表自定义条目的持久化。
@MainActor
@Observable
final class BangumiTimelineStore {
    static let shared = BangumiTimelineStore()

    /// 与原版 `SettingsKeys.bangumiTimelineEntries` 同名，备份文件可直接互通。
    private static let storageKey = "kazumi.settings.bangumiTimelineEntries"
    /// 早期原生版用过的键（键名与字段名都不同），读取时做一次迁移。
    private static let legacyKey = "kazumi.timeline.entries"

    /// bangumiID -> 自定义信息。
    private(set) var entries: [Int: BangumiTimelineEntry] = [:]

    /// 每次写入 +1，供时间表页监听后立即重排。
    private(set) var revision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load(defaults)
    }

    func entry(for bangumiID: Int) -> BangumiTimelineEntry? {
        entries[bangumiID]
    }

    /// 用户手动点选过星期的条目：ID -> 星期。
    ///
    /// 这些番在时间表里要挪到用户指定的那一天，不管「在时间表展示」开没开
    /// —— 它本来就在日历里的话，改星期就是要挪列。
    var customWeekdays: [Int: Int] {
        entries.reduce(into: [Int: Int]()) { result, pair in
            guard pair.value.weekdayCustom else { return }
            result[pair.key] = BangumiTimelineEntry.normalize(pair.value.weekday)
        }
    }

    /// 打开了「在时间表展示」的条目：ID -> 星期。
    var shownWeekdays: [Int: Int] {
        entries.reduce(into: [Int: Int]()) { result, pair in
            guard pair.value.showInTimeline else { return }
            result[pair.key] = BangumiTimelineEntry.normalize(pair.value.weekday)
        }
    }

    /// 对应 setWeekday：手动指定放送星期。
    func setWeekday(_ weekday: Int, for bangumiID: Int) {
        var entry = entries[bangumiID] ?? BangumiTimelineEntry(weekday: weekday)
        entry.weekday = BangumiTimelineEntry.normalize(weekday)
        entry.weekdayCustom = true
        entries[bangumiID] = entry
        save()
    }

    /// 对应 setShowInTimeline：点亮 / 熄灭「在时间表展示」。
    ///
    /// `weekday` 只在新建条目时用作起点（调用方给的是这部番当前所在的列），
    /// 已有条目的星期属于用户设置，不在这里覆盖。
    func setShowInTimeline(_ value: Bool, for bangumiID: Int, weekday: Int) {
        var entry = entries[bangumiID] ?? BangumiTimelineEntry(weekday: weekday)
        entry.showInTimeline = value
        entries[bangumiID] = entry
        save()
    }

    /// 删除单条数据。
    func remove(_ bangumiID: Int) {
        guard entries.removeValue(forKey: bangumiID) != nil else { return }
        save()
    }

    /// 番剧不再处于「在看」时删除数据（对应 dropIfNotWatching）。
    func dropIfNotWatching(_ bangumiID: Int, collectType: CollectType) {
        guard collectType != .watching else { return }
        remove(bangumiID)
    }

    // MARK: - 合并

    /// 算出要挪进日历的番剧 ID -> 星期（对应 resolveTimelineWeekdays）。
    ///
    /// - 用户点选过星期的：只要这部番本来就在时间表里（日历里有，或者开了
    ///   「在时间表展示」）就立刻生效；不在时间表里的只记录星期，等用户点亮
    ///   图标再加进来。
    /// - 只开了「在时间表展示」的：本来就在日历里的保持原分组，只有不在
    ///   日历里的（手动添加的）才按记录的那天插进去，且只对「在看」保留。
    func resolveWeekdays(
        inCalendar: Set<Int>,
        collectTypes: [Int: CollectType]
    ) -> [Int: Int] {
        let shown = shownWeekdays
        var weekdays: [Int: Int] = [:]
        for (bangumiID, weekday) in customWeekdays {
            if !inCalendar.contains(bangumiID), shown[bangumiID] == nil { continue }
            weekdays[bangumiID] = weekday
        }
        for (bangumiID, weekday) in shown {
            if weekdays[bangumiID] != nil { continue }
            if inCalendar.contains(bangumiID) { continue }
            guard collectTypes[bangumiID] == .watching else { continue }
            weekdays[bangumiID] = weekday
        }
        return weekdays
    }

    // MARK: - 持久化

    private func save() {
        revision &+= 1
        let stored = entries.reduce(into: [String: BangumiTimelineEntry]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(_ defaults: UserDefaults) -> [Int: BangumiTimelineEntry] {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: BangumiTimelineEntry].self, from: data) {
            return normalizeKeys(decoded)
        }
        // 早期原生版的旧键：字段名是 weekday / weekdayCustom / showInTimeline。
        if let data = defaults.data(forKey: legacyKey) {
            let migrated = migrateLegacy(data)
            if !migrated.isEmpty {
                let stored = migrated.reduce(into: [String: BangumiTimelineEntry]()) { result, pair in
                    result[String(pair.key)] = pair.value
                }
                if let encoded = try? JSONEncoder().encode(stored) {
                    defaults.set(encoded, forKey: storageKey)
                }
            }
            return migrated
        }
        return [:]
    }

    private static func normalizeKeys(
        _ stored: [String: BangumiTimelineEntry]
    ) -> [Int: BangumiTimelineEntry] {
        stored.reduce(into: [Int: BangumiTimelineEntry]()) { result, pair in
            guard let id = Int(pair.key) else { return }
            result[id] = pair.value
        }
    }

    /// 旧格式：`{"<id>": {"weekday": 1, "weekdayCustom": false, "showInTimeline": true}}`。
    private static func migrateLegacy(_ data: Data) -> [Int: BangumiTimelineEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        var result: [Int: BangumiTimelineEntry] = [:]
        for (key, value) in root {
            guard let id = Int(key) else { continue }
            result[id] = BangumiTimelineEntry(
                weekday: value["weekday"] as? Int ?? 1,
                showInTimeline: value["showInTimeline"] as? Bool ?? false,
                weekdayCustom: value["weekdayCustom"] as? Bool ?? false
            )
        }
        return result
    }

}