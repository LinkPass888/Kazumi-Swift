//
//  TimelineColumn.swift
//  Kazumi
//
//  时间表上「这部番该放哪一列」。1:1 对齐 main 的 timelineColumnWeekday
//  （lib/services/bangumi_update_times.dart）。
//
//  bangumi 日历的星期是**节目日**：日曜 24:00 记在星期日，本地时钟却已经是
//  周一 00:00。凌晨 0–5 点播出的番按本地时钟挪到第二天那一列，其余时刻原样
//  留在 bangumi 那一列 —— 白天档两者本来就一致。
//
//  只挪一天、星期只从 bangumi（日历分组 / 开播日）来：时刻自带的星期不参与
//  判断，它在 bangumi 和 bangumi-mal 对不上时（先行配信等）会跨度很大。
//

import Foundation

enum TimelineColumn {
    /// 凌晨档的上限（不含）：0–5 点播出属于前一天节目日的「24:00–29:00」。
    static let lateNightHourLimit = 6

    /// 放送星期（1 = 周一 … 7 = 周日）。
    ///
    /// - Parameters:
    ///   - bangumiWeekday: bangumi 记的放送星期（日历分组或开播日）。
    ///   - updateEpochMs: 下一次更新时刻（epoch 毫秒）；拿不到就原样返回。
    ///
    /// 用户手动选过的星期优先级更高，不经过这里。
    static func weekday(bangumiWeekday: Int, updateEpochMs: Int?) -> Int {
        let base = min(7, max(1, bangumiWeekday))
        guard let epoch = updateEpochMs else { return base }
        let date = Date(timeIntervalSince1970: Double(epoch) / 1000)
        let hour = Calendar.current.component(.hour, from: date)
        guard hour < lateNightHourLimit else { return base }
        // 7 的下一天是 1，绕回周一。
        return base % 7 + 1
    }

    /// 用这部番自己的放送时刻判断列（时刻链路与卡片上的「HH:mm 更新」同一条）。
    @MainActor
    static func weekday(bangumiWeekday: Int, airTimeOf subjectID: Int) -> Int {
        weekday(
            bangumiWeekday: bangumiWeekday,
            updateEpochMs: BangumiAirTimeService.shared.nextUpdateEpoch(for: subjectID)
        )
    }
}

/// 时间表里各番实际所在的星期（1 = 周一 … 7 = 周日，已经含凌晨档换列）。
///
/// 时间表每次分列时写入。详情页和追番页手里没有日历（bangumi 的星期只存在于
/// 时间表的分组里，条目的开播日可能压根是空的），拿不到就只能退回开播日，
/// 而开播日对不上时会出现「时间表排周一、详情页写周日」。这里把分列结果共享
/// 出来，与 main 的 `TimelineController.timelineWeekdays` 同一个用途。
@MainActor
enum TimelineWeekdayCache {
    private(set) static var columns: [Int: Int] = [:]

    /// 用一次完整分组的结果替换缓存（下标 0 = 周一）。
    static func replace(with grouped: [[BangumiItem]]) {
        var next: [Int: Int] = [:]
        for (day, items) in grouped.enumerated() {
            for item in items {
                next[item.id] = day + 1
            }
        }
        columns = next
    }

    /// 这部番在时间表里的列；时间表还没加载过时返回 nil。
    static func weekday(of bangumiID: Int) -> Int? {
        columns[bangumiID]
    }
}
