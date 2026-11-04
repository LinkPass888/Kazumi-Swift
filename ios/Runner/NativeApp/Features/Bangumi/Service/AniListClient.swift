//
//  AniListClient.swift
//  Kazumi
//
//  AniList 的当季番播出状态，对应原版 lib/services/anilist_client.dart。
//
//  AniList 的 airingAt 是「下一集的实测播出时刻」，比按 bangumi-mal 的
//  周期推算更准（停播、延期都反映在里面），所以时间表卡片和追番页的
//  「更新时间」优先用它。
//
//  请求量是这里最关键的一条：AniList 对单次请求有上限，逐部查会很快被限流。
//  因此按原版的结构做四件事：
//
//   1. 批量：一次 GraphQL 请求用别名合并最多 25 部番（batchSize）；
//   2. 按条目过期：查到的那一集播出之前都算新鲜，过了下一集播出时刻才重查，
//      完播的番查过一次就不再请求；
//   3. 失败不放弃：查不到的 id 记进 pending，下次 ensureLoaded 再试；
//   4. 磁盘缓存：整份写回 Application Support/Kazumi/update_times/anilist.json，
//      冷启动先读它，没到点的条目直接跳过请求。
//
//  429 时读 Retry-After / X-RateLimit-Reset 再等，不连续重发。
//

import Foundation

/// 一部番在 AniList 上的播出状态。
struct AniListAiring: Codable, Sendable {
    /// 下一次播出的时刻（epoch 毫秒）。
    var airingAt: Int
    /// 下一次播出的是第几话。
    var episode: Int?
    /// 已播完的番（AniList 不再给 nextAiringEpisode）。
    var finished: Bool
    /// 这份数据是什么时候查到的（epoch 毫秒）。
    var fetchedAt: Int

    /// 到下一集播出之前都算新鲜：集数和时刻都不会变。
    /// 完播的番没有下一集，永远不算新鲜。
    func isFresh(at now: Date) -> Bool {
        !finished && now.millisecondsSinceEpoch < airingAt
    }

    /// 已播出到第几集：下一集之前的那一集。
    var currentEpisode: Int? {
        guard let episode else { return nil }
        return max(1, episode - 1)
    }

    /// 超出保质期：最后一次播出之后又过了 maxAge（完播、停播、下架）。
    func isExpired(at now: Date, maxAge: TimeInterval) -> Bool {
        now.millisecondsSinceEpoch > airingAt + Int(maxAge * 1000)
    }
}

extension Date {
    var millisecondsSinceEpoch: Int { Int(timeIntervalSince1970 * 1000) }
}

/// AniList 查询客户端。只在主线程用（时间表、追番页、通知排定都在主线程）。
@MainActor
final class AniListClient {
    static let shared = AniListClient()

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    /// 条目过期时间：最后一次播出之后再过这么久就清掉。
    private static let maxAge: TimeInterval = 8 * 24 * 60 * 60
    /// 单次 HTTP 请求里合并的番数。AniList 对请求体大小有上限，
    /// 25 个别名远低于上限，同时把请求数压到 1/25。
    private static let batchSize = 25

    private var memory: [Int: AniListAiring] = [:]
    /// 查询失败、等待下次重试的 bangumi id。
    private var pendingIDs: Set<Int> = []
    private var queuedIDs: Set<Int> = []
    private var loading: Task<Void, Never>?
    private var diskLoaded = false
    private let sessionProvider: ProxyAwareURLSession
    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private var session: URLSession { sessionProvider.session }
    private let cacheURL: URL

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        sessionProvider = ProxyAwareURLSession {
            KazumiNetworkPolicy.applyProxy(to: configuration)
            return configuration
        }

        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support
            .appendingPathComponent("Kazumi", isDirectory: true)
            .appendingPathComponent("update_times", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("anilist.json")
    }

    // MARK: - 读缓存

    /// 新鲜的数据：到下一集播出之前都不会变。
    func cached(_ bangumiID: Int, now: Date = Date()) -> AniListAiring? {
        guard let airing = memory[bangumiID] else { return nil }
        guard !airing.isExpired(at: now, maxAge: Self.maxAge) else { return nil }
        return airing.isFresh(at: now) ? airing : nil
    }

    /// 不管新不新鲜都读（过期的值仍是上一集的实测结果，比周期推算准）。
    func staleCached(_ bangumiID: Int, now: Date = Date()) -> AniListAiring? {
        guard let airing = memory[bangumiID] else { return nil }
        guard !airing.isExpired(at: now, maxAge: Self.maxAge) else { return nil }
        return airing
    }

    // MARK: - 加载

    /// 批量补齐这些番的播出状态。
    ///
    /// 只有「需要重查」的番会进请求：没缓存过的、已到下一集播出时刻的、
    /// 上次查询失败的。所以每次请求量取决于这一轮有多少部真的更新了，
    /// 而不是当季一共有多少部。
    func ensureLoaded(_ bangumiIDs: [Int], malIDs: [Int: Int]) async {
        loadDiskCacheIfNeeded()
        let now = Date()
        var missing = bangumiIDs.filter { needsRefresh($0, now: now) }
        missing.append(contentsOf: pendingIDs)
        let unique = Array(Set(missing)).filter { malIDs[$0] != nil }
        guard !unique.isEmpty else { return }

        if let running = loading {
            queuedIDs.formUnion(unique)
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain(unique, malIDs: malIDs)
        }
        loading = task
        await task.value
        loading = nil
    }

