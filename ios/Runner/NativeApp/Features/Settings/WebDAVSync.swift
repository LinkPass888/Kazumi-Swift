//
//  WebDAVSync.swift
//  Kazumi
//
//  设置 →「同步设置」→「多设备同步」的同步引擎。
//
//  和「立即备份 / 从备份恢复」那条整包路径分开：整包是「这台机器盖掉那台」，
//  同步是「两边合成一份」——先把云盘上那份读回来，按内容逐类合并，
//  再把合并结果写回去，最后只把开着的两类写回本机。
//
//  合并规则：
//  · 观看记录以「规则 + 番剧」为主键，同一条内部把每集进度并起来（新的一份赢）；
//    收藏以番剧 ID 为主键，同一条留 `updatedAt` 新的那份；
//  · 弹幕屏蔽词按规则合并（含删除墓碑，按 updatedAt/deviceId/deleted 取新的那份），
//    本机的顺序在前，云盘多出来的接在后面。
//
//  关掉的那一类不拉、不写本机，写回云盘时也原样用云盘那份，
//  免得「只开了观看记录」把云盘上的收藏冲成空。
//

import Foundation

@MainActor
enum WebDAVSync {
    enum Content: String, CaseIterable, Sendable {
        case history
        case collect
        case shield

        /// 屏上那行标题，跟原版一致。
        var rowTitle: String {
            switch self {
            case .history: "观看记录"
            case .collect: "收藏"
            case .shield: "弹幕屏蔽词"
            }
        }

        /// 同步做完给用户看的那一句。
        var doneMessage: String {
            switch self {
            case .history: String(localized: "观看记录已同步")
            case .collect: String(localized: "收藏已同步")
            case .shield: String(localized: "弹幕屏蔽词已同步")
            }
        }

        var runningMessage: String {
            switch self {
            case .history: String(localized: "正在同步观看记录…")
            case .collect: String(localized: "正在同步收藏…")
            case .shield: String(localized: "正在同步弹幕屏蔽词…")
            }
        }
    }

    struct Outcome: Sendable {
        var ok: Bool
        /// 屏上那句。
        var message: String
        /// 进运行日志那句，带技术原文。
        var log: String
        /// 同步结果里第二行那串数字；空串表示没什么可写的。
        var summary: String = ""
    }

    /// 同步中途那一行报给屏上的进度。`total` 为 0 时不画进度条。
    struct ProgressEvent: Sendable {
        var text: String
        var current: Int
        var total: Int
    }

    /// 这台机器上被打开的内容。
    static func enabledContents(_ settings: SettingsStore) -> [Content] {
        var contents: [Content] = []
        if settings.webDavEnableHistory { contents.append(.history) }
        if settings.webDavEnableCollect { contents.append(.collect) }
        if settings.webDavEnableDanmakuShield { contents.append(.shield) }
        return contents
    }

    /// 合并一轮：读云盘 → 逐类合并 → 写回 → 只把开着的那几类落到本机。
    static func sync(
        _ contents: [Content],
        settings: SettingsStore,
        library: LibraryStore,
        progress: (@MainActor (ProgressEvent) -> Void)? = nil
    ) async -> Outcome {
        guard !contents.isEmpty else {
            return Outcome(ok: true, message: "", log: "")
        }
        guard !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(ok: false, message: String(localized: "先填 WebDAV 地址"), log: "同步跳过：没配地址")
        }

        let client = WebDAVClient(settings: settings)
        progress?(ProgressEvent(text: String(localized: "正在读取云盘…"), current: 0, total: 0))
        let remote: WebDAVClient.Payload?
        /// 云盘上那份是空的（0 字节）：当作还没备份，这次上传会把它覆盖掉。
        /// 空文件里没有任何数据，覆盖它不会丢掉任何东西。
        var cloudBackupWasEmpty = false
        do {
            remote = try await client.download()
        } catch WebDAVClient.WebDAVError.notFound, WebDAVClient.WebDAVError.badStatus(404) {
            // 云盘上还没有这份文件：当作空的一份，这次同步就是第一次上传。
            //
            // 必须接 .notFound：客户端把 404 翻成了这一句（WebDAVClient.validate），
            // 只接 badStatus(404) 会漏掉，「第一次同步」永远报成网络失败。
            remote = nil
        } catch WebDAVClient.WebDAVError.emptyBackup {
            // 文件在，但是 0 字节。跟「还没有备份」一样处理：本机有数据就上传一份。
            cloudBackupWasEmpty = true
            remote = nil
        } catch {
            return Outcome(
                ok: false,
                message: String(localized: "同步没能完成：\(Self.friendlyText(error))"),
                log: String(localized: "同步读云盘失败：\(String(describing: Self.technicalText(error)))")
            )
        }

