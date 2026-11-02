//
//  KazumiTimeText.swift
//  Kazumi
//
//  界面上「今天 18:00」「10月30日」这类时间文案（Camo 4914）。
//
//  `Date.formatted(...)` 和 `.dateTime.hour().minute()` 都跟着**手机语言**走：
//  手机是英文，历史卡片上就漏出「6:00 PM」，跟整页中文拼在一起很扎眼。
//  所以这里统一用固定 zh_Hans_CN 的 `DateFormatter`，别再在页面里就地拼。
//

import Foundation

enum KazumiTimeText {
    /// `18:00`。24 小时制跟中文习惯一致。
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// `今天 18:00` / `昨天 18:00` / `10/30`。
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 \(clock(date))" }
        if calendar.isDateInYesterday(date) { return "昨天 \(clock(date))" }
        return SystemDateText.date(date, includeYear: false)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        // 24 小时制写死（LP 6118：时间不跟系统，跟了会出现「6:00 PM」那种，排版放不下）。
        formatter.dateFormat = "H:mm"
        return formatter
    }()
}
