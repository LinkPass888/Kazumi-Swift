//
//  SystemDateText.swift
//  Kazumi
//
//  界面上给用户看的日期，直接用手机的日期格式（设置 → 通用 → 语言与地区 → 日期格式）。
//  LP 6137 / Ato 6138：系统给什么格式就印什么，不手动加「月日」这类字。
//  LP 6115：原来省年份的地方还是省——只把年份从格式里去掉，不往里加字。
//

import Foundation

enum SystemDateText {
    /// 手机当前的短日期格式，比如 `M/d/y`、`yyyy.MM.dd`。
    private static let shortPattern: String = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.dateFormat ?? "y-MM-dd"
    }()

    static func date(_ date: Date, includeYear: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = includeYear ? shortPattern : withoutYear(shortPattern)
        return formatter.string(from: date)
    }

    /// 把年份从手机格式里去掉，连带清掉多出来的分隔符：`M/d/y` → `M/d`，
    /// `yyyy.MM.dd` → `MM.dd`。
    private static func withoutYear(_ pattern: String) -> String {
        var text = pattern.replacingOccurrences(
            of: "y+",
            with: "",
            options: .regularExpression
        )
        // 去掉重复的分隔符和首尾残留，比如 `/MM/dd` 和 `MM/dd/`。
        text = text.replacingOccurrences(
            of: "([^A-Za-z])\\1+",
            with: "$1",
            options: .regularExpression
        )
        while let first = text.first, !first.isLetter {
            text.removeFirst()
        }
        while let last = text.last, !last.isLetter {
            text.removeLast()
        }
        return text.isEmpty ? shortPattern : text
    }
}