        let localRules = settings.danmakuFilterRulesText
        var history = remote?.history ?? []
        var entries = remote?.entries ?? []
        var rules = remote?.danmakuRules ?? ""

        // 云盘上还留着原版 Flutter 写的那几份（LP 2026-10-25：换过来以后老数据得合进来）。
        // 它们不是本端的包，只能按各自格式读一遍；读不出来的当没有，不挡这次同步。
        //
        // 观看记录与屏蔽词：两边都是 JSON、同一套数据，每次同步读一遍并进去就行，
        // 不需要「并过没有」的记号（LP 2026-10-28）。
        var legacyHistoryCount = 0
        var legacyRules: [String] = []
        /// 这一轮合并出来的屏蔽词状态（含墓碑），写回本机那份文件时用。
        var mergedShieldState: WebDAVLegacy.ShieldState?
        // 云盘上那份原版快照读到了没有：没读到就不许写回，
        // 否则一次网络抖动就会把云盘上的老记录冲成本机这几条。
        var legacyHistoryRead = false
        var legacySnapshot: Data?
        if contents.contains(.history) {
            if let legacy = try? await WebDAVLegacy.history(client: client) {
                legacyHistoryRead = legacy.raw != nil
                legacySnapshot = legacy.raw
                legacyHistoryCount = legacy.records.count
                history = mergeHistory(
                    local: adoptLegacyRuleNames(library.history, from: legacy.records),
                    remote: history + legacy.records
                )
            } else {
                history = mergeHistory(local: library.history, remote: history)
            }
        } else {
            history = remote?.history ?? []
        }

        // 收藏：只有它换格式（旧版是 Hive 二进制箱体），所以只有它带记号，而且带时间。
        //
        // 记号记的是「上一次并的是箱体哪一刻的版本」，不是「并过没有」：
        // 旧版要是在别的设备上又改过收藏，云盘上那份箱体的修改时间会比记号新，就该再并一轮。
        var legacyCollectCount = 0
        var legacyCollectRemovals: [Int: Date] = [:]
        var legacyCollectMergedAt = remote?.legacyCollectMergedAt
        var mergedRemovals: [RemovedEntry] = remote?.removedEntries ?? []
        if contents.contains(.collect) {
            var legacyEntries: [LibraryEntry] = []
            let boxModified = await Self.modifiedDate(of: WebDAVLegacy.collectiblesPath, client: client)
            let stored = remote?.legacyCollectMergedAt
            if let boxModified, stored == nil || boxModified > stored! {
                if let legacy = try? await WebDAVLegacy.collectibles(client: client) {
                    legacyEntries = legacy.entries
                    legacyCollectRemovals = legacy.removals
                    legacyCollectCount = legacy.entries.count
                    // 云盘上确实有这份箱体，才写这个字段（LP 3886：本来就没有旧格式就不写）。
                    legacyCollectMergedAt = boxModified
                }
            }
            entries = mergeEntries(local: library.entries, remote: entries + legacyEntries)

            // 取消收藏：本机记的、云盘备份里记的、旧版变更队列里记的三处并起来，按时间判先后。
            var removals: [Int: Date] = [:]
            func noteRemoval(_ id: Int, _ date: Date) {
                if let existing = removals[id], existing >= date { return }
                removals[id] = date
            }
            for item in remote?.removedEntries ?? [] { noteRemoval(item.id, item.removedAt) }
            for item in library.removedEntries { noteRemoval(item.id, item.removedAt) }
            for (id, date) in legacyCollectRemovals { noteRemoval(id, date) }
            // 取消比收藏晚，才真的删；取消得早说明后来重新收藏了，留着。
            entries.removeAll { entry in
                guard let removedAt = removals[entry.id] else { return false }
                return removedAt > entry.updatedAt
            }
            // 还收藏着的不用再记着取消过。
            let collectedIDs = Set(entries.map(\.id))
            removals = removals.filter { !collectedIDs.contains($0.key) }
            mergedRemovals = removals
                .map { RemovedEntry(id: $0.key, removedAt: $0.value) }
                .sorted { $0.id < $1.id }
        } else {
            entries = remote?.entries ?? []
        }

