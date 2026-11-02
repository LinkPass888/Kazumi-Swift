//
//  BangumiItem.swift
//  Kazumi
//
//  1:1 翻译 lib/modules/bangumi/bangumi_item.dart 的 BangumiItem 与 fromJson。
//  字段顺序、默认值、别名解析（infobox 的「别名」）、票数分布、放送日期回退
//  规则全部与 Dart 实现逐行对应，避免上层 UI 拿到与原版不同的数据。
//

import Foundation

/// 标签（lib/modules/bangumi/bangumi_tag.dart）。
struct BangumiTag: Hashable, Sendable {
    var name: String
    var count: Int

    init(name: String, count: Int = 0) {
        self.name = name
        self.count = count
    }

    static func fromJSON(_ json: JSONValue) -> BangumiTag {
        BangumiTag(
            name: json["name"].stringValue ?? "",
            count: json["count"].intValue ?? 0
        )
    }
}

/// 用户收藏状态（lib/modules/bangumi/bangumi_interest.dart 的 UI 子集）。
struct BangumiInterest: Hashable, Sendable {
    var type: Int
    var comment: String?
    var rate: Int?

    static func fromJSON(_ json: JSONValue) -> BangumiInterest {
        BangumiInterest(
            type: json["type"].intValue ?? 0,
            comment: json["comment"].stringValue,
            rate: json["rate"].intValue
        )
    }

    /// 对应 Dart 的 hasReviewContent。
    var hasReviewContent: Bool {
        let hasComment = !(comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasComment || (rate ?? 0) > 0
    }
}

/// 番剧条目。对应 lib/modules/bangumi/bangumi_item.dart。
struct BangumiItem: Identifiable, Hashable, Sendable {
    var id: Int
    var type: Int
    var name: String
    var nameCn: String
    var summary: String
    var airDate: String
    var airWeekday: Int
    var rank: Int
    var images: [String: String]
    var tags: [BangumiTag]
    var alias: [String]
    var ratingScore: Double
    var votes: Int
    var votesCount: [Int]
    var info: String
    /// 总话数（接口的 `eps`）。推荐页焦点区的元信息要用「28 话」这一项，
    /// 拿不到就是 0，元信息里直接省掉，不显示「0 话」。
    var eps: Int
    /// 时间表接口附带的元标签，与用户标签分开统计，不参与持久化。
    var metaTags: [String]
    var interest: BangumiInterest?

    init(
        id: Int,
        type: Int = 2,
        name: String,
        nameCn: String,
        summary: String = "",
        airDate: String = "",
        airWeekday: Int = 1,
        rank: Int = 0,
        images: [String: String] = [:],
        tags: [BangumiTag] = [],
        alias: [String] = [],
        ratingScore: Double = 0,
        votes: Int = 0,
        votesCount: [Int] = [],
        info: String = "",
        eps: Int = 0,
        metaTags: [String] = [],
        interest: BangumiInterest? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.nameCn = nameCn
        self.summary = summary
        self.airDate = airDate
        self.airWeekday = airWeekday
        self.rank = rank
        self.images = images
        self.tags = tags
        self.alias = alias
        self.ratingScore = ratingScore
        self.votes = votes
        self.votesCount = votesCount
        self.info = info
        self.eps = eps
        self.metaTags = metaTags
        self.interest = interest
    }

    /// UI 统一使用的标题：优先中文名，缺失时退回原名。
    var displayName: String {
        let translated = nameCn.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : translated
    }

    /// 对应 images['large'] ?? ''。
    ///
    /// 依次退到 common / medium / small / grid：Bangumi 有些条目只给了小图，
    /// 直接取 large 会得到空地址，卡片就永久停在占位图上。
    var largeImage: String {
        for key in ["large", "common", "medium", "small", "grid"] {
            if let value = images[key], !value.isEmpty { return value }
        }
        return ""
    }

    /// 对应 bangumi_timeline_card.dart 的 _supportingText：优先 metaTags，其次用户标签。
    var supportingText: String {
        let source = metaTags.isEmpty ? tags.map(\.name) : metaTags
        var seen = Set<String>()
        let metadata = source
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if !metadata.isEmpty {
            return metadata.prefix(3).joined(separator: " · ")
        }
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return original == displayName ? "" : original
    }

    // MARK: - 解析

