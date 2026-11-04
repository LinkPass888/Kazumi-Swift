//
//  WebDAVLegacy.swift
//  Kazumi
//
//  读原版 Flutter 版留在云盘上的那几份文件。
//
//  原生版自己的同步包是 `kazumiSync/kazumi_backup.json`，原版写的是
//  `history/snapshot.json`（JSON）、`history/changes/<设备>.jsonl`（事件流）、
//  `danmakuShield/<设备>.json`（每台设备一份）、以及 `collectibles.tmp` /
//  `histories.tmp`（Hive 箱文件，二进制）。
//
//  LP 2026-10-25：换到原生版以后，云盘上那份老数据得真能合进来。
//  所以同步前先按文件名精确匹配把能读的读起来，跟本地一起合并；
//  读不出来的（Hive 二进制那两份）就跳过，不猜、也不改它们。
//

import Foundation

@MainActor
enum WebDAVLegacy {
    /// 原版固定目录名（lib/services/sync/webdav.dart:16-20）。
    static let historyFolder = "history"
    static let historySnapshotPath = "history/snapshot.json"
    static let shieldFolder = "danmakuShield"

    // MARK: - 观看记录

    /// 原版历史快照的形状：只看合并要用的那几个字段，其余不解码。
    private struct Snapshot: Decodable {
        struct Item: Decodable {
            struct Bangumi: Decodable {
                let id: Int
                let name: String?
                let nameCn: String?
                let images: [String: String]?
            }

            /// 原版每集的进度：episode / road / progressMs / updatedAtMs
            /// （lib/modules/history/history_sync.dart 的 progressFromJson）。
            struct Progress: Decodable {
                let episode: Int?
                let road: Int?
                let progressMs: Double?
                /// 毫秒；原版允许缺（默认 0），缺的时候用这一条的 lastWatchTime 兑。
                let updatedAtMs: Double?
            }

            let bangumiItem: Bangumi
            let lastWatchEpisode: Int?
            let adapterName: String?
            /// 毫秒。
            let lastWatchTime: Double?
            let lastWatchEpisodeName: String?
            let progresses: [String: Progress]?
        }

        let histories: [Item]
    }

    /// 原版历史快照读出来的两样东西：能进本端模型的记录，和云盘上那份原始 JSON。
    ///
    /// 写回必须在那份原始 JSON 上改。凭空重造会把原版按线路分开的条目、
    /// 以及每部番每一集的进度都压成一条——2026-10-25 就出过这一次：
    /// 云盘上 613 条被写成 249 条，每部番只剩最后看的那一集。
    struct LegacyHistory: Sendable {
        var records: [WatchRecord] = []
        var raw: Data?
    }

