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

    // MARK: - 存档（原始 JSON 文本）

    /// 内存里那份原始 JSON（当季），冷启动第一帧用。
    private var memoryText: String?

    /// 记一份当季日历（`calendar()` 成功时调用）。
    /// `seasonStart` 是这一季的身份（`AnimeSeason.seasonRange().start`）：
    /// 存进去以后读的时候要验，不然跨季那天会把上一季那份当成当季铺出来（LP 5055）。
    func storeCurrent(rawDays: [JSONValue], seasonStart: String) {
        let payload = JSONValue.object([
            "season": .string(seasonStart),
            "days": .array(rawDays),
        ])
        let text = JSONValue.serialize(payload, pretty: false)
        remember(text: text)
        write(text, to: fileURL(currentSeason: true, seasonStart: nil))
    }

    /// 存往期季度。
    func storeSeason(rawDays: [JSONValue], start: String) {
        let payload = JSONValue.object([
            "season": .string(start),
            "days": .array(rawDays),
        ])
        write(JSONValue.serialize(payload, pretty: false), to: fileURL(currentSeason: false, seasonStart: start))
    }

    private func remember(text: String) {
        guard Self.decodeDays(text, expectedSeason: nil) != nil else {
            // 序列化失败时会退回 `{}`（`JSONValue.serialize` 的行为），这时别把烂东西
            // 当成缓存记在内存里；写一行日志，真机上「缓存总是没命中」才查得出来。
            KazumiLogBuffer.shared.append(
                "时间表缓存：这一份没写出可用的 JSON，跳过",
                category: .network
            )
            return
        }
        memoryText = text
    }

    private func write(_ text: String, to url: URL) {
        guard Self.decodeDays(text, expectedSeason: nil) != nil else { return }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - 取

    /// 当季的原始 JSON：先内存、再磁盘。取不到、或存的不是这一季，返回 nil。
    ///
    /// 为什么验季：缓存存的是「当季」这一份，跨季那天它还躺在那儿，
    /// 不验就会把上一季的番铺成这一季（LP 5055）。
    func currentRawDays(seasonStart: String) -> [JSONValue]? {
        if let memoryText,
           let days = Self.decodeDays(memoryText, expectedSeason: seasonStart) {
            return days
        }
        guard let data = try? Data(contentsOf: fileURL(currentSeason: true, seasonStart: nil)) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let days = Self.decodeDays(text, expectedSeason: seasonStart) else {
            // 跨季了：旧那份已经没用，不要留着占内存、也不要每次启动再试一次。
            memoryText = nil
            try? FileManager.default.removeItem(at: fileURL(currentSeason: true, seasonStart: nil))
            return nil
        }
        memoryText = text
        return days
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

    /// 往期季度的原始 JSON。
    func seasonRawDays(start: String) -> [JSONValue]? {
        guard let data = try? Data(contentsOf: fileURL(currentSeason: false, seasonStart: start)) else {
            return nil
        }
        return Self.decodeDays(String(decoding: data, as: UTF8.self), expectedSeason: start)
    }

    /// 解析 `{ season, days }`。`expectedSeason` 为 nil 时只验结构，不验季。
    private static func decodeDays(_ text: String, expectedSeason: String?) -> [JSONValue]? {
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