    /// 对应 BangumiItem.fromJson。
    static func fromJSON(_ json: JSONValue) -> BangumiItem {
        let airDate = resolveAirDate(json)
        let rawNameCn = json["name_cn"].stringValue ?? ""
        let fallbackNameCn = json["nameCN"].stringValue ?? ""
        let nameCN = rawNameCn.isEmpty
            ? (fallbackNameCn.isEmpty ? (json["name"].stringValue ?? "") : fallbackNameCn)
            : rawNameCn
        let interest = json["interest"].objectValue.map { BangumiInterest.fromJSON(.object($0)) }

        return BangumiItem(
            id: json["id"].intValue ?? 0,
            type: json["type"].intValue ?? 2,
            name: json["name"].stringValue ?? "",
            nameCn: nameCN,
            summary: json["summary"].stringValue ?? "",
            airDate: airDate,
            airWeekday: DateTimeHelper.dateStringToWeekday(airDate.isEmpty ? "2000-11-11" : airDate),
            rank: json["rating"]["rank"].intValue ?? 0,
            images: resolveImages(json),
            tags: (json["tags"].arrayValue ?? []).map(BangumiTag.fromJSON),
            alias: parseAliases(json),
            ratingScore: resolveScore(json),
            votes: json["rating"]["total"].intValue ?? 0,
            votesCount: parseVoteCount(json),
            info: json["info"].stringValue ?? "",
            eps: json["eps"].intValue ?? 0,
            metaTags: parseMetaTags(json),
            interest: interest
        )
    }

    /// rating.score 保留一位小数，与 Dart 的 toStringAsFixed(1) 一致。
    private static func resolveScore(_ json: JSONValue) -> Double {
        let raw = json["rating"]["score"].doubleValue ?? 0
        return (raw * 10).rounded() / 10
    }

    /// 对应 resolveAirDateString：顶层 date 优先，其次 airtime.date。
    private static func resolveAirDate(_ json: JSONValue) -> String {
        func nonEmpty(_ value: JSONValue) -> String? {
            guard value.exists else { return nil }
            let text = (value.stringValue ?? value.serialized(pretty: false))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let fromTop = nonEmpty(json["date"]) { return fromTop }
        if let fromAirTime = nonEmpty(json["airtime"]["date"]) { return fromAirTime }
        return ""
    }

    /// 对应 images 字段：缺失时用顶层 image 兜底。
    private static func resolveImages(_ json: JSONValue) -> [String: String] {
        if let object = json["images"].objectValue {
            var result: [String: String] = [:]
            for (key, value) in object {
                result[key] = value.stringValue ?? ""
            }
            return result
        }
        return [
            "large": json["image"].stringValue ?? "",
            "common": "",
            "medium": "",
            "small": "",
            "grid": "",
        ]
    }

    /// 对应 parseBangumiAliases：infobox 中 key 为「别名」的条目，
    /// 兼容 values（api.bgm.tv）与 value（next.bgm.tv）两种写法。
    private static func parseAliases(_ json: JSONValue) -> [String] {
        guard let infobox = json["infobox"].arrayValue else { return [] }
        for item in infobox where item["key"].stringValue == "别名" {
            let raw = item["values"].exists ? item["values"] : item["value"]
            guard raw.exists else { return [] }
            if let list = raw.arrayValue {
                return list.compactMap { element in
                    if element["v"].exists {
                        let text = element["v"].stringValue ?? element["v"].serialized(pretty: false)
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    let text = element.stringValue ?? element.serialized(pretty: false)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            let text = raw.stringValue ?? raw.serialized(pretty: false)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return []
    }

    /// 对应 parseBangumiVoteCount：rating.count 可能是对象（1...10 为键）或数组。
    private static func parseVoteCount(_ json: JSONValue) -> [Int] {
        let count = json["rating"]["count"]
        guard count.exists else { return [] }
        if let object = count.objectValue {
            return (1...10).map { JSONValue.object(object)["\($0)"].intValue ?? 0 }
        }
        if let list = count.arrayValue {
            return list.map { $0.intValue ?? 0 }
        }
        return []
    }

    /// 对应 metaTags：去空白、去重并保持出现顺序。
    private static func parseMetaTags(_ json: JSONValue) -> [String] {
        guard let list = json["metaTags"].arrayValue else { return [] }
        var seen = Set<String>()
        return list.compactMap { element in
            guard let text = element.stringValue else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

/// 对应 lib/utils/date_time.dart 中与放送日期相关的工具函数。
enum DateTimeHelper {
    /// 把 yyyy-MM-dd 换算成 ISO 星期（1 = 周一 ... 7 = 周日），
    /// 解析失败时退回 1，与 Dart 实现一致。
    static func dateStringToWeekday(_ value: String) -> Int {
        guard let date = parseISO(value) else { return 1 }
        return isoWeekday(date)
    }

    /// 宽松解析：优先 yyyy-MM-dd，其次完整 ISO8601 时间戳。
    static func parseISO(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count >= 10, let date = dayFormatter.date(from: String(trimmed.prefix(10))) {
            return date
        }
        if let date = isoFormatter.date(from: trimmed) { return date }
        return timeFormatter.date(from: trimmed)
    }

    static func isoWeekday(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        // Calendar 的 weekday：1 = 周日 ... 7 = 周六，转换为 ISO 的 1 = 周一 ... 7 = 周日。
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // ISO8601DateFormatter 不是 Sendable，作为 static 常量会被 Swift 6 视为共享可变状态；
    // 这两处只在解析时读一次配置后使用，因此用 nonisolated(unsafe) 明确其线程安全前提：
    // 一旦创建完成就不再修改 formatOptions，ISO8601DateFormatter 的 date(from:) 是线程安全的。
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