    /// 这一条是否需要重查：没缓存、过了下一次播出时刻、或上次失败。
    /// 完播的番查过一次就不再请求。
    private func needsRefresh(_ bangumiID: Int, now: Date) -> Bool {
        if pendingIDs.contains(bangumiID) { return true }
        guard let airing = memory[bangumiID] else { return true }
        if airing.isExpired(at: now, maxAge: Self.maxAge) { return false }
        return !airing.finished && !airing.isFresh(at: now)
    }

    /// 处理完当前批次后，如果中途又追加了新的番，继续处理。
    private func drain(_ firstBatch: [Int], malIDs: [Int: Int]) async {
        var batch = firstBatch
        while !batch.isEmpty {
            await loadAll(batch, malIDs: malIDs)
            let now = Date()
            batch = queuedIDs.filter { needsRefresh($0, now: now) && malIDs[$0] != nil }
            queuedIDs.removeAll()
        }
        saveDiskCache()
    }

    /// 把一批番按 batchSize 切成多次请求。
    private func loadAll(_ ids: [Int], malIDs: [Int: Int]) async {
        var index = 0
        while index < ids.count {
            let end = min(index + Self.batchSize, ids.count)
            let slice = Array(ids[index..<end])
            index = end
            let result = await fetchBatch(slice, malIDs: malIDs)
            let now = Date().millisecondsSinceEpoch
            for (bangumiID, payload) in result {
                memory[bangumiID] = AniListAiring(
                    airingAt: payload.airingAt,
                    episode: payload.episode,
                    finished: payload.finished,
                    fetchedAt: now
                )
                pendingIDs.remove(bangumiID)
            }
            // 这一批里没查到的，记下来下次再试。
            for id in slice where result[id] == nil {
                pendingIDs.insert(id)
            }
            if end < ids.count {
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    private struct Payload {
        var airingAt: Int
        var episode: Int?
        var finished: Bool
    }

    /// 一次 HTTP 查询多部番：GraphQL 别名把每个 MAL id 编成一个字段。
    private func fetchBatch(_ bangumiIDs: [Int], malIDs: [Int: Int]) async -> [Int: Payload] {
        var aliasToBangumi: [String: Int] = [:]
        var variables: [String: Int] = [:]
        var index = 0
        for bangumiID in bangumiIDs {
            guard let malID = malIDs[bangumiID] else { continue }
            aliasToBangumi["m\(index)"] = bangumiID
            variables["mal\(index)"] = malID
            index += 1
        }
        guard !aliasToBangumi.isEmpty else { return [:] }

        let fields = aliasToBangumi.keys.map { alias in
            "\(alias): Media(idMal: $mal\(alias.dropFirst()), type: ANIME) { episodes nextAiringEpisode { episode airingAt } }"
        }.joined(separator: "\n")
        let declarations = variables.keys.map { "$\($0): Int" }.joined(separator: ", ")
        let query = "query (\(declarations)) {\n\(fields)\n}"

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // AniList 会挡掉没带 User-Agent 的请求（直接 403），显式带一个。
        request.setValue("Kazumi-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables,
        ])

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return [:] }

        // 被限流：按服务端给的时间退避，别连续重发。
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                ?? http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map {
                    max(1, $0 - Date().timeIntervalSince1970)
                }
                ?? 30
            try? await Task.sleep(for: .seconds(min(max(retryAfter, 1), 60)))
            return [:]
        }
        guard (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any]
        else { return [:] }

        var result: [Int: Payload] = [:]
        for (alias, bangumiID) in aliasToBangumi {
            guard let media = payload[alias] as? [String: Any] else { continue }
            if let next = media["nextAiringEpisode"] as? [String: Any],
               let airingAt = next["airingAt"] as? Int {
                result[bangumiID] = Payload(
                    airingAt: airingAt * 1000,
                    episode: next["episode"] as? Int,
                    finished: false
                )
            } else {
                // 没有下一次播出：这部番已经播完（或还没开播）。
                // 记一条「已完播」，避免每次加载都重新查它。
                let fetchedAt = Date().millisecondsSinceEpoch
                result[bangumiID] = Payload(airingAt: fetchedAt, episode: media["episodes"] as? Int, finished: true)
            }
        }
        return result
    }

    // MARK: - 磁盘缓存

    private struct DiskPayload: Codable {
        var entries: [String: AniListAiring]
    }

    private func loadDiskCacheIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data)
        else { return }
        let now = Date()
        for (key, airing) in payload.entries {
            guard let bangumiID = Int(key) else { continue }
            // 过期条目（完播、停播、下架）直接丢掉，不再占缓存。
            guard !airing.isExpired(at: now, maxAge: Self.maxAge) else { continue }
            memory[bangumiID] = airing
        }
    }

    private func saveDiskCache() {
        var entries: [String: AniListAiring] = [:]
        let now = Date()
        for (bangumiID, airing) in memory where !airing.isExpired(at: now, maxAge: Self.maxAge) {
            entries["\(bangumiID)"] = airing
        }
        guard let data = try? JSONEncoder().encode(DiskPayload(entries: entries)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