    /// 读原版的历史快照，转成本端的 `WatchRecord`。
    ///
    /// 云盘上没有这个文件时返回空的——原版从没用过 WebDAV 的用户就是这样。
    static func history(client: WebDAVClient) async throws -> LegacyHistory {
        guard let data = try await client.rawDownload(path: historySnapshotPath) else {
            return LegacyHistory()
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let records: [WatchRecord] = snapshot.histories.compactMap { item in
            let episode = item.lastWatchEpisode ?? 0
            let updatedMs = item.lastWatchTime ?? 0
            guard item.bangumiItem.id > 0 else { return nil }
            let nameCn = item.bangumiItem.nameCn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = item.bangumiItem.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let images = item.bangumiItem.images ?? [:]
            let cover = images["large"] ?? images["common"] ?? images["medium"] ?? images["small"] ?? ""
            // 原版一份条目里存着这部番看过的每一集，全部接过来：
            // 只接最后那一集的话，同步完本机就只剩一集的进度了。
            var progresses: [String: EpisodeProgress] = [:]
            for (slot, progress) in item.progresses ?? [:] {
                let number = progress.episode ?? Int(slot) ?? 0
                guard number > 0 else { continue }
                progresses[String(number)] = EpisodeProgress(
                    episode: number,
                    road: progress.road ?? 0,
                    progressSeconds: max(progress.progressMs ?? 0, 0) / 1000,
                    updatedAt: Date(timeIntervalSince1970: max(progress.updatedAtMs ?? updatedMs, 0) / 1000)
                )
            }
            return WatchRecord(
                bangumiID: item.bangumiItem.id,
                bangumiName: nameCn.isEmpty ? name : nameCn,
                imageURL: cover,
                sourceRuleName: item.adapterName ?? "",
                episodeTitle: item.lastWatchEpisodeName ?? "",
                episodeNumber: episode,
                // 原版快照不记这一集的时长，留 0；播放器下次播到这儿会补上。
                durationSeconds: 0,
                updatedAt: Date(timeIntervalSince1970: max(updatedMs, 0) / 1000),
                progresses: progresses
            )
        }
        return LegacyHistory(records: records, raw: data)
    }

    // MARK: - 弹幕屏蔽词

    /// 一条屏蔽词在同步状态里的样子（对应 main 的 `DanmakuShieldSyncEntry`）。
    ///
    /// 删掉的规则也要留着：`deleted` + `updatedAt` 就是墓碑，
    /// 少了它，另一台设备那份旧文件会把规则重新带回来。
    struct ShieldEntry: Sendable {
        let rule: String
        let updatedAt: Int
        let deviceId: String
        let deleted: Bool
    }

    /// 合并后的屏蔽词状态（对应 main 的 `DanmakuShieldSyncState`）。
    ///
    /// `order` 记住每条规则第一次出现的顺序：写回时 main 按 rule 排序，
    /// 这里读的时候仍按文件里的顺序保留，用户看到的行序不会被这次改动打乱。
    struct ShieldState: Sendable {
        private(set) var entries: [String: ShieldEntry] = [:]
        private(set) var order: [String] = []

        /// 只返回没删的；跟 main 的 `DanmakuShieldSyncState.rules` 一样。
        var rules: [String] {
            order.compactMap { entries[$0] }.filter { !$0.deleted }.map(\.rule)
        }

        var latestTimestamp: Int {
            entries.values.reduce(0) { max($0, $1.updatedAt) }
        }

        /// main 的 `_compareTo`：先 updatedAt，再 deviceId，最后 deleted。
        /// 相等时保留先到的那条（main 的 `_mergeEntries` 也是 `> 0` 才换）。
        private static func wins(_ candidate: ShieldEntry, over current: ShieldEntry) -> Bool {
            if candidate.updatedAt != current.updatedAt {
                return candidate.updatedAt > current.updatedAt
            }
            if candidate.deviceId != current.deviceId {
                return candidate.deviceId > current.deviceId
            }
            return (candidate.deleted ? 1 : 0) > (current.deleted ? 1 : 0)
        }

        mutating func insert(_ entry: ShieldEntry) {
            if let current = entries[entry.rule] {
                if Self.wins(entry, over: current) { entries[entry.rule] = entry }
            } else {
                entries[entry.rule] = entry
                order.append(entry.rule)
            }
        }

        mutating func merge(_ other: ShieldState) {
            for rule in other.order {
                guard let entry = other.entries[rule] else { continue }
                insert(entry)
            }
        }

        /// 原版写回的格式：`{version:1, entries:[...]}`，entries 按 rule 排序。
        func encoded() throws -> Data {
            let sorted = order.compactMap { entries[$0] }.sorted { $0.rule < $1.rule }
            let json: [String: Any] = [
                "version": 1,
                "entries": sorted.map { entry in
                    [
                        "rule": entry.rule,
                        "updatedAt": entry.updatedAt,
                        "deviceId": entry.deviceId,
                        "deleted": entry.deleted
                    ] as [String: Any]
                }
            ]
            return try JSONSerialization.data(withJSONObject: json)
        }
    }

    /// 一份云盘状态的快照：所有设备并起来的结果，以及本机那一份。
    struct ShieldSnapshot: Sendable {
        var merged = ShieldState()
        /// 本机上次写上去的那份，用来判断本机这次删掉了哪条规则。
        var own = ShieldState()
    }

    /// 原版每一台设备一个文件，形状是 `{version, entries:[{rule, updatedAt, deviceId, deleted}]}`。
    ///
    /// 字段都可缺：老文件只有 `rule` / `deleted` 也要能读，缺的按「不知道」处理。
    private struct ShieldFile: Decodable {
        struct Entry: Decodable {
            let rule: String?
            let updatedAt: Int?
            let deviceId: String?
            let deleted: Bool?
        }

        let version: Int?
        let entries: [Entry]?
    }

    /// 把所有设备那份的屏蔽词并起来（包括墓碑），本机那份单独留一份。
    ///
    /// 对应 main 的 `syncDanmakuShield`：读 `danmakuShield/` 下每个
    /// `<deviceId>.json`，逐个 `DanmakuShieldSyncState.decode` 后 merge。
    static func shieldState(client: WebDAVClient, deviceID: String) async throws -> ShieldSnapshot {
        let names = try await client.listFolder(path: shieldFolder)
        var snapshot = ShieldSnapshot()
        let ownName = "\(deviceID).json"
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try await client.rawDownload(path: "\(shieldFolder)/\(name)"),
                  let file = try? JSONDecoder().decode(ShieldFile.self, from: data)
            else { continue }
            // main 只认 version 1；没有 version 的老文件仍按兼容读。
            if let version = file.version, version != 1 { continue }
            // 老文件缺 deviceId 时用文件名兜底：main 那边 deviceId 为空会
            // 直接判整份文件无效，写回去时不能留空。
            let fileDevice = String(name.dropLast(".json".count))
            let fallbackDevice = fileDevice.isEmpty ? deviceID : fileDevice
            var state = ShieldState()
            for entry in file.entries ?? [] {
                let rule = entry.rule?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rule.isEmpty else { continue }
                // 缺字段的老文件按「不知道」处理：updatedAt 0 盖不过云端的墓碑，
                // deleted 缺省当没删。
                let deviceId = entry.deviceId.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackDevice
                state.insert(ShieldEntry(
                    rule: rule,
                    updatedAt: max(entry.updatedAt ?? 0, 0),
                    deviceId: deviceId,
                    deleted: entry.deleted ?? false
                ))
            }
            snapshot.merged.merge(state)
            if name == ownName { snapshot.own = state }
        }
        return snapshot
    }

