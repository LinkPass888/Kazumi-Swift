//
//  PopularRowCache.swift
//  Kazumi
//
//  推荐页每行结果的落盘缓存。
//
//  口径（LP 2733 / Ato 2734 / LP 2827 / Ato 2828）：
//  * 默认 15 天（综合排名、收藏榜、本季新番），只有本周热门给 7 天；
//  * 进推荐页先画缓存，再后台刷新；过期了才重新拉；
//  * 换季不靠缓存过期：本季新番那行的键里直接带季度标签
//    （如 `season-2025-Q4`），一换季键就变了，天然读不到旧数据。
//  * **缓存键要带上镜像来源**，否则切了加速方式还在读另一边的旧数据。
//  * 下拉刷新已按 LP 2823 / Colo 2824 去掉：各行照旧按各自的过期时间自己换新。
//

import Foundation

@MainActor
final class PopularRowCache {
    static let shared = PopularRowCache()

    /// 一行缓存的过期时间。
    enum TTL {
        /// 本周热门（趋势榜）：7 天。
        static let fast: TimeInterval = 7 * 24 * 60 * 60
        /// 综合排名、收藏榜、本季新番：15 天（LP 2825）。
        static let slow: TimeInterval = 15 * 24 * 60 * 60
    }

    private struct Payload: Codable {
        var savedAt: Date
        var items: [PopularPoster]
    }

    /// 缓存目录；传 nil 表示用应用自己的存储根（Application Support/Kazumi/popular）。
    ///
    /// 不在 init 里就读 `AppEnvironment.storageRoot`：那是 MainActor 上的东西，
    /// 而 init 的隔离性取哪种写法都能编过，把它推到使用时读（本类所有用法本来就在 MainActor 上）。
    private let directory: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        self.directory = directory
    }

    /// 缓存目录（不存在就建）。
    private var root: URL {
        let url = directory ?? AppEnvironment.storageRoot.appending(path: "popular")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 取缓存，**不看是否过期**：过期的那份也照样先画出来，
    /// 再由调用方决定要不要后台刷新（这就是「先画缓存再刷新」）。
    func items(for key: String) -> [PopularPoster]? {
        guard let payload = load(key), !payload.items.isEmpty else { return nil }
        return payload.items
    }

    /// 这份缓存还在有效期内吗。
    func isFresh(_ key: String, ttl: TimeInterval) -> Bool {
        guard let payload = load(key) else { return false }
        return Date().timeIntervalSince(payload.savedAt) < ttl
    }

    func store(_ items: [PopularPoster], for key: String) {
        guard !items.isEmpty else { return }
        guard let data = try? encoder.encode(Payload(savedAt: Date(), items: items)) else { return }
        try? data.write(to: fileURL(key), options: .atomic)
    }

    /// 这份缓存还在有效期内吗。
    // MARK: - 内部

    private func load(_ key: String) -> Payload? {
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        return try? decoder.decode(Payload.self, from: data)
    }

    private func fileURL(_ key: String) -> URL {
        // 键里可能带季度、标签、镜像来源，统一换成文件名安全的形状。
        let safe = key.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return root.appending(path: "\(safe).json")
    }
}

extension PopularRowCache {
    /// 一行缓存键的统一拼法。
    ///
    /// `source` 是镜像来源标记：趋势榜与评分榜走哪个域名结果不一样，
    /// 必须算进键里；季度接口只有镜像一条路，但照样带上，口径统一。
    static func key(_ name: String, source: String, extra: String? = nil) -> String {
        var key = "\(name)-\(source)"
        if let extra, !extra.isEmpty { key += "-\(extra)" }
        return key
    }

    /// 当前的镜像来源标记。
    static var currentSource: String {
        BangumiAcceleration.isMirrorEnabled ? "mirror" : "direct"
    }

    /// 本季度的键后缀，形如 `2025-Q4`。换季那一刻键就变了。
    static func currentSeasonTag(now: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let quarter = (month - 1) / 3 + 1
        return "\(year)-Q\(quarter)"
    }
}
