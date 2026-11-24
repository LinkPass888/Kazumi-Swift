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
    /// 缓存带年/不带年两份 `DateFormatter`，用 `NSLock` 保护并发读写，
    /// 并监听 `NSLocale.currentLocaleDidChangeNotification` 在系统地区/格式变化时自动重建，
    /// 消除列表渲染每帧新建 `DateFormatter` 与两次正则替换的开销。
    private final class FormatterCache: @unchecked Sendable {
        static let shared = FormatterCache()

        private let lock = NSLock()
        private var withYearFormatter: DateFormatter?
        private var withoutYearFormatter: DateFormatter?
        private var localeObserver: NSObjectProtocol?

        private init() {
            localeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.invalidate()
            }
        }

        private func invalidate() {
            lock.lock()
            withYearFormatter = nil
            withoutYearFormatter = nil
            lock.unlock()
        }

        func string(from date: Date, includeYear: Bool) -> String {
            lock.lock()
            defer { lock.unlock() }
            if withYearFormatter == nil || withoutYearFormatter == nil {
                rebuildLocked()
            }
            let formatter = includeYear ? withYearFormatter! : withoutYearFormatter!
            return formatter.string(from: date)
        }

        private func rebuildLocked() {
            let locale = Locale.current
            let probe = DateFormatter()
            probe.locale = locale
            probe.dateStyle = .short
            probe.timeStyle = .none
            let shortPattern = probe.dateFormat ?? "y-MM-dd"

            let withYear = DateFormatter()
            withYear.locale = locale
            withYear.dateFormat = shortPattern

            let withoutYear = DateFormatter()
            withoutYear.locale = locale
            withoutYear.dateFormat = SystemDateText.withoutYear(shortPattern)

            withYearFormatter = withYear
            withoutYearFormatter = withoutYear
        }
    }

    static func date(_ date: Date, includeYear: Bool) -> String {
        FormatterCache.shared.string(from: date, includeYear: includeYear)
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
        return text.isEmpty ? pattern : text
    }
}
