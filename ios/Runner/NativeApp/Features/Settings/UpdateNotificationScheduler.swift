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
import UIKit
import UserNotifications

/// 一条已排定的更新提醒（设置页「通知排程」展示用）。
struct ScheduledUpdateNotification: Identifiable, Hashable {
    let id: String
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
    private static let defaultPeriod: TimeInterval = 7 * 24 * 60 * 60
    private static let idBase = 400_000
    private static let idRange = 100_000
    /// 一部番最多排这么多集，避免长期番把系统队列占满（系统上限 64 条）。
    private static let maxEpisodesPerBangumi = 2
    /// 留出少量余量，避免触顶 iOS 单应用 64 条本地通知上限后新番被系统静默淘汰。
    private static let maxPendingRequests = 60

    private let center = UNUserNotificationCenter.current()
    /// 串行化排程操作，防止并发 `reschedule` / `cancelAll` 交错把刚排好的提醒撤空。
    private var lastOperation: Task<Void, Never>?

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
        await enqueue { [self] in
            await self.performReschedule(watching: entries, now: now)
        }
    }

    /// 关掉提醒时把排定的通知全撤掉。
    func cancelAll() async {
        await enqueue { [self] in
            await self.removeManagedPendingRequests()
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        lastOperation = task
        await task.value
    }

    private struct CandidateMeta: Sendable {
        let fireAt: Date
        let bangumiID: Int
        let displayName: String
        let identifier: String
        let coverURLString: String
    }

    private func performReschedule(watching entries: [LibraryEntry], now: Date) async {
        guard !entries.isEmpty else {
            await removeManagedPendingRequests()
            return
        }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            // 没有权限时排了也不会响，等用户在设置里打开再排。
            await removeManagedPendingRequests()
            return
        }

        var candidates: [CandidateMeta] = []
        candidates.reserveCapacity(entries.count * Self.maxEpisodesPerBangumi)

        for entry in entries {
            let airing = AniListClient.shared.staleCached(entry.id, now: now)
            // 已明确完结的番不再按周期无限顺延，避免占满系统 64 条通知名额。
            if let airing, airing.finished { continue }

            let schedule = BangumiAirTimeService.shared.schedule(for: entry.id)
            if airing == nil,
               entry.totalEpisodes > 0,
               let schedule,
               schedule.period > 0,
               now.timeIntervalSince(schedule.first) >= Double(entry.totalEpisodes) * schedule.period {
                continue
            }

            guard let firstFireAt = firstUpcomingDate(for: entry.id, schedule: schedule, now: now) else {
                continue
            }
            let period = (schedule?.period ?? 0) > 0 ? schedule!.period : Self.defaultPeriod

            let coverURL = !entry.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? entry.imageURL
                : (BangumiSubjectCache.shared.memoryItem(for: entry.id)?.largeImage ?? "")

            var scheduled = 0
            var fireAt = firstFireAt
            while scheduled < Self.maxEpisodesPerBangumi,
                  fireAt.timeIntervalSince(now) > 0,
                  fireAt.timeIntervalSince(now) <= Self.maxLead {
                // 同一部番的两集要各自成条，id 用「番 + 集序号」，否则后一条盖掉前一条。
                let identifier = "\(Self.identifier(for: entry.id))-\(scheduled)"
                candidates.append(
                    CandidateMeta(
                        fireAt: fireAt,
                        bangumiID: entry.id,
                        displayName: entry.displayName,
                        identifier: identifier,
                        coverURLString: coverURL
                    )
                )
                scheduled += 1
                fireAt = firstFireAt.addingTimeInterval(Double(scheduled) * period)
            }
        }

        // 先按触发时刻从近到远排序并截断至前 60 条候选元数据，再在后台按 coverURLString 去重准备封面附件。
        candidates.sort { $0.fireAt < $1.fireAt }
        let selected = Array(candidates.prefix(Self.maxPendingRequests))

        let preparedCoverURLs: [String: URL] = await Task.detached(priority: .utility) {
            Self.prepareCoverAttachmentFiles(for: selected)
        }.value

        var tempURLsToClean = Array(preparedCoverURLs.values)
        defer {
            for tempURL in tempURLsToClean {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let calendar = Calendar.current
        var requests: [UNNotificationRequest] = []
        requests.reserveCapacity(selected.count)
        for meta in selected {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "番剧更新")
            content.body = String(localized: "「\(String(describing: meta.displayName))」已更新")
            content.sound = .default
            content.userInfo = ["bangumiID": meta.bangumiID, "fireAt": meta.fireAt.timeIntervalSince1970]

            if let tempURL = preparedCoverURLs[meta.identifier],
               let attachment = try? UNNotificationAttachment(
                   identifier: "cover-\(meta.identifier)",
                   url: tempURL,
                   options: nil
               ) {
                content.attachments = [attachment]
            }

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: meta.fireAt
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            requests.append(
                UNNotificationRequest(
                    identifier: meta.identifier,
                    content: content,
                    trigger: trigger
                )
            )
        }

        // 先算完新队列再一次性替换旧通知，避免耗时计算期间把排程清空。
        await removeManagedPendingRequests()
        for request in requests {
            try? await center.add(request)
        }
        // 已成功添加的通知附件会被系统移走；剩余未被移走的临时文件由 defer 统一清理。
        tempURLsToClean = tempURLsToClean.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private func removeManagedPendingRequests() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter(Self.isManagedIdentifier)
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 已排定的提醒，按时间先后排序（设置页「通知排程」）。
    func scheduledNotifications() async -> [ScheduledUpdateNotification] {
        // 若正有一轮排程写入在执行，等它落地后再读取，避免读到「刚撤旧、未加新」的瞬间空窗。
        await lastOperation?.value
        let pending = await center.pendingNotificationRequests()
        var result: [ScheduledUpdateNotification] = []
        for request in pending {
            guard Self.isManagedIdentifier(request.identifier) else { continue }
            let bangumiID = request.content.userInfo["bangumiID"] as? Int ?? 0
            let epoch = request.content.userInfo["fireAt"] as? TimeInterval ?? 0
            guard epoch > 0 else { continue }
            result.append(
                ScheduledUpdateNotification(
                    id: request.identifier,
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

    /// 结合 AniList 实测下一集与 bangumi-mal 季度首播周期，推算晚于 `now` 的下一次更新时间。
    private func firstUpcomingDate(
        for subjectID: Int,
        schedule: BangumiAirSchedule?,
        now: Date
    ) -> Date? {
        if let epochMs = BangumiAirTimeService.shared.nextUpdateEpoch(for: subjectID, now: now) {
            let candidate = Date(timeIntervalSince1970: Double(epochMs) / 1000)
            if candidate > now { return candidate }
        }
        guard let schedule else { return nil }
        return nextOccurrence(of: schedule, after: now)
    }

    private static func isManagedIdentifier(_ identifier: String) -> Bool {
        guard let prefix = identifier.split(separator: "-").first,
              let value = Int(prefix) else { return false }
        return value >= idBase && value < idBase + idRange
    }

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

    // MARK: - 封面附件

    /// 在后台按 `coverURLString` 去重读取本地缓存与转码（如 WebP → JPEG），
    /// 再为每条待排程通知写出独立的临时附件文件（系统 add 时会移动各自文件）。
    private enum CachedCover {
        case hit(data: Data, ext: String)
        case miss
    }

    private nonisolated static func prepareCoverAttachmentFiles(
        for candidates: [CandidateMeta]
    ) -> [String: URL] {
        var encodedCache: [String: CachedCover] = [:]
        var result: [String: URL] = [:]
        let tempDir = FileManager.default.temporaryDirectory

        for candidate in candidates where !candidate.coverURLString.isEmpty {
            let key = candidate.coverURLString
            let entry: CachedCover
            if let cached = encodedCache[key] {
                entry = cached
            } else if let loaded = loadEncodedCoverData(for: key) {
                entry = .hit(data: loaded.data, ext: loaded.ext)
                encodedCache[key] = entry
            } else {
                entry = .miss
                encodedCache[key] = entry
            }
            guard case let .hit(data, ext) = entry else { continue }

            let tempURL = tempDir
                .appendingPathComponent("notif_cover_\(UUID().uuidString)")
                .appendingPathExtension(ext)
            do {
                try data.write(to: tempURL, options: .atomic)
                result[candidate.identifier] = tempURL
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
        return result
    }

    private nonisolated static func loadEncodedCoverData(
        for coverURLString: String
    ) -> (data: Data, ext: String)? {
        guard let data = KazumiImageLoader.shared.cachedDiskData(for: coverURLString) else {
            return nil
        }
        // 识别图片魔数，确认为标准 JPEG 或 PNG；其他格式（如 WebP）转为 JPEG 以便 iOS 通知服务原生显示。
        let isJPEG = data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
        let isPNG = data.count >= 4 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47
        if isJPEG {
            return (data, "jpg")
        }
        if isPNG {
            return (data, "png")
        }
        guard let image = UIImage(data: data),
              let converted = image.jpegData(compressionQuality: 0.85) else {
            return nil
        }
        return (converted, "jpg")
    }
}
