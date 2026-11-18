//
//  TimelineCache.swift
//  Kazumi
//
//  时间表（七天的日历）落盘缓存。
//
//  为什么要有它（LP 5050 / 5051）：时间表原来每次冷启动都是「列表先清空 → 再等
//  日历接口 → 灰底一个转圈」，第一屏什么都没有。可这份日历一天最多变几条，
//  完全没必要每次都等网络。
//
//  存的是接口原始 JSON（每天的条目数组），读回来走同一套 `BangumiItem.fromJSON`，
//  与 `BangumiSubjectCache` 一个路子：不另立一套可能跟接口对不上的字段。
//
//  读取分两级：
//   * `memory()` 只碰内存，冷启动第一帧就能铺；
//   * `disk()` 才读盘，给「先铺占位再补」的路径用。
//

import Foundation

@MainActor
final class TimelineCache {
    static let shared = TimelineCache()

    private let directory: URL

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = support
            .appendingPathComponent("Kazumi", isDirectory: true)
            .appendingPathComponent("timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 键

    /// 当季与往期分开存：往期基本不变，当季天天在变。
    private func fileURL(currentSeason: Bool, seasonStart: String?) -> URL {
        let name: String
        if currentSeason {
            name = "current.json"
        } else {
            let raw = seasonStart ?? "unknown"
            name = "season-\(raw.replacingOccurrences(of: ":", with: "-")).json"
        }
        return directory.appendingPathComponent(name)
    }

    // MARK: - 存档（内存结构化快照 + 后台落盘）

    /// 当季内存快照：直接存已校验的 `[JSONValue]`，避免在主线程反复对几百 KB 字符串做 JSON 反解。
    private var memoryCurrentSeason: String?
    private var memoryCurrentDays: [JSONValue]?
    /// 往期季度内存缓存（`start -> rawDays`）。
    private var memorySeasonDays: [String: [JSONValue]] = [:]

    /// 记一份当季日历（`calendar()` 成功时调用）。
    /// `seasonStart` 是这一季的身份（`AnimeSeason.seasonRange().start`）：
    /// 存进去以后读的时候要验，不然跨季那天会把上一季那份当成当季铺出来（LP 5055）。
    func storeCurrent(rawDays: [JSONValue], seasonStart: String) {
        guard Self.isValidNonEmptyDays(rawDays) else {
            KazumiLogBuffer.shared.append(
                String(localized: "时间表缓存：这一份为空或结构无效，跳过"),
                category: .network
            )
            return
        }
        memoryCurrentSeason = seasonStart
        memoryCurrentDays = rawDays
        let targetURL = fileURL(currentSeason: true, seasonStart: nil)
        Self.writeAsync(rawDays: rawDays, season: seasonStart, to: targetURL)
    }

    /// 存往期季度。
    func storeSeason(rawDays: [JSONValue], start: String) {
        guard Self.isValidNonEmptyDays(rawDays) else { return }
        memorySeasonDays[start] = rawDays
        let targetURL = fileURL(currentSeason: false, seasonStart: start)
        Self.writeAsync(rawDays: rawDays, season: start, to: targetURL)
    }

    nonisolated private static func isValidNonEmptyDays(_ days: [JSONValue]) -> Bool {
        guard days.count == 7 else { return false }
        var hasContent = false
        for day in days {
            guard case let .array(items) = day else { return false }
            if !items.isEmpty { hasContent = true }
        }
        return hasContent
    }

    nonisolated private static func writeAsync(rawDays: [JSONValue], season: String, to url: URL) {
        Task.detached(priority: .utility) {
            let payload = JSONValue.object([
                "season": .string(season),
                "days": .array(rawDays),
            ])
            let text = JSONValue.serialize(payload, pretty: false)
            guard text != "{}" else { return }
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: - 取

    /// 当季的原始 JSON：先内存、再磁盘。取不到、或存的不是这一季，返回 nil。
    ///
    /// 为什么验季：缓存存的是「当季」这一份，跨季那天它还躺在那儿，
    /// 不验就会把上一季的番铺成这一季（LP 5055）。
    ///
    /// 读盘与解析放后台线程：冷启动第一帧走的就是这条路径，几百 KB 的 JSON
    /// 在主线程上读一遍、解一遍，首屏要多等一截。
    func currentRawDays(seasonStart: String) async -> [JSONValue]? {
        if memoryCurrentSeason == seasonStart, let days = memoryCurrentDays {
            return days
        }
        let url = fileURL(currentSeason: true, seasonStart: nil)
        let read = await Task.detached(priority: .userInitiated) {
            Self.readDays(at: url, seasonStart: seasonStart)
        }.value
        switch read {
        case let .ok(days):
            memoryCurrentSeason = seasonStart
            memoryCurrentDays = days
            return days
        case .stale:
            // 跨季了：旧那份已经没用，不要留着占内存、也不要每次启动再试一次。
            memoryCurrentSeason = nil
            memoryCurrentDays = nil
            try? FileManager.default.removeItem(at: url)
            return nil
        case .missing:
            return nil
        }
    }

    /// 读盘结果：`stale` 是「文件在、但不是这一季」（要清掉），`missing` 是根本没有。
    private enum DiskRead: Sendable {
        case missing
        case stale
        case ok(days: [JSONValue])
    }

    /// 读盘 + 解析。不碰实例状态，所以可以放后台线程。
    nonisolated private static func readDays(at url: URL, seasonStart: String) -> DiskRead {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        let text = String(decoding: data, as: UTF8.self)
        guard let days = decodeDays(text, expectedSeason: seasonStart) else { return .stale }
        return .ok(days: days)
    }

    /// 快捷指令只读磁盘快照，不刷新、不删除跨季缓存，也不把读取时刻冒充保存时刻。
    func localCurrentSnapshot(seasonStart: String) -> (days: [JSONValue], savedAt: Date?)? {
        let url = fileURL(currentSeason: true, seasonStart: nil)
        guard let data = try? Data(contentsOf: url),
              case let .object(root)? = try? JSONValue.decode(String(decoding: data, as: UTF8.self)),
              case let .string(season)? = root["season"], season == seasonStart,
              case let .array(days)? = root["days"], days.count == 7,
              days.allSatisfy({ if case .array = $0 { return true }; return false })
        else { return nil }
        // 与页面的“全空就刷新”策略分开：只读指令应区分有效空缓存与没有缓存。
        let savedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (days, savedAt)
    }

    /// 往期季度的原始 JSON：先查内存，未命中时在后台线程读盘并解码。
    func seasonRawDays(start: String) async -> [JSONValue]? {
        if let cached = memorySeasonDays[start] {
            return cached
        }
        let url = fileURL(currentSeason: false, seasonStart: start)
        let read = await Task.detached(priority: .userInitiated) {
            Self.readDays(at: url, seasonStart: start)
        }.value
        guard case let .ok(days) = read else { return nil }
        memorySeasonDays[start] = days
        return days
    }

    /// 解析 `{ season, days }`。`expectedSeason` 为 nil 时只验结构，不验季。
    nonisolated private static func decodeDays(_ text: String, expectedSeason: String?) -> [JSONValue]? {
        guard case let .object(root)? = try? JSONValue.decode(text),
              case let .array(days)? = root["days"],
              days.count == 7
        else { return nil }
        if let expectedSeason {
            guard case let .string(season)? = root["season"], season == expectedSeason else { return nil }
        }
        // 全空的缓存等于没缓存：宁可返回 nil 让调用方去拉网络。
        let hasContent = days.contains { day in
            if case let .array(items) = day { return !items.isEmpty }
            return false
        }
        return hasContent ? days : nil
    }
}
