//
//  PopularPoster.swift
//  Kazumi
//
//  推荐页（焦点区 / 横向货架）用的轻量海报模型。
//
//  为什么不直接用 `BangumiItem`：推荐页的三行都要落盘缓存（LP 2733 / Ato 2734
//  定的过期时间），而 `BangumiItem` 不是 `Codable`，也不该为了缓存把它变成
//  一个「半个网络模型、半个存储模型」的东西。这里只留推荐页真正要画的字段：
//  点进详情只要 id，货架要图 + 名字，焦点区再加评分、话数、简介。
//

import Foundation

/// 推荐页一张海报。`Codable` 是为了整行落盘缓存。
struct PopularPoster: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var nameCn: String
    var imageURL: String
    var summary: String
    var airDate: String
    var rating: Double
    var totalEpisodes: Int

    /// 与 `BangumiItem.displayName` 同一口径：优先中文名，缺了退回原名。
    var displayName: String {
        let translated = nameCn.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty { return translated }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 焦点区那行元信息：「2023 · 28 话 · 9.4」，缺项省项，全缺返回 nil（整行不占位）。
    var metaLine: String? {
        var parts: [String] = []
        let year = String(airDate.prefix(4))
        if year.count == 4, year.allSatisfy(\.isNumber) { parts.append(year) }
        // 话数拿不到就写「？？ 话」：跟原版 main 一样，宁可露出不知道，
        // 也不拿信息框里那个累计话数顶（LP 2026-10-27）。
        parts.append(totalEpisodes > 0 ? String(localized: "\(String(describing: totalEpisodes)) 集") : String(localized: "？？ 集"))
        if rating > 0 { parts.append(String(format: "%.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(
        id: Int,
        name: String,
        nameCn: String = "",
        imageURL: String = "",
        summary: String = "",
        airDate: String = "",
        rating: Double = 0,
        totalEpisodes: Int = 0
    ) {
        self.id = id
        self.name = name
        self.nameCn = nameCn
        self.imageURL = imageURL
        self.summary = summary
        self.airDate = airDate
        self.rating = rating
        self.totalEpisodes = totalEpisodes
    }

    /// 从网络模型转换。
    ///
    /// 趋势榜返回的是精简条目（只有名字、图、评分和一行 `info`），没有 date / eps
    /// 字段，所以年份和话数得从 `info`（形如「12话 / 2026年10月3日 / …」）里取。
    /// 拿不到就是 0，元信息里直接省掉。
    init(_ item: BangumiItem) {
        let info = item.info
        self.init(
            id: item.id,
            name: item.name,
            nameCn: item.nameCn,
            imageURL: item.largeImage,
            summary: item.summary,
            airDate: item.airDate.isEmpty ? Self.yearFromInfo(info) : item.airDate,
            rating: item.ratingScore,
            // 不再从 info 的「36话」里兜底。
            //
            // 那是番剧信息框里人填的话数，跨季连载的番写的是累计话数：某一季
            // 从第 25 集放到第 36 集，info 里写 36，实际这一季只有 12 集
            // （LP 2026-10-27 拿 subject/530104 举的例子）。接口没给 `eps` 时
            // 宁可不显示话数，也不能显示一个错的。
            totalEpisodes: max(item.eps, 0)
        )
    }

    /// 从 info 里取「12话」中的 12。
    ///
    /// 注意用字面量「话」而不是 `\u{8bdd}`：原始字符串 `#"…"#` 不解析转义，
    /// 写成转义时正则一个都匹配不上（第一版就是这么静默失败的）。
    private static func episodesFromInfo(_ info: String) -> Int {
        guard let range = info.range(of: #"(\d{1,3})话"#, options: .regularExpression) else { return 0 }
        let digits = info[range].dropLast()
        return Int(digits) ?? 0
    }

    /// 从 info 里取「2026年10月3日」中的年份。
    private static func yearFromInfo(_ info: String) -> String {
        guard let range = info.range(of: #"(\d{4})年"#, options: .regularExpression) else { return "" }
        return String(info[range].dropLast())
    }
}
