//
//  KazumiSyncHistory.swift
//  Kazumi
//
//  与原版 Flutter 版「观看历史」同步格式对齐的读写层。
//
//  原版布局（lib/services/sync/webdav.dart，实测样本见 hive-format-findings.md）：
//    kazumiSync/history/snapshot.json          全量快照，schemaVersion 1
//    kazumiSync/history/changes/<deviceId>.jsonl 每设备一份追加式事件日志
//
//  快照结构（实测 609 条）：
//    { schemaVersion, generatedAt, histories[], itemVersions{}, progressVersions{}, deletedVersions{} }
//  histories 每条：
//    { bangumiItem, lastWatchEpisode, adapterName, lastWatchTime, lastSrc,
//      lastWatchEpisodeName, entryKind, episodePageUrl, progresses{} }
//  progresses 每个键是集数，值 { episode, road, progressMs, updatedAtMs }。
//
//  事件行（实测 116 行/文件）：
//    { eventId, deviceId, seq, op, updatedAt, entityKey, bangumiItem,
//      adapterName, episode, road, progressMs, entryKind, episodePageUrl }
//    op 实测两种：upsertWatchState / upsertProgress。
//
//  版本号（itemVersions / progressVersions）是字符串
//    "<17 位零填充时间>|local-state:<entityKey>[:<episode>:<road>]"
//  合并时按这个字符串比大小即可（零填充保证字典序 = 时间序）。
//

import Foundation

// MARK: - 快照

struct KazumiHistorySnapshot: Codable, Sendable {
    var schemaVersion: Int
    var generatedAt: Int64
    var histories: [KazumiHistoryEntry]
    var itemVersions: [String: String]
    var progressVersions: [String: [String: String]]
    var deletedVersions: [String: String]

    init(
        schemaVersion: Int = 1,
        generatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        histories: [KazumiHistoryEntry] = [],
        itemVersions: [String: String] = [:],
        progressVersions: [String: [String: String]] = [:],
        deletedVersions: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.histories = histories
        self.itemVersions = itemVersions
        self.progressVersions = progressVersions
        self.deletedVersions = deletedVersions
    }

    /// 缺字段时当空，避免对方版本多了字段就整份读不进来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decodeIfPresent(Int64.self, forKey: .generatedAt) ?? 0
        histories = try c.decodeIfPresent([KazumiHistoryEntry].self, forKey: .histories) ?? []
        itemVersions = try c.decodeIfPresent([String: String].self, forKey: .itemVersions) ?? [:]
        progressVersions = try c.decodeIfPresent([String: [String: String]].self, forKey: .progressVersions) ?? [:]
        deletedVersions = try c.decodeIfPresent([String: String].self, forKey: .deletedVersions) ?? [:]
    }
}

struct KazumiHistoryEntry: Codable, Sendable {
    var bangumiItem: KazumiBangumiItem
    var lastWatchEpisode: Int
    var adapterName: String
    var lastWatchTime: Int64
    var lastSrc: String
    var lastWatchEpisodeName: String
    var entryKind: String
    var episodePageUrl: String
    var progresses: [String: KazumiProgress]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bangumiItem = try c.decode(KazumiBangumiItem.self, forKey: .bangumiItem)
        lastWatchEpisode = try c.decodeIfPresent(Int.self, forKey: .lastWatchEpisode) ?? 0
        adapterName = try c.decodeIfPresent(String.self, forKey: .adapterName) ?? ""
        lastWatchTime = try c.decodeIfPresent(Int64.self, forKey: .lastWatchTime) ?? 0
        lastSrc = try c.decodeIfPresent(String.self, forKey: .lastSrc) ?? ""
        lastWatchEpisodeName = try c.decodeIfPresent(String.self, forKey: .lastWatchEpisodeName) ?? ""
        entryKind = try c.decodeIfPresent(String.self, forKey: .entryKind) ?? "online"
        episodePageUrl = try c.decodeIfPresent(String.self, forKey: .episodePageUrl) ?? ""
        progresses = try c.decodeIfPresent([String: KazumiProgress].self, forKey: .progresses) ?? [:]
    }

    /// 原版的实体键：<adapterName><bangumiId>::<entryKind>。
    var entityKey: String {
        "\(adapterName)\(bangumiItem.id)::\(entryKind)"
    }
}

struct KazumiProgress: Codable, Sendable {
    var episode: Int
    var road: Int
    var progressMs: Int64
    var updatedAtMs: Int64
}

