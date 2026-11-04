//
//  AnimeSeason.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/anime_season.dart 与 lib/utils/date_time.dart 中
//  与季度、日期格式化相关的函数。
//

import Foundation

enum AnimeSeason {
    /// 对应 getSeasonStringByMonth。
    static func seasonString(month: Int) -> String {
        if month <= 3 { return String(localized: "冬") }
        if month <= 6 { return String(localized: "春") }
        if month <= 9 { return String(localized: "夏") }
        return String(localized: "秋")
    }

    /// 对应 isSameSeason：同一年且同一季度。
    static func isSameSeason(_ lhs: Date, _ rhs: Date) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        let left = calendar.dateComponents([.year, .month], from: lhs)
        let right = calendar.dateComponents([.year, .month], from: rhs)
        guard let ly = left.year, let lm = left.month,
              let ry = right.year, let rm = right.month else { return false }
        return ly == ry && (lm - 1) / 3 == (rm - 1) / 3
    }

    /// 对应 toSeasonStartAndEnd：返回 [季初前一天所在月的 1 号, 季末下一个月 1 号)。
    ///
    /// 与 Dart 实现一致：起点刻意回退到上一季度的首月，因为放送日通常比
    /// 季度起点还早几天。
    static func seasonRange(for date: Date) -> (start: String, end: String) {
        let calendar = Calendar(identifier: .gregorian)
        var year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let season = (month - 1) / 3

        var startMonth = season * 3
        if startMonth == 0 {
            startMonth = 12
            year -= 1
        }
        let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)) ?? date
        let end = calendar.date(
            from: DateComponents(year: calendar.component(.year, from: date), month: (season + 1) * 3, day: 1)
        ) ?? date
        return (format(start), format(end))
    }

    /// 「2026年冬季新番」。
    static func label(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let season = (month - 1) / 3
        let seasonName = String(localized: ["冬季", "春季", "夏季", "秋季"][season])
        return String(localized: "\(String(describing: year))年\(seasonName)新番")
    }

    /// 对应 formatDateTime：yyyy-MM-dd。
    static func format(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 1)
        let day = String(format: "%02d", parts.day ?? 1)
        return "\(year)-\(month)-\(day)"
    }
}