    // MARK: - 收藏

    /// 原版把收藏存在两个 Hive 箱体里（`_updateBox()` 直接把本机箱子拷上去）：
    /// `collectibles.tmp` 是全部收藏，`collectchanges.tmp` 是还没传到别的设备上的变更队列。
    static let collectiblesPath = "collectibles.tmp"
    static let collectChangesPath = "collectchanges.tmp"

    /// 从旧格式收藏里读出来的两样东西。
    struct LegacyCollect: Sendable {
        var entries: [LibraryEntry] = []
        /// 旧版那边取消过的：番剧 ID → 取消时刻（同一部取最新一条）。
        var removals: [Int: Date] = [:]
    }

    /// 读原版的收藏箱体（二进制，格式见 `HiveBox`）。
    ///
    /// 收藏这条只有它能读：本端备份里的收藏是新格式，旧版不认；
    /// 旧版这份是 Hive 箱体，本端要自己解。
    /// 云盘上没有这个文件时返回空的。
    static func collectibles(client: WebDAVClient) async throws -> LegacyCollect {
        var result = LegacyCollect()
        if let data = try await client.rawDownload(path: collectiblesPath) {
            for item in try HiveBox.read(data) {
                guard let fields = item.value.objectFields,
                      let bangumi = fields[0]?.objectFields
                else { continue }
                let id = bangumi[0]?.intValue ?? item.key
                let time = fields[1]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                let collectType = fields[2]?.intValue ?? 1
                let images = bangumi[8]
                let imageURL = ["large", "common", "medium", "small", "grid"]
                    .lazy
                    .compactMap { images?.mapValue($0)?.stringValue }
                    .first { !$0.isEmpty } ?? ""
                let tags = (bangumi[9]?.listValue ?? []).compactMap { tag -> String? in
                    guard let name = tag.objectFields?[0]?.stringValue,
                          !name.isEmpty
                    else { return nil }
                    return name
                }
                let entry = LibraryEntry(
                    id: id,
                    type: collectType,
                    name: bangumi[2]?.stringValue ?? "",
                    nameCn: bangumi[3]?.stringValue ?? "",
                    summary: bangumi[4]?.stringValue ?? "",
                    airDate: bangumi[5]?.stringValue ?? "",
                    imageURL: imageURL,
                    rating: bangumi[11]?.numberValue ?? 0,
                    rank: bangumi[7]?.intValue ?? 0,
                    tags: tags,
                    totalEpisodes: 0,
                    currentEpisode: 0,
                    addedAt: time,
                    updatedAt: time
                )
                // 箱体里偶尔有同一个 key 存了两帧（实测 id 549654 就是这样，
                // 一帧「在看」一帧「看过」）。Hive 的语义是后写的覆盖前面的，
                // 所以同一个番剧 id 只留最后一帧，顺序按第一次出现的位置。
                if let index = result.entries.firstIndex(where: { $0.id == entry.id }) {
                    result.entries[index] = entry
                } else {
                    result.entries.append(entry)
                }
            }
        }

        // 变更队列：取消收藏（action 3）要从这里来，不然旧设备上取消的会被当没发生过。
        if let data = try? await client.rawDownload(path: collectChangesPath) {
            for item in (try? HiveBox.read(data)) ?? [] {
                guard let fields = item.value.objectFields,
                      let bangumiID = fields[1]?.intValue,
                      fields[2]?.intValue == 3
                else { continue }
                // 这个队列的时间是**秒**（原版 CollectedBangumiChange.timestamp，
                // 注释就写着 timestamp in seconds，因为要拿来当 Hive 的键）。
                // 箱体里收藏时间是 DateTime（毫秒），两边单位不一样，别混。
                let stamp = fields[4]?.numberValue
                    .map { Date(timeIntervalSince1970: $0) } ?? Date()
                if let existing = result.removals[bangumiID], existing > stamp { continue }
                result.removals[bangumiID] = stamp
            }
        }
        return result
    }

