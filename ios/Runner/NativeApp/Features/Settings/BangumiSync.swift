//
//  BangumiSync.swift
//  Kazumi
//
//  「追番同步」的引擎：1:1 翻译 lib/services/sync/bangumi_sync_service.dart
//  与 lib/modules/collect/collect_sync_merger.dart 的 planBangumi。
//
//  为什么必须真做一套引擎：这一页在 Flutter 版里有五个会改变行为的开关
//  （自动同步、同步偏好、同步结果提示、自动标记看过、立即同步）。没有引擎，
//  这些开关只能是「拨了没人读」的假开关 —— 产品上明令禁止。
//
//  与其它同步路径的关系：WebDAV 备份是「本机 ⇄ 备份文件」，这里是
//  「本机 ⇄ Bangumi」，两套互不影响；这里的写入都走 LibraryStore，
//  所以和收藏库、时间表看到的是同一份数据。
//

import Foundation
import Observation

/// 状态冲突时听谁的。数值与 lib/modules/bangumi/sync_priority.dart 一致。
enum BangumiSyncPriority: Int, CaseIterable, Identifiable, Sendable {
    case localFirst = 0
    case bangumiFirst = 1
    case timeFirst = 2

    var id: Int { rawValue }

    /// 进度里用的短名，对应原版 `priority.label`。
    var label: String {
        switch self {
        case .localFirst: String(localized: "本地优先")
        case .bangumiFirst: String(localized: "Bangumi优先")
        case .timeFirst: String(localized: "最新优先")
        }
    }

    /// 「同步偏好」里单选项的标题，逐字照抄 bangumi_sync_page.dart。
    var optionTitle: String {
        switch self {
        case .localFirst: String(localized: "以本机为准")
        case .bangumiFirst: String(localized: "以 Bangumi 为准")
        case .timeFirst: String(localized: "保留最近更新")
        }
    }

    var optionDetail: String {
        switch self {
        case .localFirst: String(localized: "用本机状态更新 Bangumi")
        case .bangumiFirst: String(localized: "用 Bangumi 状态更新本机")
        case .timeFirst: String(localized: "比较两边的更新时间")
        }
    }

    static func from(_ value: Int) -> BangumiSyncPriority {
        BangumiSyncPriority(rawValue: value) ?? .localFirst
    }
}

/// Bangumi 追番同步引擎。
///
/// 一个进程一份：设置页、详情页、播放器都要用它，而它持有「这次运行里验证过的
/// 令牌」这件事本身，多份实例会让三处对「连没连上」各说各话。
@MainActor
@Observable
final class BangumiSyncEngine {
    private let settings: SettingsStore
    private let library: LibraryStore

    /// 这次运行里被服务器认过的令牌。只有它和 username 都齐了才算「连上了」。
    private var verifiedToken: String?
    private(set) var username = ""
    private(set) var isConnecting = false
    private(set) var lastError: String?

    /// 串行队列的替代：同步、推送、连接三种操作不能同时跑。
    private var operations: Task<Void, Never>?