        if contents.contains(.shield) {
            // 本机当前的规则（设置里那串文本）。
            let localList = Self.ruleLines(localRules)
            // 本端备份里那份也是云端数据，没有编辑时间，按 updatedAt 0 参与合并。
            let backupList = Self.ruleLines(rules)
            let readSnapshot = try? await WebDAVLegacy.shieldState(
                client: client,
                deviceID: settings.webDAVDeviceID
            )
            let snapshot = readSnapshot ?? WebDAVLegacy.ShieldSnapshot()
            legacyRules = snapshot.merged.rules

            var merged = snapshot.merged
            // 本机有、状态里没有的规则：updatedAt 0，盖不过云端带时间戳的墓碑。
            for rule in localList where merged.entries[rule] == nil {
                merged.insert(WebDAVLegacy.ShieldEntry(
                    rule: rule,
                    updatedAt: 0,
                    deviceId: settings.webDAVDeviceID,
                    deleted: false
                ))
            }
            // 本端备份里的规则：同样没有编辑时间，用本机设备号补上，
            // 写回去时 deviceId 不能为空（main 会判整份文件无效）。
            for rule in backupList where merged.entries[rule] == nil {
                merged.insert(WebDAVLegacy.ShieldEntry(
                    rule: rule,
                    updatedAt: 0,
                    deviceId: settings.webDAVDeviceID,
                    deleted: false
                ))
            }
            // 本机上次写上去时还是可见、这次设置里已经没有的规则 = 本机删掉的。
            // 写成墓碑，时间取 max(now, latest + 1)，保证比云端已有的都新。
            let localSet = Set(localList)
            let now = Int(Date().timeIntervalSince1970 * 1000)
            var latest = merged.latestTimestamp
            for rule in snapshot.own.order {
                guard let entry = snapshot.own.entries[rule],
                      !entry.deleted,
                      !localSet.contains(rule),
                      merged.entries[rule]?.deleted == false
                else { continue }
                latest = latest == Int.max ? Int.max : max(now, latest + 1)
                merged.insert(WebDAVLegacy.ShieldEntry(
                    rule: rule,
                    updatedAt: latest,
                    deviceId: settings.webDAVDeviceID,
                    deleted: true
                ))
            }
            // 用户看到的行序跟以前一致：本机在前，备份多出来的其次，
            // 云盘原版多出来的最后。
            var lines: [String] = []
            var seen = Set<String>()
            for rule in localList {
                guard let entry = merged.entries[rule], !entry.deleted else { continue }
                if seen.insert(rule).inserted { lines.append(rule) }
            }
            for rule in backupList {
                guard let entry = merged.entries[rule], !entry.deleted else { continue }
                if seen.insert(rule).inserted { lines.append(rule) }
            }
            for rule in merged.order {
                guard let entry = merged.entries[rule], !entry.deleted else { continue }
                if seen.insert(rule).inserted { lines.append(rule) }
            }
            rules = lines.joined(separator: "\n")
            // 云盘没读到就不写回：拿空状态盖上去会把本机那份里的墓碑冲掉。
            mergedShieldState = readSnapshot == nil ? nil : merged
        } else {
            rules = remote?.danmakuRules ?? ""
        }

        progress?(ProgressEvent(text: String(localized: "正在上传合并结果…"), current: 0, total: 0))
        let payload = WebDAVClient.Payload(
            entries: entries,
            history: history,
            danmakuRules: rules,
            legacyCollectMergedAt: legacyCollectMergedAt,
            removedEntries: mergedRemovals
        )
        do {
            try await client.uploadAndVerify(payload)
        } catch {
            return Outcome(
                ok: false,
                message: String(localized: "同步没能完成：\(Self.friendlyText(error))"),
                log: String(localized: "同步写云盘失败：\(String(describing: Self.technicalText(error)))")
            )
        }

