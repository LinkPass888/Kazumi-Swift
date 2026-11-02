//
//  BangumiSubjectCache.swift
//  Kazumi
//
//  番剧详情的本地缓存：条目本身和剧集列表都落盘，进详情页时先拿它铺页面，
//  再在后台刷新。
//
//  为什么要有它：详情页原来每次进去都先请求一遍条目、再请求剧集，期间整页
//  只有一个转圈。条目在列表里其实已经拿到过一份（时间表、推荐、追番都有），
//  只是没留下来。现在列表渲染过的条目直接记进内存，详情页立刻能画；
//  拉过一次的完整条目和剧集落到 Application Support/Kazumi/subjects/，
//  下次冷启动也还是先有内容再刷新。
//
//  缓存的是接口原始 JSON：BangumiItem / BangumiEpisode 没有 Codable 实现，
//  存原始 JSON 再走同一套 fromJSON 解析，和网络那条路径逐字段一致，
//  不会出现「缓存读出来的字段和接口给的不一样」。
//

import Foundation

@MainActor
final class BangumiSubjectCache {
    static let shared = BangumiSubjectCache()

    /// 条目本身多久算新鲜（与剧集分开算：条目变的是简介、评分、票数）。
    private static let infoMaxAge: TimeInterval = 24 * 60 * 60
    /// 剧集列表多久算新鲜。
    private static let episodesMaxAge: TimeInterval = 24 * 60 * 60

    /// 内存里的条目：列表渲染过的、详情页拉过的都在这里。
    private var items: [Int: BangumiItem] = [:]
    private var episodes: [Int: [BangumiEpisode]] = [:]
    /// 每份数据是什么时候拿到的（epoch 秒）。
    private var infoSavedAt: [Int: TimeInterval] = [:]
    private var episodesSavedAt: [Int: TimeInterval] = [:]

