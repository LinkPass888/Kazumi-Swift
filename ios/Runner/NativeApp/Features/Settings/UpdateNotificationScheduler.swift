//
//  UpdateNotificationScheduler.swift
//  Kazumi
//
//  番剧更新提醒（对应 lib/services/bangumi_update_notification_service.dart）。
//
//  原版用 flutter_local_notifications 排 iOS 本地通知；原生这边直接用
//  UNUserNotificationCenter，行为对齐：
//  - 只在「追番更新提醒」开着时排；
//  - 每次重排先把旧的提醒全撤掉，弃追、停更后不留残影；
//  - 只排未来 7 天内、且还没到点的更新；
//  - 通知 id 用 400000 + (bangumiID % 100000)，payload 记 `bangumiID:epochMs`，
//    因为系统不返回排定时刻，只能自己带。
//
//  排定时刻来自 BangumiAirTimeService 的季度数据（首播时刻 + 周期），
//  与原版 nextUpdateEpoch 同一套推算：下一集 = 首播 + 周期 × n。
//

import Foundation
import UserNotifications

/// 一条已排定的更新提醒（设置页「通知排程」展示用）。
struct ScheduledUpdateNotification: Identifiable, Hashable {
    let id: Int
    let bangumiID: Int
    let title: String
    let body: String
    let fireAt: Date
}

@MainActor
final class UpdateNotificationScheduler {
    static let shared = UpdateNotificationScheduler()

    /// 最多看未来这么多天（与原版 _maxLead 一致）。
    private static let maxLead: TimeInterval = 7 * 24 * 60 * 60
    private static let idBase = 400_000
    private static let idRange = 100_000
    /// 一部番最多排这么多集，避免长期番把系统队列占满（系统上限 64 条）。
    private static let maxEpisodesPerBangumi = 2

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - 权限

    /// 当前权限状态（不会弹系统弹窗）。
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// 设置页「通知权限」那一行点下去的处理。
    /// 已允许直接返回；从没问过就弹系统弹窗；之前拒绝过的不会再弹，
    /// 只能引导用户去系统设置里手动打开（与原版一致）。
    func ensurePermission() async -> PermissionOutcome {
        let before = await authorizationStatus()
        switch before {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .needsSettings
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            let after = await authorizationStatus()
            if granted, after == .authorized || after == .provisional {
                return .granted
            }
            return after == .notDetermined ? .asked : .needsSettings
        @unknown default:
            return .needsSettings
        }
    }

    enum PermissionOutcome {
        /// 已授权。
        case granted
        /// 弹了系统弹窗，用户没允许。
        case asked
        /// 之前拒绝过，需要用户自己去系统设置打开。
        case needsSettings
    }

    // MARK: - 排定

    /// 按当前追番列表重排提醒。`entries` 传「在看」的那些番。
    ///
    /// 调用方负责判断开关是否打开；关掉时调 `cancelAll()`。
    func reschedule(watching entries: [LibraryEntry], now: Date = Date()) async {
        await cancelAll()
        guard !entries.isEmpty else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            // 没有权限时排了也不会响，等用户在设置里打开再排。
            return
        }

        let calendar = Calendar.current
        for entry in entries {
            guard let schedule = BangumiAirTimeService.shared.schedule(for: entry.id) else { continue }
            var scheduled = 0
            var fireAt = nextOccurrence(of: schedule, after: now)
            while scheduled < Self.maxEpisodesPerBangumi,
                  fireAt.timeIntervalSince(now) > 0,
                  fireAt.timeIntervalSince(now) <= Self.maxLead {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "番剧更新")
                content.body = String(localized: "「\(String(describing: entry.displayName))」已更新")
                content.sound = .default
                content.userInfo = ["bangumiID": entry.id, "fireAt": fireAt.timeIntervalSince1970]

                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: fireAt
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                // 同一部番的两集要各自成条，id 用「番 + 集序号」，否则后一条盖掉前一条。
                let identifier = "\(Self.identifier(for: entry.id))-\(scheduled)"
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
                scheduled += 1
                // 下一集：首播 + 周期 × n，比逐次加一个周期更不容易积累误差。
                fireAt = fireAt.addingTimeInterval(schedule.period)
            }
        }
    }

    /// 关掉提醒时把排定的通知全撤掉。
    func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { identifier in
                guard let prefix = identifier.split(separator: "-").first,
                      let value = Int(prefix) else { return false }
                return value >= Self.idBase && value < Self.idBase + Self.idRange
            }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 已排定的提醒，按时间先后排序（设置页「通知排程」）。
    func scheduledNotifications() async -> [ScheduledUpdateNotification] {
        let pending = await center.pendingNotificationRequests()
        var result: [ScheduledUpdateNotification] = []
        for request in pending {
            // identifier 形如「400123-0」：前半是番的编号，后半是集序号。
            guard let prefix = request.identifier.split(separator: "-").first,
                  let value = Int(prefix),
                  value >= Self.idBase,
                  value < Self.idBase + Self.idRange else { continue }
            let bangumiID = request.content.userInfo["bangumiID"] as? Int ?? 0
            let epoch = request.content.userInfo["fireAt"] as? TimeInterval ?? 0
            guard epoch > 0 else { continue }
            result.append(
                ScheduledUpdateNotification(
                    id: value,
                    bangumiID: bangumiID,
                    title: request.content.title,
                    body: request.content.body,
                    fireAt: Date(timeIntervalSince1970: epoch)
                )
            )
        }
        return result.sorted { $0.fireAt < $1.fireAt }
    }

    // MARK: - 推算

    /// 首播之后、晚于 `now` 的第一次播出时刻。
    private func nextOccurrence(of schedule: BangumiAirSchedule, after now: Date) -> Date {
        guard schedule.period > 0 else { return schedule.first }
        if schedule.first > now { return schedule.first }
        let elapsed = now.timeIntervalSince(schedule.first)
        let cycles = (elapsed / schedule.period).rounded(.down) + 1
        return schedule.first.addingTimeInterval(cycles * schedule.period)
    }

    private static func identifier(for bangumiID: Int) -> Int {
        idBase + (abs(bangumiID) % idRange)
    }
}