struct KazumiBangumiItem: Codable, Sendable {
    var id: Int
    var type: Int
    var name: String
    var nameCn: String
    var summary: String
    var airDate: String
    var airWeekday: Int
    var rank: Int
    var images: [String: String]
    var tags: [KazumiTag]
    var alias: [String]
    var ratingScore: Double
    var votes: Int
    var votesCount: Int
    var info: [String: String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 2
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nameCn = try c.decodeIfPresent(String.self, forKey: .nameCn) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        airDate = try c.decodeIfPresent(String.self, forKey: .airDate) ?? ""
        airWeekday = try c.decodeIfPresent(Int.self, forKey: .airWeekday) ?? 0
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
        images = try c.decodeIfPresent([String: String].self, forKey: .images) ?? [:]
        tags = try c.decodeIfPresent([KazumiTag].self, forKey: .tags) ?? []
        alias = try c.decodeIfPresent([String].self, forKey: .alias) ?? []
        ratingScore = try c.decodeIfPresent(Double.self, forKey: .ratingScore) ?? 0
        votes = try c.decodeIfPresent(Int.self, forKey: .votes) ?? 0
        votesCount = try c.decodeIfPresent(Int.self, forKey: .votesCount) ?? 0
        info = try c.decodeIfPresent([String: String].self, forKey: .info) ?? [:]
    }
}

struct KazumiTag: Codable, Sendable {
    var name: String
    var count: Int
}

// MARK: - 事件日志

/// 一行事件。字段的可选性照抄原版 `HistorySyncEvent`（lib/modules/history/history_sync.dart:164-210），
/// 因为原版读的时候对**必有字段**用的是硬转换（`as String` / `as num`），
/// 少一个就整份文件解析失败；对可选字段则是 `as X?`，缺了没事。
///
/// 尤其注意 `carriesWatchState`：原版没显式写的时候，用
/// 「JSON 里有没有 lastSrc / lastWatchEpisodeName」来推断这条事件带不带看状态。
/// 所以我们写观看状态事件时必须带上这两个键，否则原版会把事件当成「只带进度」。
struct KazumiHistoryEvent: Codable, Sendable {
    var eventId: String
    var deviceId: String
    var seq: Int
    var op: String
    var updatedAt: Int64
    var entityKey: String?
    var bangumiItem: KazumiBangumiItem?
    var adapterName: String?
    var episode: Int?
    var road: Int?
    var progressMs: Int64?
    var lastSrc: String?
    var lastWatchEpisodeName: String?
    var entryKind: String?
    var episodePageUrl: String?
    var carriesWatchState: Bool?

    static let opWatchState = "upsertWatchState"
    static let opProgress = "upsertProgress"

    /// 原版判断「这条带不带看状态」的规则：显式字段优先，否则看有没有那两个键。
    var effectiveCarriesWatchState: Bool {
        carriesWatchState ?? (lastSrc != nil || lastWatchEpisodeName != nil)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventId, forKey: .eventId)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(seq, forKey: .seq)
        try c.encode(op, forKey: .op)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(entityKey, forKey: .entityKey)
        try c.encodeIfPresent(bangumiItem, forKey: .bangumiItem)
        try c.encodeIfPresent(adapterName, forKey: .adapterName)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(road, forKey: .road)
        try c.encodeIfPresent(progressMs, forKey: .progressMs)
        try c.encodeIfPresent(lastSrc, forKey: .lastSrc)
        try c.encodeIfPresent(lastWatchEpisodeName, forKey: .lastWatchEpisodeName)
        try c.encodeIfPresent(entryKind, forKey: .entryKind)
        try c.encodeIfPresent(episodePageUrl, forKey: .episodePageUrl)
        if effectiveCarriesWatchState {
            try c.encode(true, forKey: .carriesWatchState)
        }
    }
}

// MARK: - 合并

enum KazumiHistoryMerge {
    /// 版本号字符串：17 位零填充毫秒 + 来源标记。
    /// 零填充是关键 —— 原版按字符串比大小，不填充会得出「9 > 10」。
    static func version(_ updatedAtMs: Int64, key: String, episode: Int? = nil, road: Int? = nil) -> String {
        let stamp = String(format: "%017lld", updatedAtMs)
        if let episode {
            return "\(stamp)|local-state:\(key):\(episode):\(road ?? 0)"
        }
        return "\(stamp)|local-state:\(key):watch-state"
    }