        if contents.contains(.collect) {
            entries = mergeEntries(local: library.entries, remote: entries)
            var removals: [Int: Date] = [:]
            func noteRemoval(_ id: Int, _ date: Date) {
                if let existing = removals[id], existing >= date { return }
                removals[id] = date
            }
            for item in mergedRemovals { noteRemoval(item.id, item.removedAt) }
            for item in library.removedEntries { noteRemoval(item.id, item.removedAt) }
            entries.removeAll { entry in
                guard let removedAt = removals[entry.id] else { return false }
                return removedAt > entry.updatedAt
            }
            let collectedIDs = Set(entries.map(\.id))
            mergedRemovals = removals
                .filter { !collectedIDs.contains($0.key) }
                .map { RemovedEntry(id: $0.key, removedAt: $0.value) }
                .sorted { $0.id < $1.id }
        }
        if contents.contains(.history) {
            history = mergeHistory(local: library.history, remote: history)
        }

        // 落到本机：开着的那几类用合并结果，没开的原样不动。
        let localEntries = contents.contains(.collect) ? entries : library.entries
        let localHistory = contents.contains(.history) ? history : library.history
        library.replace(entries: localEntries, history: localHistory)
        if contents.contains(.collect) {
            library.replaceRemovals(mergedRemovals)
        }
        if contents.contains(.shield) {
            settings.danmakuFilterRulesText = rules
        }

        // 写回原版那几份（LP 2026-10-25：历史与屏蔽词要支持读写，旧版得读到新记录）。
        var writeBackError: String?
        if contents.contains(.history), legacyHistoryRead {
            do {
                try await WebDAVLegacy.writeHistory(
                    history,
                    existing: legacySnapshot,
                    client: client
                ) { current, total in
                    progress?(ProgressEvent(
                        text: String(localized: "正在写回原版观看记录 · \(current) / \(total)"),
                        current: current,
                        total: total
                    ))
                }
            } catch {
                writeBackError = Self.technicalText(error)
            }
        }
        if contents.contains(.shield), let mergedShieldState {
            // 只写本机那一份，别的设备的文件一概不碰。整份状态都要写，墓碑不能丢。
            do {
                try await WebDAVLegacy.writeShield(
                    mergedShieldState,
                    deviceID: settings.webDAVDeviceID,
                    client: client
                )
            } catch {
                writeBackError = Self.technicalText(error)
            }
        }

        var summaryParts: [String] = []
        if contents.contains(.history) { summaryParts.append(String(localized: "观看记录 \(history.count) 条")) }
        if contents.contains(.collect) { summaryParts.append(String(localized: "收藏 \(entries.count) 部")) }
        if contents.contains(.shield) { summaryParts.append(String(localized: "屏蔽词 \(Self.ruleCount(rules)) 条")) }
        let summary = summaryParts.joined(separator: " · ")