    init(settings: SettingsStore, library: LibraryStore) {
        self.settings = settings
        self.library = library
        // 启动时把存下来的用户名接回来（LP 5429）：它跟令牌一样属于账号的一部分，
        // 不能在重启后退回「已保存」——那等于让用户以为登录没了。
        self.username = settings.bangumiUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这次运行里服务器认过这个令牌。还是「连没连上」的唯一判据，
    /// 只是界面不再拿它决定要不要显示用户名（见 `hasSavedAccount`）。
    var initialized: Bool {
        verifiedToken != nil && !username.isEmpty
    }

    /// 存着令牌、也存着用户名：算已经登录过的账号，界面照用户名显示（LP 5429）。
    var hasSavedAccount: Bool {
        configured && !username.isEmpty
    }

    /// 配置里有没有令牌（没验证过也算配置过）。
    var configured: Bool {
        !settings.bangumiAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var priority: BangumiSyncPriority {
        BangumiSyncPriority.from(settings.bangumiSyncPriority)
    }

    // MARK: - 连接

    /// 「测试连接 / 重试连接」。
    func ping() async {
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }
        do {
            username = try await validateToken(settings.bangumiAccessToken)
            verifiedToken = settings.bangumiAccessToken
            lastError = nil
        } catch {
            verifiedToken = nil
            // 名字是账号的一部分，验证失败不清掉它：清了界面就退回「已保存」。
            username = settings.bangumiUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = Self.describeError(error)
        }
    }

    /// 验证并保存令牌。失败时抛错，让输入框把那句话显示在字段下面。
    ///
    /// 只在验证通过之后才写进设置：写一个没被认过的令牌，等于替一个坏凭据担保。
    func saveToken(_ value: String) async throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw BangumiSyncError.emptyToken }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let name = try await validateToken(token)
            settings.bangumiAccessToken = token
            settings.bangumiUsername = name
            verifiedToken = token
            username = name
            lastError = nil
        } catch {
            if token == settings.bangumiAccessToken {
                verifiedToken = nil
                username = settings.bangumiUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = Self.describeError(error)
            }
            throw error
        }
    }

    /// 打开 / 关闭「自动同步追番」。打开时先验证一次，验证不过就不打开。
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await ping()
            guard lastError == nil else { return }
        }
        settings.bangumiSyncEnable = enabled
    }

    private func validateToken(_ raw: String) async throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw BangumiSyncError.emptyToken }
        // 验证要拿「待验证的那串」去问，而不是先写进设置：saveToken 的成功路径才写。
        let previous = BangumiAPI.accessToken
        BangumiAPI.accessToken = token
        defer { BangumiAPI.accessToken = previous }
        switch await BangumiAPI.checkToken() {
        case let .ok(_, _, username):
            guard !username.isEmpty else { throw BangumiSyncError.incompleteUser }
            return username
        case .missing:
            throw BangumiSyncError.emptyToken
        case .rejected:
            throw BangumiSyncError.rejected
        case let .unreachable(message):
            throw BangumiSyncError.unreachable(message)
        }
    }

    // MARK: - 立即同步

    /// 全量同步：拉远端 → 比差异 → 按偏好双向写。进度用 (文案, 当前, 总数) 报出去。
    func syncCollectibles(
        onProgress: @escaping @Sendable @MainActor (String, Int, Int) -> Void
    ) async throws {
        guard settings.bangumiSyncEnable else { throw BangumiSyncError.syncDisabled }
        if !initialized { await ping() }
        if let lastError { throw BangumiSyncError.failed(lastError) }

        onProgress(String(localized: "开始同步 Bangumi 状态"), 0, 0)
        let remote = try await BangumiAPI.remoteCollections(username: username) { message, current, total in
            // 拉取进度要回主线程再报：页面直接改 @State。
            Task { @MainActor in onProgress(message, current, total) }
        }
        let plan = Self.plan(
            local: library.entries,
            remote: remote,
            priority: priority
        )
        let total = plan.totalOperations
        if total == 0 {
            onProgress(String(localized: "未发现状态差异，无需同步"), 1, 1)
            return
        }

        var done = 0
        if !plan.localOnlyUploads.isEmpty {
            onProgress(String(localized: "正在上传本地新增状态"), done, total)
            for upload in plan.localOnlyUploads {
                let ok = await BangumiAPI.updateCollection(
                    subjectID: upload.subjectID,
                    type: upload.type
                )
                guard ok else { throw BangumiSyncError.uploadFailed(upload.subjectID) }
                done += 1
                onProgress(String(localized: "正在上传本地新增状态"), done, total)
            }
        }
        if !plan.remoteOnlyPuts.isEmpty {
            onProgress(String(localized: "正在补全本地缺失状态"), done, total)
            for put in plan.remoteOnlyPuts {
                apply(put)
                done += 1
                onProgress(String(localized: "正在补全本地缺失状态"), done, total)
            }
        }
        if !plan.conflictUploads.isEmpty {
            onProgress(String(localized: "\(priority.label)：正在上传冲突状态"), done, total)
            for upload in plan.conflictUploads {
                let ok = await BangumiAPI.updateCollection(
                    subjectID: upload.subjectID,
                    type: upload.type
                )
                guard ok else { throw BangumiSyncError.uploadFailed(upload.subjectID) }
                done += 1
                onProgress(String(localized: "\(priority.label)：正在上传冲突状态"), done, total)
            }
        }
        if !plan.conflictLocalUpdates.isEmpty {
            onProgress(String(localized: "\(priority.label)：正在更新本地冲突状态"), done, total)
            for put in plan.conflictLocalUpdates {
                apply(put)
                done += 1
                onProgress(String(localized: "\(priority.label)：正在更新本地冲突状态"), done, total)
            }
        }
        onProgress(String(localized: "Bangumi 状态同步完成"), 1, 1)
    }

    /// 改了一条追番状态之后把这一条推上去（对应 syncCollectibleWhenIdle）。
    ///
    /// 返回 false 表示没推成功，调用方要按原版的规矩把本地这次修改退回去 ——
    /// 本地显示「已看过」而 Bangumi 上还是「在看」，比不改更让人糊涂。
    func pushCollectible(bangumiID: Int, type: CollectType) async -> Bool {
        if !initialized { await ping() }
        guard initialized else { return false }
        return await BangumiAPI.updateCollection(subjectID: bangumiID, type: type)
    }

    // MARK: - 合并

    /// 一次同步要做的事。对应 BangumiCollectiblesMergePlan。
    struct Plan: Sendable {
        var localOnlyUploads: [Upload] = []
        var remoteOnlyPuts: [LocalPut] = []
        var conflictUploads: [Upload] = []
        var conflictLocalUpdates: [LocalPut] = []

        var totalOperations: Int {
            localOnlyUploads.count + remoteOnlyPuts.count + conflictUploads.count + conflictLocalUpdates.count
        }
    }

    struct Upload: Sendable {
        var subjectID: Int
        var type: CollectType
    }

    struct LocalPut: Sendable {
        var entry: LibraryEntry
        var changeAction: Int
    }

    /// 对应 CollectSyncMerger.planBangumi。
    ///
    /// 只比较「收藏状态」：本机有远端没有 → 上传；远端有本机没有 → 落到本地；
    /// 两边都有但状态不同 → 按偏好决定谁覆盖谁。
    static func plan(
        local: [LibraryEntry],
        remote: [BangumiAPI.RemoteCollection],
        priority: BangumiSyncPriority
    ) -> Plan {
        var localMap: [Int: LibraryEntry] = [:]
        for entry in local where entry.collectType != .none {
            localMap[entry.id] = entry
        }
        var remoteMap: [Int: BangumiAPI.RemoteCollection] = [:]
        for item in remote {
            // Bangumi 的 0 = 未收藏，等于「远端没有」，不能当成一条冲突。
            guard let type = collectType(bangumiType: item.type), type != .none else { continue }
            remoteMap[item.subjectID] = item
        }

        var plan = Plan()
        for id in localMap.keys.sorted() where remoteMap[id] == nil {
            let localEntry = localMap[id]!
            plan.localOnlyUploads.append(Upload(subjectID: id, type: localEntry.collectType))
        }
        for id in remoteMap.keys.sorted() where localMap[id] == nil {
            plan.remoteOnlyPuts.append(
                LocalPut(entry: entry(from: remoteMap[id]!), changeAction: 1)
            )
        }

        let sharedIDs = localMap.keys.filter { remoteMap[$0] != nil }.sorted()
        for id in sharedIDs {
            let existing = localMap[id]!
            let item = remoteMap[id]!
            guard let remoteType = collectType(bangumiType: item.type),
                  remoteType != existing.collectType else { continue }
            switch priority {
            case .localFirst:
                plan.conflictUploads.append(Upload(subjectID: id, type: existing.collectType))
            case .bangumiFirst:
                plan.conflictLocalUpdates.append(LocalPut(entry: entry(from: item), changeAction: 2))
            case .timeFirst:
                if existing.updatedAt >= item.updatedAt {
                    plan.conflictUploads.append(Upload(subjectID: id, type: existing.collectType))
                } else {
                    plan.conflictLocalUpdates.append(LocalPut(entry: entry(from: item), changeAction: 2))
                }
            }
        }
        return plan
    }

    /// Bangumi 的收藏类型 → 本地收藏类型。对应 collect_type_mapper.dart。
    static func collectType(bangumiType: Int) -> CollectType? {
        switch bangumiType {
        case 0: .none
        case 1: .wish
        case 2: .watched
        case 3: .watching
        case 4: .onHold
        case 5: .dropped
        default: nil
        }
    }

    /// 远端条目落成本地条目，字段对齐 LibraryEntry 的数集。
    private static func entry(from item: BangumiAPI.RemoteCollection) -> LibraryEntry {
        LibraryEntry(
            id: item.subjectID,
            type: collectType(bangumiType: item.type)?.rawValue ?? 0,
            name: item.name,
            nameCn: item.nameCn,
            summary: item.summary,
            airDate: item.airDate,
            imageURL: item.imageURL,
            rating: item.rating,
            rank: item.rank,
            tags: item.tags,
            totalEpisodes: item.totalEpisodes,
            // 集数进度只有 Bangumi 上要知道；这里不覆盖本机的观看进度。
            currentEpisode: 0,
            addedAt: item.updatedAt,
            updatedAt: item.updatedAt
        )
    }

    /// 把远端的写法落到本机。已有条目只改状态与时间，不动名字 / 集数这些本地字段：
    /// 本地那份可能带着用户自己的进度，整条覆盖会把它抹掉。
    private func apply(_ put: LocalPut) {
        if var existing = library.entry(for: put.entry.id) {
            existing.type = put.entry.type
            existing.updatedAt = put.entry.updatedAt
            if existing.nameCn.isEmpty { existing.nameCn = put.entry.nameCn }
            if existing.imageURL.isEmpty { existing.imageURL = put.entry.imageURL }
            library.upsert(existing)
        } else {
            library.upsert(put.entry)
        }
    }

    // MARK: - 错误文案

    /// 逐条对着原版 describeError 的说法，用户在页面上看到的就是这些句子。
    nonisolated static func describeError(_ error: Error) -> String {
        switch error {
        case BangumiSyncError.emptyToken:
            return String(localized: "请先在 Bangumi 配置中填写并保存 Access Token")
        case BangumiSyncError.incompleteUser:
            return String(localized: "Bangumi 用户信息不完整")
        case BangumiSyncError.rejected:
            return String(localized: "Access Token 无效或已过期，请在 Bangumi 配置中更换 Token")
        case let BangumiSyncError.unreachable(message):
            return message
        case BangumiSyncError.syncDisabled:
            return String(localized: "请先开启 Bangumi 同步")
        case let BangumiSyncError.uploadFailed(id):
            return String(localized: "同步失败：条目 \(id) 上传到 Bangumi 失败")
        case let BangumiSyncError.failed(message):
            return message
        case let error as NetworkError:
            if case let .badResponse(status, _, _) = error {
                switch status {
                case 401:
                    return String(localized: "Access Token 无效或已过期，请在 Bangumi 配置中更换 Token")
                case 403:
                    return String(localized: "Bangumi 拒绝访问，请检查 Token 权限或稍后重试")
                case 429:
                    return String(localized: "Bangumi 请求过于频繁，请稍后重试")
                default:
                    return String(localized: "Bangumi 服务请求失败（HTTP \(status)），请稍后重试")
                }
            }
            return error.localizedDescription
        case let error as DecodingError:
            return String(localized: "Bangumi 返回的数据格式异常：\(error.localizedDescription)")
        default:
            return String(localized: "Bangumi 操作失败，请稍后重试")
        }
    }
}

/// 引擎自己产生的失败。把「哪一步失败」和「该显示哪句话」分开，
/// 页面就不用去解析错误字符串。
enum BangumiSyncError: LocalizedError {
    case emptyToken
    case incompleteUser
    case rejected
    case unreachable(String)
    case syncDisabled
    case uploadFailed(Int)
    case failed(String)

    var errorDescription: String? {
        BangumiSyncEngine.describeError(self)
    }
}
