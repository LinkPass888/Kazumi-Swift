//
//  SearchParser.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/search_parser.dart：搜索框支持
//  `id:` `tag:` `sort:` `season:` `date:` `rank:` `score:` `weekday:` 前缀语法，
//  解析成 SearchFilterState 后再拼回字符串回填搜索框。
//

import Foundation

/// 日期区间（对应 SearchDateRange）。
struct SearchDateRange: Hashable, Sendable {
    var start: String
    var end: String

    var isValid: Bool { !start.isEmpty && !end.isEmpty }
}

/// 名次区间（对应 SearchIntRange）。
struct SearchIntRange: Hashable, Sendable {
    var min: Int?
    var max: Int?

    var isValid: Bool { min != nil || max != nil }

    /// 对应 toToken：'min..max'，未填的一侧留空。
    func toToken() -> String {
        "\(min.map(String.init) ?? "")..\(max.map(String.init) ?? "")"
    }

    /// 人话写法：1–5000（整数，中间是短横线 U+2013）。
    var displayText: String {
        "\(min ?? 1)–\(max ?? 10000)"
    }
}

/// 评分区间（对应 SearchDoubleRange）。
struct SearchDoubleRange: Hashable, Sendable {
    var min: Double?
    var max: Double?

    var isValid: Bool { min != nil || max != nil }

    func toToken() -> String {
        "\(Self.format(min))..\(Self.format(max))"
    }

    /// 人话写法：7.0–10.0（一位小数，中间是短横线 U+2013）。
    /// 面板和条件摘要共用这一处，别写第二份（Camo 3036）。
    var displayText: String {
        let low = String(format: "%.1f", min ?? 0)
        let high = String(format: "%.1f", max ?? 10)
        return "\(low)–\(high)"
    }

    /// 保留一位小数并去掉末尾的 .0，与 Dart 的 _formatDouble 一致。
    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        let fixed = String(format: "%.1f", value)
        return fixed.hasSuffix(".0") ? String(fixed.dropLast(2)) : fixed
    }
}

/// 搜索条件（对应 SearchFilterState）。
struct SearchFilterState: Hashable, Sendable {
    var id: String = ""
    var keyword: String = ""
    var tags: [String] = []
    var sort: String = "heat"
    var season: String = ""
    var dateRange: SearchDateRange?
    var rankRange: SearchIntRange?
    var scoreRange: SearchDoubleRange?
    var weekdays: [Int] = []

    var isIdSearch: Bool { !id.isEmpty }

    var hasAdvancedFilters: Bool {
        !tags.isEmpty
            || sort != "heat"
            || !season.isEmpty
            || dateRange != nil
            || (rankRange?.isValid ?? false)
            || (scoreRange?.isValid ?? false)
            || !weekdays.isEmpty
    }

    /// season 优先于 dateRange：选了季度就按季度换算日期区间。
    var effectiveDateRange: SearchDateRange? {
        if let dateRange { return dateRange }
        if season.isEmpty { return nil }
        return SearchParser.seasonToDateRange(season)
    }
}

/// 搜索语法解析器（对应 SearchParser）。
struct SearchParser {
    let query: String

    private static let fieldNames = "id|tag|sort|season|date|rank|score|weekday|nsfw"