        let counts = String(localized: "观看记录 \(library.history.count) 条 / 收藏 \(library.entries.count) 部 / 屏蔽词 \(Self.ruleCount(rules)) 条")
        var legacyParts: [String] = []
        if legacyHistoryCount > 0 { legacyParts.append(String(localized: "历史 \(legacyHistoryCount) 条")) }
        if !legacyRules.isEmpty { legacyParts.append(String(localized: "屏蔽词 \(legacyRules.count) 条")) }
        if legacyCollectCount > 0 { legacyParts.append(String(localized: "收藏 \(legacyCollectCount) 部")) }
        let listSep = "、"
        let legacy = legacyParts.isEmpty ? "" : String(localized: "；原版旧数据：\(legacyParts.joined(separator: listSep))")
        if let writeBackError {
            return Outcome(
                ok: false,
                message: String(localized: "已同步，但没能写回旧版格式：\(writeBackError)"),
                log: String(localized: "多设备同步完成但写回原版格式失败（\(String(describing: counts))\(String(describing: legacy))）：\(String(describing: writeBackError))"),
                summary: String(localized: "\(summary) · 写回旧版格式失败")
            )
        }
        let base = contents.count == 1 ? contents[0].doneMessage : String(localized: "同步完成")
        // 云盘上原来那份是空的：说一句，别让他继续以为云上一直存着一份。
        let message = cloudBackupWasEmpty
            ? String(localized: "\(base)（云盘上原来那份是空的，已用这次的结果覆盖）")
            : base
        let emptyNote = cloudBackupWasEmpty ? String(localized: ")；云盘原文件为 0 字节，已覆盖") : ""
        return Outcome(
            ok: true,
            message: message,
            log: String(localized: "多设备同步完成（\(String(describing: counts))\(String(describing: legacy))\(String(describing: emptyNote))"),
            summary: summary
        )
    }

    /// 云盘上某个文件的修改时间；文件不在、或服务器没给这个头，就当没有（不挡同步）。
    private static func modifiedDate(of path: String, client: WebDAVClient) async -> Date? {
        (try? await client.modifiedDate(path: path)) ?? nil
    }

    // MARK: - 合并

    // 观看记录与收藏都以「番剧 ID / 规则 + 番剧」为主键，同一条留 `updatedAt`
    // 新的那份；观看记录内部还要把每一集的进度并起来（见 `mergeHistory`）。

    /// 观看记录：按「规则 + 番剧」合，两份都有就把每集进度并起来
    /// （同一集新的赢）。不能按番剧 ID 压成一条——不同源是两份记录，
    /// 压一条就等于丢掉其中一源看过的那些集。
    private static func mergeHistory(local: [WatchRecord], remote: [WatchRecord]) -> [WatchRecord] {
        // 顺序跟合并前一致：云盘上那份在前，本机多出来的接在后面（字典序稳定）。
        LibraryStore.deduplicated(remote + local)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 迁移过来的老格式记录没存来源规则（空串），而原版快照里同一部番只有一条带规则名的。
    /// 那就把规则名认过来，合并时两边能并成一条；不认的话同一部番会在历史列表里
    /// 出现两遍（一条带规则名、一条不带），看上去像重复记录。
    ///
    /// 多条不同规则时不猜——老格式本来就没存是哪一条，硬选一条会把记录安到错的来源上。
    private static func adoptLegacyRuleNames(
        _ local: [WatchRecord],
        from legacy: [WatchRecord]
    ) -> [WatchRecord] {
        var result = local
        for index in result.indices where result[index].sourceRuleName.isEmpty {
            let bangumiID = result[index].bangumiID
            let rules = Set(
                legacy
                    .filter { $0.bangumiID == bangumiID && !$0.sourceRuleName.isEmpty }
                    .map(\.sourceRuleName)
            )
            if rules.count == 1, let rule = rules.first {
                result[index].sourceRuleName = rule
            }
        }
        return result
    }

    /// 收藏：本机的顺序留着（用户摆过的分类顺序），云盘上多出来的接在后面。
    /// 收藏：按番剧 ID 合起来，**本机为准**（LP 2026-10-28）。
    ///
    /// 原来比 `updatedAt`、谁新谁赢，会让一份老数据把本机这条顶掉。
    /// 收藏看的是「收没收这一部」，同一部两边都有时本机那套字段（分类、时间）
    /// 才是用户现在用的那份，所以留着本机的；云盘上多出来的补进来。
    /// 取消走的不是这里，是 `removedEntries`（见 sync 里的那段）。
    private static func mergeEntries(local: [LibraryEntry], remote: [LibraryEntry]) -> [LibraryEntry] {
        var merged = local
        var seen = Set(local.map(\.id))
        for entry in remote where !seen.contains(entry.id) {
            merged.append(entry)
            seen.insert(entry.id)
        }
        return merged
    }

    private static func ruleCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private static func ruleLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func technicalText(_ error: Error) -> String {
        (error as? WebDAVClient.WebDAVError)?.logDescription ?? error.localizedDescription
    }

    /// 屏上那句话：能说清原因的就直说原因，只有真的是网络层出错才让人去查网络。
    ///
    /// 以前这两个 catch 都只写「请检查网络或服务器配置」，可最常遇到的两种失败
    /// 都跟网络无关（云盘上文件是空的、格式对不上），等于把问题直接推给用户。
    static func friendlyText(_ error: Error) -> String {
        if let webdav = error as? WebDAVClient.WebDAVError {
            return webdav.errorDescription ?? String(localized: "云盘读写失败。")
        }
        if error is URLError {
            return String(localized: "连不上服务器，请检查网络或服务器地址。")
        }
        return error.localizedDescription
    }
}
