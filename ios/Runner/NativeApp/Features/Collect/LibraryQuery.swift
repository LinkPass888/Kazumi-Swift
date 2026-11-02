//
//  LibraryQuery.swift
//  Kazumi
//
//  对应 lib/pages/collect/collect_library_query.dart：
//  * 五档排序（更新时间 / 最近变更 / 番剧名称 / 评分最高 / 开播时间）；
//  * 分类 + 关键词过滤；
//  * 「更新时间」的时刻换算（对应 bangumi_update_times.dart 的
//    updateTimeForWeekdayFrom）。
//
//  这里只有纯函数：时刻表由 LibraryScreen 预先算好成 [Int: Date] 再交进来，
//  比较器里不读缓存、不发网络请求，保证一次排序里每一部番的时刻前后一致。
//

import Foundation

/// 追番页排序档位。rawValue 与原版 `CollectSort.name` 一致，
/// `SettingsStore.librarySort` 存的就是它。
enum CollectSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case updateTime
    case recentlyChanged
    case title
    case rating
    case airDate

    var id: String { rawValue }

    /// 菜单文案，顺序即 `allCases` 的顺序（照 main）。
    var label: String {
        switch self {
        case .updateTime: String(localized: "更新时间")
        case .recentlyChanged: String(localized: "最近变更")
        case .title: String(localized: "番剧名称")
        case .rating: String(localized: "评分最高")
        case .airDate: String(localized: "开播时间")
        }
    }
}

/// 追番页的纯查询：过滤与排序都不碰 UI、不读全局状态。
enum CollectLibraryQuery {
    // MARK: - 过滤

    /// 当前分类之内按关键词过滤。
    ///
    /// 与 main 的 `_match` 同一套：关键词按空白切成多个词，每个词都要命中
    /// 番剧名（中文名或原名，任一即可）。iOS 的收藏条目没有 alias 字段，
    /// 因此只查这两个名字。
    static func filter(_ entries: [LibraryEntry], type: CollectType?, query: String) -> [LibraryEntry] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return entries.filter { entry in
            if let type, entry.collectType != type { return false }
            guard !terms.isEmpty else { return true }
            let names = [entry.nameCn, entry.name].joined(separator: "\n").lowercased()
            return terms.allSatisfy { names.contains($0) }
        }
    }

    // MARK: - 排序

    /// 按 `sort` 排序；「更新时间」的每个时刻都从 `updateTimes` 里取。
    ///
    /// 缺失值的下沉规则见规格第五节：更新时间无时刻、评分 0、无开播日期、
    /// 空名字都排在有值之后；同序回退 `updatedAt` 降序、再回退 id 升序
    /// （与 main 的 `results` 一致）。「更新时间」同刻时直接按 id 升序。
    static func sort(
        _ entries: [LibraryEntry],
        by sort: CollectSort,
        updateTimes: [Int: Date]
    ) -> [LibraryEntry] {
        entries.sorted { lhs, rhs in
            switch sort {
            case .updateTime:
                switch (updateTimes[lhs.id], updateTimes[rhs.id]) {
                case (nil, nil):
                    return lhs.id < rhs.id
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case let (left?, right?):
                    if left != right { return left > right }
                    return lhs.id < rhs.id
                }

            case .recentlyChanged:
                return tieBreak(lhs, rhs)

            case .title:
                let left = lhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let right = rhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if left.isEmpty || right.isEmpty {
                    if left.isEmpty, right.isEmpty { return tieBreak(lhs, rhs) }
                    return !left.isEmpty
                }
                let result = left.compare(
                    right,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    range: nil,
                    locale: .current
                )
                if result != .orderedSame { return result == .orderedAscending }
                return tieBreak(lhs, rhs)

            case .rating:
                if lhs.rating <= 0 || rhs.rating <= 0 {
                    if lhs.rating <= 0, rhs.rating <= 0 { return tieBreak(lhs, rhs) }
                    return lhs.rating > 0
                }
                if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
                return tieBreak(lhs, rhs)

            case .airDate:
                let left = dayValue(lhs.airDate)
                let right = dayValue(rhs.airDate)
                if left == nil || right == nil {
                    if left == nil, right == nil { return tieBreak(lhs, rhs) }
                    return left != nil
                }
                if left != right { return left! > right! }
                return tieBreak(lhs, rhs)
            }
        }
    }

    /// 同序回退：`updatedAt` 降序，再 id 升序（对应 main 的 byTime / id）。
    private static func tieBreak(_ lhs: LibraryEntry, _ rhs: LibraryEntry) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    /// "yyyy-MM-dd" -> 可比较的整数；解析不出来返回 nil（视为没有开播日期）。
    ///
    /// 不走 DateFormatter：比较器会被调用上百次，而且这里只需要日期先后。
    private static func dayValue(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
        guard parts.count >= 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }
        return year * 10_000 + month * 100 + day
    }

    // MARK: - 「更新时间」

    /// 把「这一集几点播」落到本周的那一天，返回那一刻；今天还没到就落到上周，
    /// 早于首播则视为没有时刻。与 main 的 `updateTimeForWeekdayFrom` 等价：
    /// 星期只由放送星期决定，绝不用时刻自带的星期反推。
    ///
    /// - Parameters:
    ///   - hour: 本地时间的小时（来自 `BangumiAirTimeService` 的 "HH:mm"）。
    ///   - minute: 本地时间的分钟。
    ///   - weekday: 1 = 周一 ... 7 = 周日（时间表同一套回退链算出来的）。
    ///   - now: 当前时刻，由调用方固定，避免一次排序里时间漂移。
    ///   - firstAir: 首播时刻（`BangumiAirSchedule.first`）。
    static func updateTimeForWeekday(
        hour: Int,
        minute: Int,
        weekday: Int,
        now: Date,
        firstAir: Date?
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let target = min(7, max(1, weekday))
        let today = calendar.startOfDay(for: now)
        // Calendar 的 weekday 是 1 = 周日 ... 7 = 周六，换成 ISO 的 1 = 周一 ... 7 = 周日。
        let isoWeekday = ((calendar.component(.weekday, from: today) + 5) % 7) + 1
        let daysBack = (isoWeekday - target + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: -daysBack, to: today) else {
            return nil
        }

        func slot(on day: Date) -> Date? {
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = hour
            components.minute = minute
            components.second = 0
            return calendar.date(from: components)
        }

        guard var epoch = slot(on: day) else { return nil }
        if epoch > now {
            // 本周这一刻还没到：落到上周同一天同一时刻（按日历日回退，避开夏令时）。
            guard let lastWeek = calendar.date(byAdding: .day, value: -7, to: day),
                  let previous = slot(on: lastWeek)
            else { return nil }
            epoch = previous
        }

        if let firstAir, epoch < firstAir { return nil }
        return epoch
    }
}