    private static let idRegex = try? NSRegularExpression(pattern: #"id:(\d+)"#, options: [.caseInsensitive])
    private static let tagRegex = try? NSRegularExpression(
        pattern: #"(?:^|\s)tag:([^\s]+?)(?=(?:id|tag|sort|season|date|rank|score|weekday|nsfw):|\s|$)"#,
        options: [.caseInsensitive]
    )
    private static let sortRegex = try? NSRegularExpression(pattern: #"sort:([\w\-]+)"#, options: [.caseInsensitive])
    private static let seasonRegex = try? NSRegularExpression(pattern: #"season:(\d{4}Q[1-4])"#, options: [.caseInsensitive])
    private static let dateRegex = try? NSRegularExpression(
        pattern: #"date:(\d{4}-\d{2}-\d{2})\.\.(\d{4}-\d{2}-\d{2})"#,
        options: [.caseInsensitive]
    )
    private static let rankRegex = try? NSRegularExpression(pattern: #"rank:(\d*)\.\.(\d*)"#, options: [.caseInsensitive])
    private static let scoreRegex = try? NSRegularExpression(
        pattern: #"score:(\d+(?:\.\d+)?)?\.\.(\d+(?:\.\d+)?)?"#,
        options: [.caseInsensitive]
    )
    private static let weekdayRegex = try? NSRegularExpression(pattern: #"weekday:([1-7](?:,[1-7])*)"#, options: [.caseInsensitive])

    init(_ query: String) {
        self.query = query
    }

    // MARK: - 单字段解析

    func parseId() -> String? {
        Self.firstMatch(Self.idRegex, query).first
    }

    func parseTags() -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for line in Self.allMatches(Self.tagRegex, query) {
            let tag = line.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            tags.append(tag)
        }
        return tags
    }

    func parseSort() -> String? {
        Self.firstMatch(Self.sortRegex, query).first
    }

    func parseSeason() -> String? {
        Self.firstMatch(Self.seasonRegex, query).first?.uppercased()
    }

    func parseDateRange() -> SearchDateRange? {
        let match = Self.firstMatch(Self.dateRegex, query)
        guard match.count >= 2, let start = match.first, let end = match.last else { return nil }
        return SearchDateRange(start: start, end: end)
    }

    func parseRankRange() -> SearchIntRange? {
        let match = Self.firstMatch(Self.rankRegex, query)
        guard !match.isEmpty else { return nil }
        let range = SearchIntRange(min: Int(match[0]), max: match.count > 1 ? Int(match[1]) : nil)
        return range.isValid ? range : nil
    }

    func parseScoreRange() -> SearchDoubleRange? {
        let match = Self.firstMatch(Self.scoreRegex, query)
        guard !match.isEmpty else { return nil }
        let range = SearchDoubleRange(min: Double(match[0]), max: match.count > 1 ? Double(match[1]) : nil)
        return range.isValid ? range : nil
    }

    func parseWeekdays() -> [Int] {
        guard let raw = Self.firstMatch(Self.weekdayRegex, query).first, !raw.isEmpty else { return [] }
        let values = raw.split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) }
        return Array(Set(values)).sorted()
    }

    /// 去掉所有已知前缀 token，剩下的就是关键词。
    func parseKeywords() -> String {
        guard let tokenRegex = Self.tokenRegex else {
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(query.startIndex..., in: query)
        let stripped = tokenRegex.stringByReplacingMatches(in: query, options: [], range: range, withTemplate: " ")
        let collapsed = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toFilterState() -> SearchFilterState {
        SearchFilterState(
            id: parseId() ?? "",
            keyword: parseKeywords(),
            tags: parseTags(),
            sort: parseSort() ?? "heat",
            season: parseSeason() ?? "",
            dateRange: parseDateRange(),
            rankRange: parseRankRange(),
            scoreRange: parseScoreRange(),
            weekdays: parseWeekdays()
        )
    }

    // MARK: - 反向拼装

    /// 对应 fromFilterState：把筛选条件拼回搜索框文本。
    static func fromFilterState(_ state: SearchFilterState) -> String {
        if !state.id.isEmpty { return "id:\(state.id)" }

        var tokens: [String] = []
        let keyword = state.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty { tokens.append(keyword) }
        for tag in state.tags {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { tokens.append("tag:\(normalized)") }
        }
        if !state.sort.isEmpty, state.sort != "heat" {
            tokens.append("sort:\(state.sort)")
        }
        if !state.season.isEmpty {
            tokens.append("season:\(state.season)")
        } else if let range = state.dateRange, range.isValid {
            tokens.append("date:\(range.start)..\(range.end)")
        }
        if let rank = state.rankRange, rank.isValid {
            tokens.append("rank:\(rank.toToken())")
        }
        if let score = state.scoreRange, score.isValid {
            tokens.append("score:\(score.toToken())")
        }
        if !state.weekdays.isEmpty {
            let weekdays = Array(Set(state.weekdays)).sorted()
            tokens.append("weekday:\(weekdays.map(String.init).joined(separator: ","))")
        }
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 对应 seasonToDateRange：2024Q1 -> 2023-12-01 .. 2024-03-01。
    static func seasonToDateRange(_ season: String) -> SearchDateRange? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{4})Q([1-4])$"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: season, options: [], range: NSRange(season.startIndex..., in: season)),
              let yearRange = Range(match.range(at: 1), in: season),
              let quarterRange = Range(match.range(at: 2), in: season),
              let year = Int(season[yearRange]),
              let quarter = Int(season[quarterRange]) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        let startMonth = (quarter - 1) * 3 + 1
        // Dart 的 DateTime(year, startMonth - 1, 1) 使用 0 基月份，
        // 因此区间起点落在季度首月的前一个月（放送日通常早于季度起点）。
        let start = calendar.date(from: DateComponents(year: year, month: startMonth - 1, day: 1))
        let end = calendar.date(from: DateComponents(year: year, month: startMonth + 2, day: 1))
        guard let start, let end else { return nil }
        return SearchDateRange(start: AnimeSeason.format(start), end: AnimeSeason.format(end))
    }

    // MARK: - 正则辅助

    private static let tokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:^|\s)?(?:"# + fieldNames + #"):[^\s]*?(?=(?:\s|$)|(?:"# + fieldNames + #"):)"#,
        options: [.caseInsensitive]
    )

    /// 返回第一处匹配的全部捕获组（空串表示该组未参与匹配）。
    private static func firstMatch(_ regex: NSRegularExpression?, _ text: String) -> [String] {
        guard let regex,
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return [] }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    private static func allMatches(_ regex: NSRegularExpression?, _ text: String) -> [[String]] {
        guard let regex else { return [] }
        let results = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        return results.map { match in
            guard match.numberOfRanges > 1 else { return [] }
            return (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }
}


// MARK: - 给人看的说法

extension SearchFilterState {
    /// 排序名，对应 search_widgets.dart 的 _searchSortLabels。
    static func sortLabel(_ sort: String) -> String {
        switch sort {
        case "rank": return String(localized: "排名")
        case "score": return "评分"
        case "match": return String(localized: "匹配")
        default: return String(localized: "热度")
        }
    }

    /// 条件摘要，对应 _filterSummary：题材 · 季度/日期 · 评分 · 排名 · 星期。
    var summary: String {
        var parts: [String] = []
        parts.append(contentsOf: tags)
        if !season.isEmpty {
            parts.append(season)
        } else if let dateRange {
            parts.append(String(localized: "\(String(describing: dateRange.start)) 至 \(String(describing: dateRange.end))"))
        }
        if let scoreRange, scoreRange.isValid {
            // LP 3040：先照 main——摘要就用 toToken，屏上是「评分 7..10」。
            parts.append(String(localized: "评分 \(String(describing: scoreRange.toToken()))"))
        }
        if let rankRange, rankRange.isValid {
            parts.append(String(localized: "排名 \(String(describing: rankRange.toToken()))"))
        }
        if !weekdays.isEmpty {
            let titles = [String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六"), String(localized: "日")]
            parts.append(String(localized: "周") + weekdays.map { titles[$0 - 1] }.joined(separator: "、"))
        }
        return parts.joined(separator: " · ")
    }

    /// 搜索语法翻成人话，对应 _readableQuery：搜索框里、历史记录里都只给人看这个。
    var readableQuery: String {
        var parts: [String] = []
        if !keyword.isEmpty { parts.append(keyword) }
        if !id.isEmpty { parts.append(String(localized: "条目 \(String(describing: id))")) }
        let summary = self.summary
        if !summary.isEmpty { parts.append(summary) }
        if sort != "heat" { parts.append(String(localized: "\(String(describing: Self.sortLabel(sort)))排序")) }
        return parts.joined(separator: " · ")
    }
}