    // MARK: - 写回原版格式

    /// 把本端的观看记录合并写回 `history/snapshot.json`。
    ///
    /// 必须在原版那份 JSON 上改，不能凭空重造：原版按「线路 + 番剧」存条目，
    /// 每部番的 `progresses` 里存着看过的每一集。重造会把它压成一条、
    /// 只剩最后看的那一集（2026-10-25 出过：613 条被写成 249 条）。
    /// 所以：同一条目有就更新，没有才追加；原版存着的别的集一律保留。
    static func writeHistory(
        _ records: [WatchRecord],
        existing: Data?,
        client: WebDAVClient,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws {
        var root: [String: Any] = [:]
        if let existing, let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = parsed
        }
        var histories = root["histories"] as? [[String: Any]] ?? []
        var itemVersions = root["itemVersions"] as? [String: Any] ?? [:]
        var progressVersions = root["progressVersions"] as? [String: Any] ?? [:]

        var index: [String: Int] = [:]
        for (position, item) in histories.enumerated() {
            guard let key = entryKey(item) else { continue }
            index[key] = position
        }

        for (offset, record) in records.enumerated() where record.bangumiID > 0 {
            progress?(offset, records.count)
            let key = Self.entryKey(for: record, in: histories, index: index)
            let updatedMs = Int(record.updatedAt.timeIntervalSince1970 * 1000)
            let episode = record.episodeNumber
            // 局部变量不能叫 `version`：它会盖住下面用的那个静态方法 `version(_:)`。
            let itemVersion = version(updatedMs)
            // 这一份记录里看过的每一集都要写回去（main 的快照就是按集存的）：
            // 只写最后那一集，会把原版存着的别的集的进度在本机这边「看不出看过」。
            // 线路号取那一集自己的，不再写死 0。
            var perEpisode = record.progresses
            let lastSlot = String(episode)
            if perEpisode[lastSlot] == nil, episode > 0 {
                // 兜底：这份记录一份 progresses 都没有（老格式 0 进度那种），
                // 最后看的那一集照老格式的字段写回去，别让云盘上少一条。
                perEpisode[lastSlot] = EpisodeProgress(
                    episode: episode,
                    road: record.roadIndex,
                    progressSeconds: record.progressSeconds,
                    updatedAt: record.updatedAt
                )
            }
            let progresses: [String: [String: Any]] = perEpisode.reduce(into: [:]) { result, pair in
                let entry = pair.value
                result[pair.key] = [
                    "episode": entry.episode,
                    "road": entry.road,
                    "progressMs": Int(entry.progressSeconds * 1000),
                    "updatedAtMs": Int(entry.updatedAt.timeIntervalSince1970 * 1000)
                ]
            }

            if let position = index[key] {
                var item = histories[position]
                var cloudProgresses = item["progresses"] as? [String: Any] ?? [:]
                var versions = progressVersions[key] as? [String: Any] ?? [:]
                for (slot, progress) in progresses {
                    // 同一集：云盘上那份更新就不动（只保留更新的那边）。
                    let previous = ms((cloudProgresses[slot] as? [String: Any])?["updatedAtMs"])
                    let incoming = ms(progress["updatedAtMs"])
                    guard previous <= incoming else { continue }
                    cloudProgresses[slot] = progress
                    versions[slot] = version(Int(incoming))
                }
                if !progresses.isEmpty {
                    item["progresses"] = cloudProgresses
                    progressVersions[key] = versions
                }
                if ms(item["lastWatchTime"]) <= Double(updatedMs) {
                    item["lastWatchEpisode"] = episode
                    item["lastWatchTime"] = updatedMs
                    item["lastWatchEpisodeName"] = record.episodeTitle
                    item["bangumiItem"] = fillItem(item["bangumiItem"] as? [String: Any] ?? [:], from: record)
                    itemVersions[key] = itemVersion
                }
                histories[position] = item
            } else {
                histories.append([
                    "bangumiItem": freshItem(record),
                    "lastWatchEpisode": episode,
                    "adapterName": record.sourceRuleName,
                    "lastWatchTime": updatedMs,
                    "lastSrc": "",
                    "lastWatchEpisodeName": record.episodeTitle,
                    "entryKind": "online",
                    "episodePageUrl": "",
                    "progresses": progresses
                ] as [String: Any])
                index[key] = histories.count - 1
                itemVersions[key] = itemVersion
                progressVersions[key] = progresses.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = version(Int(ms(pair.value["updatedAtMs"])))
                }
            }
        }