    /// 把一批事件合进快照。
    ///
    /// 语义照原版：同一实体取 updatedAt 更大的那条；每条事件的版本号进
    /// itemVersions（看状态）或 progressVersions（单集进度），已存在且更新的跳过。
    static func apply(events: [KazumiHistoryEvent], to snapshot: inout KazumiHistorySnapshot) {
        var byKey = Dictionary(uniqueKeysWithValues: snapshot.histories.map { ($0.entityKey, $0) })
        var pendingProgress: [KazumiHistoryEvent] = []

        for event in events {
            // 原版对没有 entityKey 的事件（clearAll 之类）不参与合并。
            guard let key = event.entityKey else { continue }
            let isProgress = event.op == KazumiHistoryEvent.opProgress
            let version = version(
                event.updatedAt,
                key: key,
                episode: isProgress ? event.episode : nil,
                road: isProgress ? event.road : nil
            )

            if isProgress {
                guard let episode = event.episode else { continue }
                let existing = snapshot.progressVersions[key]?[String(episode)]
                if let existing, existing >= version { continue }

                guard var entry = byKey[key] else {
                    pendingProgress.append(event)
                    continue
                }
                let episodeKey = String(episode)
                if let current = entry.progresses[episodeKey], current.updatedAtMs > event.updatedAt { continue }
                entry.progresses[episodeKey] = KazumiProgress(
                    episode: episode,
                    road: event.road ?? 0,
                    progressMs: event.progressMs ?? 0,
                    updatedAtMs: event.updatedAt
                )
                byKey[key] = entry
                snapshot.progressVersions[key, default: [:]][episodeKey] = version
            } else {
                let existing = snapshot.itemVersions[key]
                if let existing, existing >= version { continue }
                snapshot.itemVersions[key] = version

                // 新建条目必须有 bangumiItem，否则写进快照也没法用。
                guard var entry = byKey[key] ?? event.bangumiItem.map({ item in
                    KazumiHistoryEntry(
                        bangumiItem: item,
                        lastWatchEpisode: 0,
                        adapterName: event.adapterName ?? "",
                        lastWatchTime: 0,
                        lastSrc: "",
                        lastWatchEpisodeName: "",
                        entryKind: event.entryKind ?? "online",
                        episodePageUrl: "",
                        progresses: [:]
                    )
                }) else { continue }

                if event.updatedAt >= entry.lastWatchTime {
                    entry.lastWatchEpisode = event.episode ?? entry.lastWatchEpisode
                    entry.lastWatchTime = event.updatedAt
                    entry.episodePageUrl = event.episodePageUrl ?? entry.episodePageUrl
                    if let src = event.lastSrc { entry.lastSrc = src }
                    if let name = event.lastWatchEpisodeName { entry.lastWatchEpisodeName = name }
                    if let item = event.bangumiItem { entry.bangumiItem = item }
                }
                for pending in pendingProgress where pending.entityKey == key {
                    guard let episode = pending.episode else { continue }
                    let episodeKey = String(episode)
                    let pendingVersion = Self.version(
                        pending.updatedAt,
                        key: key,
                        episode: episode,
                        road: pending.road
                    )
                    let existing = snapshot.progressVersions[key]?[episodeKey]
                    if let existing, existing >= pendingVersion { continue }
                    if let current = entry.progresses[episodeKey], current.updatedAtMs > pending.updatedAt { continue }
                    entry.progresses[episodeKey] = KazumiProgress(
                        episode: episode,
                        road: pending.road ?? 0,
                        progressMs: pending.progressMs ?? 0,
                        updatedAtMs: pending.updatedAt
                    )
                    snapshot.progressVersions[key, default: [:]][episodeKey] = pendingVersion
                }
                pendingProgress.removeAll { $0.entityKey == key }
                byKey[key] = entry
            }
        }

        snapshot.histories = Array(byKey.values).sorted { $0.lastWatchTime > $1.lastWatchTime }
    }

    /// 解析 jsonl：一行一个事件，坏行跳过而不是整份失败
    /// （原版对远端坏行是整份拒绝，对本地是自己写的才容忍 —— 这里取宽的那侧，
    ///  因为跳过一行最多少一条进度，整份失败会让同步完全停住）。
    static func decodeEvents(_ text: String) -> [KazumiHistoryEvent] {
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(KazumiHistoryEvent.self, from: data)
        }
    }
}

extension KazumiHistoryEntry {
    init(
        bangumiItem: KazumiBangumiItem,
        lastWatchEpisode: Int,
        adapterName: String,
        lastWatchTime: Int64,
        lastSrc: String,
        lastWatchEpisodeName: String,
        entryKind: String,
        episodePageUrl: String,
        progresses: [String: KazumiProgress]
    ) {
        self.bangumiItem = bangumiItem
        self.lastWatchEpisode = lastWatchEpisode
        self.adapterName = adapterName
        self.lastWatchTime = lastWatchTime
        self.lastSrc = lastSrc
        self.lastWatchEpisodeName = lastWatchEpisodeName
        self.entryKind = entryKind
        self.episodePageUrl = episodePageUrl
        self.progresses = progresses
    }
}