    private let directory: URL
    private let decoder = JSONDecoder()

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = support
            .appendingPathComponent("Kazumi", isDirectory: true)
            .appendingPathComponent("subjects", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 读

    /// 只查内存、不碰磁盘。给「手指落下就得立刻出东西」的路径用：
    /// 轮播那颗「开始观看」启动后第一次点，读盘是几秒白屏的一份账（LP 2026-10-28）。
    func memoryItem(for bangumiID: Int) -> BangumiItem? { items[bangumiID] }

    /// 同上，剧集。
    func memoryEpisodes(for bangumiID: Int) -> [BangumiEpisode]? { episodes[bangumiID] }

    /// 条目：内存里有就直接用，没有就读盘。不判断新鲜度——调用方拿它先画页面，
    /// 是否要刷新由 [needsInfoRefresh] 决定。
    func item(for bangumiID: Int) -> BangumiItem? {
        if let item = items[bangumiID] { return item }
        guard let payload = loadPayload(bangumiID),
              let info = payload.info,
              // 只留一天：更早的当没有，重新拉。
              let savedAt = payload.infoSavedAt,
              Date().timeIntervalSince1970 - savedAt < Self.infoMaxAge
        else { return nil }
        let item = BangumiItem.fromJSON(JSONValue(any: info.value))
        // 没标题的旧缓存当没有（LP 2997）：以前会把半截响应存进去，
        // 之后详情页就一直拿它铺页面，停在「未知」那张空页上。
        guard !item.displayName.isEmpty else { return nil }
        items[bangumiID] = item
        infoSavedAt[bangumiID] = payload.infoSavedAt
        return item
    }

    /// 剧集列表，同上。
    func episodes(for bangumiID: Int) -> [BangumiEpisode]? {
        if let episodes = episodes[bangumiID] { return episodes }
        guard let payload = loadPayload(bangumiID),
              let raw = payload.episodes,
              let savedAt = payload.episodesSavedAt,
              Date().timeIntervalSince1970 - savedAt < Self.episodesMaxAge
        else { return nil }
        let parsed = raw.map { BangumiEpisode.fromJSON(JSONValue(any: $0.value)) }
        // 一集首播日期都没有的缓存当没有（LP 3013）：早期版本存过没有 airdate 的
        // 剧集，结果「更新进度」永远算成 0 集、整行不显示，缓存还挡着不再去拉。
        // 只认「一条日期都没有」这种情况，正常的未播出番（日期为空）不受影响。
        guard parsed.contains(where: { !$0.airdate.isEmpty }) else { return nil }
        episodes[bangumiID] = parsed
        episodesSavedAt[bangumiID] = payload.episodesSavedAt
        return parsed
    }

    /// 条目是否需要重新拉：没缓存、或过了保质期。
    func needsInfoRefresh(_ bangumiID: Int) -> Bool {
        guard let savedAt = infoSavedAt[bangumiID] ?? loadPayload(bangumiID)?.infoSavedAt else {
            return true
        }
        return Date().timeIntervalSince1970 - savedAt > Self.infoMaxAge
    }

    /// 剧集是否需要重新拉。
    func needsEpisodesRefresh(_ bangumiID: Int) -> Bool {
        guard let savedAt = episodesSavedAt[bangumiID] ?? loadPayload(bangumiID)?.episodesSavedAt else {
            return true
        }
        return Date().timeIntervalSince1970 - savedAt > Self.episodesMaxAge
    }

    // MARK: - 写

    /// 只记进内存：列表里渲染到的条目，够详情页立刻画出标题、封面、评分。
    /// 不落盘——列表里几十上百条，没必要全存，进过详情页的才值得留。
    func remember(_ item: BangumiItem) {
        if items[item.id] == nil { items[item.id] = item }
    }

    func remember(_ list: [BangumiItem]) {
        for item in list { remember(item) }
    }

    /// 接口返回的完整条目，落盘。
    func store(info json: JSONValue, for bangumiID: Int) {
        // 半截响应不落盘：存了会顶掉原来那份好的，还会被当成「有数据」不再刷新。
        let item = BangumiItem.fromJSON(json)
        guard !item.displayName.isEmpty else { return }
        var payload = loadPayload(bangumiID) ?? Payload()
        payload.info = AnyCodableJSON(json.foundationObject)
        payload.infoSavedAt = Date().timeIntervalSince1970
        save(payload, for: bangumiID)
        items[bangumiID] = item
        infoSavedAt[bangumiID] = payload.infoSavedAt
    }

    /// 接口返回的剧集列表，落盘。
    func store(episodes list: [JSONValue], for bangumiID: Int) {
        var payload = loadPayload(bangumiID) ?? Payload()
        payload.episodes = list.map { AnyCodableJSON($0.foundationObject) }
        payload.episodesSavedAt = Date().timeIntervalSince1970
        save(payload, for: bangumiID)
        episodes[bangumiID] = list.map { BangumiEpisode.fromJSON($0) }
        episodesSavedAt[bangumiID] = payload.episodesSavedAt
    }

    // MARK: - 磁盘

    private struct Payload: Codable {
        var info: AnyCodableJSON?
        var infoSavedAt: TimeInterval?
        var episodes: [AnyCodableJSON]?
        var episodesSavedAt: TimeInterval?
    }

    private func fileURL(_ bangumiID: Int) -> URL {
        directory.appendingPathComponent("\(bangumiID).json")
    }

    private func loadPayload(_ bangumiID: Int) -> Payload? {
        guard let data = try? Data(contentsOf: fileURL(bangumiID)) else { return nil }
        return try? decoder.decode(Payload.self, from: data)
    }

    private func save(_ payload: Payload, for bangumiID: Int) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL(bangumiID), options: .atomic)
    }
}

/// 把接口原始 JSON 原样存进 Codable 容器里（不解成具体模型）。
struct AnyCodableJSON: Codable {
    var value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodableJSON].self) {
            value = array.map(\.value)
        } else if let object = try? container.decode([String: AnyCodableJSON].self) {
            value = object.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法识别的 JSON 值"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodableJSON.init))
        case let object as [String: Any]:
            try container.encode(object.mapValues(AnyCodableJSON.init))
        default:
            try container.encodeNil()
        }
    }
}
