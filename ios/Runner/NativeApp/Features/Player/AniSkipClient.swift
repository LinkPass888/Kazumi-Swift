//
//  AniSkipClient.swift
//  Kazumi
//
//  AniSkip（https://api.aniskip.com）的片头片尾时间轴，原生实现，对应
//  lib/services/skip/aniskip_client.dart：
//
//  1. Bangumi 的 subject id 换成 MyAnimeList id——走 LinkPass888/bangumi-mal
//     那张表（CC BY 4.0，合并了 BangumiExtLinker 和 bangumi-data）；
//     全量表查不到时按 `bangumi_id % 100` 的分片补查一次。
//  2. `GET /v2/skip-times/{malId}/{集数}?types=op&types=ed&types=mixed-op&types=mixed-ed`
//     拿这一集的片头 / 片尾区间。
//
//  时间轴是社区按在线片源测的，所以只给在线播放用（本地文件不查，见
//  PlayerController.maybeLoadSkipSegments）。
//

import Foundation

/// AniSkip 查询客户端。单例，跟 main 的 `AniSkipClient.instance` 对齐。
enum AniSkipClient {
    private static let baseURL = "https://linkpass888.github.io/bangumi-mal/data"
    private static let mapPath = "/bangumi-mal.min.json"
    private static let shardPath = "/shards"
    private static let mapMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private static let sessionProvider = ProxyAwareURLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        KazumiNetworkPolicy.applyProxy(to: configuration)
        return configuration
    }

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private static var session: URLSession { sessionProvider.session }

    // MARK: - bangumi id -> mal id

    /// 全量表的下载 promise（去重用：同时来的几次查询只下一次）。
    /// 包一层 class：`Task` 是值类型，没法用 `===` 认自己是不是被换掉了。
    private final class MapDownload: @unchecked Sendable {
        let task: Task<[Int: Int], Error>
        init(task: Task<[Int: Int], Error>) { self.task = task }
    }

    private nonisolated(unsafe) static var mapDownload: MapDownload?
    /// 内存里已取到的分片（bangumi_id % 100 -> {bangumi_id: mal_id}）。
    private nonisolated(unsafe) static var shards: [Int: [Int: Int]] = [:]

    /// 这部番的 MAL id；查不到返回 nil（新番、或表里没有）。
    static func malID(for bangumiID: Int) async -> Int? {
        guard bangumiID > 0 else { return nil }
        // 重叠的查询共用一次下载；失败不留在内存里，下次再试。
        if mapDownload == nil {
            mapDownload = MapDownload(task: Task { try await loadMap() })
        }
        let download = mapDownload
        guard let download else { return nil }
        do {
            let map = try await download.task.value
            if let mal = map[bangumiID] { return mal }
            return await lookupShard(bangumiID)
        } catch {
            if mapDownload === download { mapDownload = nil }
            return nil
        }
    }

    private static func loadMap() async throws -> [Int: Int] {
        let cache = mapCacheURL
        let fresh = fileAge(cache).map { $0 < mapMaxAge } ?? false
        if !fresh {
            do {
                let map = parseMap(try await get(path: mapPath))
                write(map, to: cache)
                return map
            } catch {
                KazumiLogBuffer.player("AniSkip: bangumi-mal 表下载失败")
            }
        }
        if let stored = read(cache) { return stored }
        return [:]
    }

    private static func lookupShard(_ bangumiID: Int) async -> Int? {
        let shard = bangumiID % 100
        if let cached = shards[shard] { return cached[bangumiID] }

        let cache = shardCacheURL(shard)
        if fileAge(cache).map({ $0 < mapMaxAge }) ?? false {
            let stored = read(cache)
            shards[shard] = stored ?? [:]
            return stored?[bangumiID]
        }
        // 没有缓存或已过期：拉一次分片（~2 KB）。404 也是「没有」，落一份空表，
        // 免得每次都去问。
        let map = parseMap((try? await get(path: "\(shardPath)/\(shard).json")) ?? Data())
        write(map, to: cache)
        shards[shard] = map
        return map[bangumiID]
    }

    // MARK: - 查区间

    /// 查这一集的片头 / 片尾。任何失败都当成「没有」——这只是个增强，
    /// 查不到不该影响播放。
    static func lookup(bangumiID: Int, episode: Int, duration: Double) async -> SkipSegments {
        guard bangumiID > 0, episode > 0 else { return .empty }
        guard let malID = await malID(for: bangumiID) else { return .empty }

        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)")
        components?.queryItems = [
            URLQueryItem(name: "types[]", value: "op"),
            URLQueryItem(name: "types[]", value: "ed"),
            URLQueryItem(name: "types[]", value: "mixed-op"),
            URLQueryItem(name: "types[]", value: "mixed-ed")
        ]
        if duration > 0 {
            components?.queryItems?.append(
                URLQueryItem(name: "episodeLength", value: "\(Int(duration.rounded()))")
            )
        }
        guard let url = components?.url else { return .empty }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return .empty
            }
            return parseResponse(data)
        } catch {
            KazumiLogBuffer.player("AniSkip: 查询失败")
            return .empty
        }
    }

    // MARK: - 解析

    private static func parseResponse(_ data: Data) -> SkipSegments {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["found"] as? Bool == true,
            let results = root["results"] as? [[String: Any]]
        else { return .empty }

        var opening: SkipRange?
        var ending: SkipRange?
        for result in results {
            guard
                let interval = result["interval"] as? [String: Any],
                let start = (interval["startTime"] as? NSNumber)?.doubleValue,
                let end = (interval["endTime"] as? NSNumber)?.doubleValue,
                end > start
            else { continue }
            let range = SkipRange(start: start, end: end, source: .aniskip)
            switch result["skipType"] as? String {
            case "op", "mixed-op":
                if opening == nil { opening = range }
            case "ed", "mixed-ed":
                if ending == nil { ending = range }
            default:
                continue
            }
        }
        return SkipSegments(opening: opening, ending: ending)
    }

    private static func parseMap(_ data: Data) -> [Int: Int] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [Int: Int] = [:]
        for (key, value) in root {
            guard
                let bangumi = Int(key),
                let mal = (value as? NSNumber)?.intValue,
                mal > 0
            else { continue }
            result[bangumi] = mal
        }
        return result
    }

    // MARK: - 落盘

    private static var supportDirectory: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support
            .appendingPathComponent("Kazumi", isDirectory: true)
            .appendingPathComponent("skip", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var mapCacheURL: URL {
        supportDirectory.appendingPathComponent("bangumi_mal.json")
    }

    private static func shardCacheURL(_ shard: Int) -> URL {
        supportDirectory
            .appendingPathComponent("shards", isDirectory: true)
            .appendingPathComponent("\(shard).json")
    }

    private static func fileAge(_ url: URL) -> TimeInterval? {
        guard
            let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private static func read(_ url: URL) -> [Int: Int]? {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let map = parseMap(data)
        return map.isEmpty ? nil : map
    }

    private static func write(_ map: [Int: Int], to url: URL) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: map.mapKeys { String($0) })
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 网络

    private static func get(path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await session.data(from: url)
        return data
    }
}

private extension Dictionary {
    func mapKeys<T>(_ transform: (Key) throws -> T) rethrows -> [T: Value] {
        var result: [T: Value] = [:]
        for (key, value) in self {
            result[try transform(key)] = value
        }
        return result
    }
}