        root["histories"] = histories
        root["itemVersions"] = itemVersions
        root["progressVersions"] = progressVersions
        root["generatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
        if root["schemaVersion"] == nil { root["schemaVersion"] = 1 }
        if root["deletedVersions"] == nil { root["deletedVersions"] = [String: Any]() }
        let data = try JSONSerialization.data(withJSONObject: root)
        try await client.uploadRaw(path: historySnapshotPath, data: data)
    }

    /// 原版的条目键：线路 + 番剧 ID + online。
    private static func entryKey(_ item: [String: Any]) -> String? {
        guard let bangumi = item["bangumiItem"] as? [String: Any] else { return nil }
        let id = Int(ms(bangumi["id"]))
        guard id > 0 else { return nil }
        let rule = item["adapterName"] as? String ?? ""
        let kind = item["entryKind"] as? String ?? "online"
        return "\(rule)\(id)::\(kind)"
    }

    /// 写回时这条本机记录该落到云盘哪一条目上。
    ///
    /// 正常就是「规则 + 番剧」的键。但迁移过来的老格式记录没存来源规则
    /// （`sourceRuleName` 是空串），这时若直接追加，云盘上同一部番会多出
    /// 一条空规则的重复条目（原版列表里就看得到两部一样的番）。
    /// 所以规则名为空、且云盘上确实有这部番时，按番剧 ID 找一条认下来：
    /// 多条时取最近看的那条（跟 `record(for:)` 跨规则取最新的语义一致）。
    private static func entryKey(
        for record: WatchRecord,
        in histories: [[String: Any]],
        index: [String: Int]
    ) -> String {
        if !record.sourceRuleName.isEmpty || index[record.id] != nil {
            return record.id
        }
        let matches = histories.filter { item in
            guard let bangumi = item["bangumiItem"] as? [String: Any] else { return false }
            return Int(ms(bangumi["id"])) == record.bangumiID
        }
        let newest = matches.max { ms($0["lastWatchTime"]) < ms($1["lastWatchTime"]) }
        if let newest, let key = entryKey(newest) { return key }
        return record.id
    }

    /// 只在缺名字、缺封面时补，不改原版已经存下的番剧资料。
    private static func fillItem(_ item: [String: Any], from record: WatchRecord) -> [String: Any] {
        var item = item
        if (item["nameCn"] as? String ?? "").isEmpty { item["nameCn"] = record.bangumiName }
        if (item["name"] as? String ?? "").isEmpty { item["name"] = record.bangumiName }
        var images = item["images"] as? [String: Any] ?? [:]
        if images["large"] == nil, !record.imageURL.isEmpty {
            for size in ["small", "grid", "large", "medium", "common"] { images[size] = record.imageURL }
            item["images"] = images
        }
        return item
    }

    /// 云盘上还没有这部番时，按原版 `bangumiItem` 的字段造一份。
    private static func freshItem(_ record: WatchRecord) -> [String: Any] {
        var images = [String: Any]()
        if !record.imageURL.isEmpty {
            for size in ["small", "grid", "large", "medium", "common"] { images[size] = record.imageURL }
        }
        return [
            "id": record.bangumiID,
            "type": 2,
            "name": record.bangumiName,
            "nameCn": record.bangumiName,
            "summary": "",
            "airDate": "",
            "airWeekday": 7,
            "rank": 0,
            "images": images,
            "tags": [Any](),
            "alias": [Any](),
            "ratingScore": 0,
            "votes": 0,
            "votesCount": [Any](),
            "info": ""
        ]
    }

    /// JSON 里的数字可能是 Int 也可能是 Double，统一按毫秒取。
    private static func ms(_ value: Any?) -> Double {
        guard let value else { return 0 }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let number = Double(text) { return number }
        return 0
    }

    /// 把合并后的整份屏蔽词状态写成「本机设备」那一份，原版会把各设备的文件并起来。
    ///
    /// 必须把墓碑一起写上去（`deleted: true` + `updatedAt`），否则本机删掉的规则
    /// 会被另一台设备的旧文件重新带回来。
    static func writeShield(_ state: ShieldState, deviceID: String, client: WebDAVClient) async throws {
        let data = try state.encoded()
        try await client.uploadRaw(path: "\(shieldFolder)/\(deviceID).json", data: data)
    }

    /// 原版 `HistorySyncVersion.of`：16 位补零的毫秒，竖线，事件 ID。
    private static func version(_ ms: Int) -> String {
        let digits = String(max(ms, 0))
        let pad = String(repeating: "0", count: max(0, 16 - digits.count))
        return "\(pad)\(digits)|kazumi-native:\(UUID().uuidString)"
    }
}
