//
//  BangumiAPI.swift
//  Kazumi
//
//  1:1 翻译 lib/request/apis/bangumi_api.dart 与 lib/request/clients/bangumi_client.dart。
//
//  行为约定（与 Dart 版逐条对齐）：
//  * UA 固定为 Bangumi 文档要求的 `Predidit/Kazumi/<版本> (Android) (...)`；
//  * 超时沿用 NetworkConfig 默认值：连接 12s / 接收 12s；
//  * 首页与搜索失败时不抛错，返回空结果（原实现 catch 后记日志）；
//  * 开启 Bangumi 镜像加速时，热门列表改走 api.kazumi.fyi 的缓存榜单。
//

import Foundation
import os

/// 与 lib/request/config/api_endpoints.dart 一致的端点表。
enum BangumiEndpoints {
    static let apiDomain = "https://api.bgm.tv"
    static let apiNextDomain = "https://next.bgm.tv"
    static let mirrorDomain = "https://api.kazumi.fyi"

    /// 番剧信息（next 版本带 info 与 metaTags）。
    static let infoByIDNext = "/p1/subjects/{0}"
    /// 条目搜索（支持 rank 排序与过滤器）。
    static let rankSearch = "/v0/search/subjects?limit={0}&offset={1}"
    /// 每日放送。
    static let calendar = "/p1/calendar"
    /// 番剧趋势。
    static let trendsNext = "/p1/trending/subjects"
    /// Kazumi 镜像缓存榜单。
    static let mirrorPopularSubjects = "/kazumi/v1/popular/subjects"
    /// Kazumi 镜像季度时间表。
    static let mirrorSeasonCalendar = "/kazumi/v1/calendar/season"
    /// 剧集列表。
    static let episodes = "/v0/episodes"
    /// 标记单集看到。
    static let setEpisode = "/v0/users/-/collections/-/episodes/{0}"
    /// 关联条目（续集 / 前传 / 角色等）。
    static let relations = "/v0/subjects/{0}/subjects"
    /// 角色列表。
    static let characters = "/v0/subjects/{0}/characters"
    /// 制作人员（原作 / 导演 / 声优等）。
    static let staff = "/v0/subjects/{0}/persons"
    /// 吐槽（评论），next 域。
    static let commentsNext = "/p1/subjects/{0}/comments?limit={1}&offset={2}"

    /// 写收藏（追番状态 / 吐槽 / 评分）。与原版 api_endpoints.dart 一致：
    /// 写操作走 bgmapi 这个认证镜像域，读操作走 api.bgm.tv。
    static let authMirrorDomain = "https://api.bgmapi.com"
    static let setCollection = "/v0/users/-/collections/{0}"

    /// 对应 ApiEndpoints.formatUrl。
    static func format(_ template: String, _ params: [CustomStringConvertible]) -> String {
        var url = template
        for (index, value) in params.enumerated() {
            url = url.replacingOccurrences(of: "{\(index)}", with: value.description)
        }
        return url
    }
}

/// Bangumi 加速方式（对应 services/network/bangumi_acceleration.dart）。
enum BangumiAcceleration: String, Sendable {
    case direct
    case mirror

    /// 与 Dart 的 `BangumiAcceleration.current` 对应，由设置页写入。
    static let current = OSAllocatedUnfairLock(initialState: BangumiAcceleration.direct)

    /// 当前加速方式（读写都要走锁）。
    static var mode: BangumiAcceleration {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    static var isMirrorEnabled: Bool {
        current.withLock { $0 == .mirror }
    }
}

/// 搜索结果页（对应 BangumiSearchPage）。
struct BangumiSearchPage: Sendable {
    var items: [BangumiItem]
    var rawCount: Int
}

/// Bangumi 数据接口。对应 lib/request/apis/bangumi_api.dart。
///
/// 首页 / 搜索类接口沿袭原实现「失败返回空结果」的契约：
/// 调用方只需要根据空列表展示错误态，不必再区分网络异常。
enum BangumiAPI {
    /// 与 NetworkConfig 默认值一致。
    private static let connectTimeout: TimeInterval = 12
    private static let receiveTimeout: TimeInterval = 12

    private static let sessionProvider = ProxyAwareURLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = receiveTimeout
        config.timeoutIntervalForResource = connectTimeout + receiveTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        KazumiNetworkPolicy.applyProxy(to: config)
        return config
    }

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private static var session: URLSession { sessionProvider.session }

    // MARK: - 每日放送

    /// 对应 getCalendar：返回 7 天的番剧，下标 0 为周一。
    /// 成功后把原始 JSON 落盘（`TimelineCache`），冷启动时先用它铺。
    static func calendar() async -> [[BangumiItem]] {
        var result: [[BangumiItem]] = []
        do {
            let json = try await get(BangumiEndpoints.apiNextDomain + BangumiEndpoints.calendar)
            var rawDays: [JSONValue] = []
            for day in 1...7 {
                let list = json["\(day)"].arrayValue ?? []
                // 存原始条目（含 `subject` 那一层），读回来走同一套解析。
                rawDays.append(.array(list))
                result.append(list.compactMap { entry in
                    guard !entry["subject"].isNull else { return nil }
                    return BangumiItem.fromJSON(entry["subject"])
                })
            }
            // 列表里已经拿到的条目记进缓存：点进详情页时先有内容可画。
            let flat = result.flatMap { $0 }
            await BangumiSubjectCache.shared.remember(flat)
            await TimelineCache.shared.storeCurrent(
                rawDays: rawDays,
                seasonStart: AnimeSeason.seasonRange(for: Date()).start
            )
        } catch {
            KazumiLog.network.error("Resolve calendar failed: \(error.localizedDescription, privacy: .public)")
            if result.isEmpty {
                result = (0..<7).map { _ in [] }
            }
        }
        return result
    }

    /// 上周缓存的那份日历（不发请求）。冷启动先用它铺，网络回来再盖。
    /// 返回 nil 表示没有可用缓存（从没成功拉过，或缓存是空的）。
    static func cachedCalendar() async -> [[BangumiItem]]? {
        let seasonStart = AnimeSeason.seasonRange(for: Date()).start
        guard let rawDays = await TimelineCache.shared.currentRawDays(seasonStart: seasonStart) else { return nil }
        return rawDays.map { day in
            guard case let .array(list) = day else { return [] }
            return list.compactMap { entry in
                guard !entry["subject"].isNull else { return nil }
                return BangumiItem.fromJSON(entry["subject"])
            }
        }
    }

    // MARK: - 推荐列表

    /// 对应 getBangumiTrendsList：next.bgm.tv 的趋势榜，每页 24 条。
    static func trends(limit: Int = 24, offset: Int = 0, type: Int = 2) async -> [BangumiItem]? {
        do {
            let url = BangumiEndpoints.apiNextDomain + BangumiEndpoints.trendsNext
            let json = try await get(
                url,
                query: [
                    URLQueryItem(name: "type", value: "\(type)"),
                    URLQueryItem(name: "limit", value: "\(limit)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                ]
            )
            let items: [BangumiItem] = (json["data"].arrayValue ?? []).compactMap { entry -> BangumiItem? in
                guard !entry["subject"].isNull else { return nil }
                return BangumiItem.fromJSON(entry["subject"])
            }
            await BangumiSubjectCache.shared.remember(items)
            return items
        } catch {
            KazumiLog.network.error("Resolve bangumi trends failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 对应 getBangumiMirrorPopularSubjects：走 Kazumi 镜像缓存，支持标签。
    static func mirrorPopular(tag: String = "", limit: Int = 24, offset: Int = 0) async -> [BangumiItem]? {
        do {
            var components = URLComponents()
            components.path = BangumiEndpoints.mirrorPopularSubjects
            var items: [URLQueryItem] = []
            if !tag.isEmpty { items.append(URLQueryItem(name: "tag", value: tag)) }
            items.append(URLQueryItem(name: "limit", value: "\(limit)"))
            items.append(URLQueryItem(name: "offset", value: "\(offset)"))
            components.queryItems = items
            let path = components.string ?? BangumiEndpoints.mirrorPopularSubjects
            let json = try await get(BangumiEndpoints.mirrorDomain + path)
            let list = json.arrayValue ?? json["data"].arrayValue ?? []
            return list.compactMap { BangumiItem.fromJSON($0) }
        } catch {
            KazumiLog.network.error("Resolve bangumi mirror popular failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 综合排名（原名「评分最高」）：官方搜索按 rank 升序的**固定区间**（不是随机名次）。
    ///
    /// 推荐页「综合排名」那行和它的列表页用这一个口子。原来的 `listByTag`
    /// 按标签取的时候用的是随机名次（`Int.random(in: 1...8000)`），同一行两次
    /// 打开内容不一样，Ato 定过这种不稳的源不能进首页。
    static func ranked(limit: Int = 10, offset: Int = 0) async -> [BangumiItem]? {
        let params = searchParams(
            keyword: "",
            tags: ["日本"],
            sort: "rank",
            rankFilter: [">0", "<=99999"]
        )
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.rankSearch,
                [limit, offset]
            )
            let json = try await post(url, body: params)
            let items: [BangumiItem] = (json["data"].arrayValue ?? []).compactMap { entry -> BangumiItem? in
                BangumiItem.fromJSON(entry)
            }
            await BangumiSubjectCache.shared.remember(items)
            return items
        } catch {
            KazumiLog.network.error("Resolve bangumi ranked failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 收藏榜：官方搜索按 heat 降序。
    ///
    /// next.bgm.tv 的 SubjectSearchSort 里 `heat` 的定义就是「收藏人数」，
    /// 所以这是收藏总数榜——跟「本周热门」（趋势，正在涨的）不是一回事。
    static func collected(limit: Int = 10, offset: Int = 0) async -> [BangumiItem]? {
        let params = searchParams(keyword: "", sort: "heat")
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.rankSearch,
                [limit, offset]
            )
            let json = try await post(url, body: params)
            let items: [BangumiItem] = (json["data"].arrayValue ?? []).compactMap { entry -> BangumiItem? in
                BangumiItem.fromJSON(entry)
            }
            await BangumiSubjectCache.shared.remember(items)
            return items
        } catch {
            KazumiLog.network.error("Resolve bangumi collected failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 对应 getBangumiList：按标签（或随机名次）从官方搜索接口取 100 条。
    static func listByTag(rank: Int = 2, tag: String = "") async -> [BangumiItem]? {
        let params = searchParams(
            keyword: "",
            tags: tag.isEmpty ? ["日本"] : [tag],
            sort: "rank",
            rankFilter: tag.isEmpty ? [">\(rank)", "<=1050"] : [">\(rank)", "<=99999"]
        )
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.rankSearch,
                [100, 0]
            )
            let json = try await post(url, body: params)
            return (json["data"].arrayValue ?? []).compactMap { BangumiItem.fromJSON($0) }
        } catch {
            KazumiLog.network.error("Resolve bangumi list failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 搜索

    /// 对应 buildBangumiSearchParams。
    static func searchParams(
        keyword: String,
        tags: [String] = [],
        sort: String = "heat",
        rankFilter: [String]? = nil,
        airDateRange: [String]? = nil,
        scoreFilter: [String]? = nil,
        weekdays: [Int] = []
    ) -> JSONValue {
        let rank = rankFilter ?? (sort == "rank" ? [">0", "<=99999"] : [">=0", "<=99999"])
        var filter: [String: JSONValue] = [
            "type": .array([JSONValue.int(2)]),
            "tag": .array(tags.map { JSONValue.string($0) }),
            "rank": .array(rank.map { JSONValue.string($0) }),
            "nsfw": .bool(false),
        ]
        if let airDateRange, airDateRange.count == 2 {
            filter["air_date"] = .array([
                JSONValue.string(">=\(airDateRange[0])"),
                JSONValue.string("<\(airDateRange[1])"),
            ])
        }
        if let scoreFilter, !scoreFilter.isEmpty {
            filter["rating"] = .array(scoreFilter.map { JSONValue.string($0) })
        }
        if !weekdays.isEmpty {
            let unique = Array(Set(weekdays)).sorted()
            filter["air_weekday"] = .array(unique.map { JSONValue.int($0) })
        }
        return .object([
            "keyword": .string(keyword),
            "sort": .string(sort),
            "filter": .object(filter),
        ])
    }

    /// 对应 bangumiSearch：只保留有中文名的条目，rawCount 用于判断是否还有下一页。
    static func search(
        keyword: String,
        tags: [String] = [],
        limit: Int = 20,
        offset: Int = 0,
        sort: String = "heat",
        airDateRange: [String]? = nil,
        rankFilter: [String]? = nil,
        scoreFilter: [String]? = nil,
        weekdays: [Int] = []
    ) async -> BangumiSearchPage? {
        let params = searchParams(
            keyword: keyword,
            tags: tags,
            sort: sort,
            rankFilter: rankFilter,
            airDateRange: airDateRange,
            scoreFilter: scoreFilter,
            weekdays: weekdays
        )
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.rankSearch,
                [limit, offset]
            )
            let json = try await post(url, body: params)
            let raw = json["data"].arrayValue ?? []
            var items: [BangumiItem] = []
            for entry in raw {
                let item = BangumiItem.fromJSON(entry)
                // 与原实现一致：没有中文名的条目直接丢弃（通常是同人 / 非正式条目）。
                if !item.nameCn.isEmpty {
                    items.append(item)
                }
            }
            await BangumiSubjectCache.shared.remember(items)
            return BangumiSearchPage(items: items, rawCount: raw.count)
        } catch {
            KazumiLog.network.error("Unknown search problem: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 对应 getBangumiInfoByID：详情走 next 域，带 info 与 metaTags。
    static func info(id: Int) async -> BangumiItem? {
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiNextDomain + BangumiEndpoints.infoByIDNext,
                [id]
            )
            let json = try await get(url)
            let item = BangumiItem.fromJSON(json)
            // 没标题的响应当失败处理，不落盘（LP 2997）：
            // 镜像偶尔会回一个缺字段的壳，存下来之后详情页会一整天显示
            // 「未知」加一张没封面、没简介的空页，而缓存又算「有数据」，不再去拉。
            guard !item.displayName.isEmpty else {
                KazumiLog.network.error("Resolve bangumi item returned no title for id \(id, privacy: .public)")
                return nil
            }
            // 拉到的完整条目落盘：下次进详情页先拿它铺页面，不用再转圈等。
            await BangumiSubjectCache.shared.store(info: json, for: id)
            return item
        } catch {
            KazumiLog.network.error("Resolve bangumi item failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 详情页分标签

    /// 对应 getBangumiRelationsByID：关联条目（续集 / 前传 / 角色…）。
    static func relations(subjectID: Int) async -> [BangumiRelationItem] {
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.relations,
                [subjectID]
            )
            let json = try await get(url)
            return (json.arrayValue ?? []).compactMap(BangumiRelationItem.fromJSON)
        } catch {
            KazumiLog.network.error("Resolve bangumi relations failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 对应 getCharatersByBangumiID：角色列表。
    static func characters(subjectID: Int) async -> [BangumiCharacterItem] {
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.characters,
                [subjectID]
            )
            let json = try await get(url)
            return (json.arrayValue ?? []).map(BangumiCharacterItem.fromJSON)
        } catch {
            KazumiLog.network.error("Resolve bangumi characters failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 对应 getBangumiStaffByID：制作人员。
    static func staff(subjectID: Int) async -> [BangumiStaffItem] {
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.staff,
                [subjectID]
            )
            let json = try await get(url)
            return BangumiStaffItem.merge(json.arrayValue ?? [])
        } catch {
            KazumiLog.network.error("Resolve bangumi staff failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 对应 getBangumiCommentsByID：吐槽列表（next 域，一次 20 条）。
    static func comments(subjectID: Int, limit: Int = 20, offset: Int = 0) async -> BangumiCommentPage {
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiNextDomain + BangumiEndpoints.commentsNext,
                [subjectID, limit, offset]
            )
            let json = try await get(url)
            let list = json["list"].arrayValue ?? json["data"].arrayValue ?? []
            return BangumiCommentPage(
                items: list.map(BangumiCommentItem.fromJSON),
                total: json["total"].intValue ?? list.count
            )
        } catch {
            KazumiLog.network.error("Resolve bangumi comments failed: \(error.localizedDescription, privacy: .public)")
            return BangumiCommentPage(items: [], total: 0)
        }
    }

    /// 对应 `getBangumiEpisodeByID`：取某条番某话在 Bangumi 上的 episodeId。
    /// 失败时返回 nil，调用方就退回整部番的吐槽。
    static func episodeID(subjectID: Int, episode: Int) async -> Int? {
        // /v0/episodes?subject_id=xxx&offset=n&limit=1，对应 EpisodeInfo.fromJson
        let url = BangumiEndpoints.apiDomain + BangumiEndpoints.episodes
            + "?subject_id=\(subjectID)&offset=\(max(0, episode - 1))&limit=1"
        do {
            let json = try await get(url)
            if let list = json["data"].arrayValue, let first = list.first {
                return first["id"].intValue
            }
            return nil
        } catch {
            KazumiLog.network.error(
                "Resolve bangumi episode id failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// 对应 `getBangumiCommentsByEpisodeID`：单集评论（next 域，整集返回为数组）。
    static func episodeComments(episodeID: Int) async -> BangumiCommentPage {
        let url = BangumiEndpoints.apiNextDomain + "/p1/episodes/\(episodeID)/comments"
        do {
            let json = try await get(url)
            let list = json.arrayValue ?? json["data"].arrayValue ?? []
            // next 域的单集评论目前直接返回数组，total 以 count 为准
            return BangumiCommentPage(
                items: list.map(BangumiCommentItem.fromJSON),
                total: json["total"].intValue ?? list.count
            )
        } catch {
            KazumiLog.network.error(
                "Resolve episode comments failed: \(error.localizedDescription, privacy: .public)"
            )
            return BangumiCommentPage(items: [], total: 0)
        }
    }

    // MARK: - 写收藏 / 吐槽

    /// 对应 addOrUpdateBangumiEvaluationBySubjectID：把「追番状态 + 吐槽 + 评分」
    /// 写回 Bangumi。
    ///
    /// 原版的写操作走 bgmapi 认证镜像域，且必须带用户令牌；没有令牌直接返回
    /// false，让调用方提示先登录，而不是发一个必然 401 的请求。
    static func updateCollection(
        subjectID: Int,
        type: CollectType,
        comment: String? = nil,
        rate: Int? = nil
    ) async -> Bool {
        guard let bangumiType = type.bangumiCollectionType, accessToken != nil else {
            return false
        }
        var body: [String: JSONValue] = ["type": .int(bangumiType)]
        if let comment { body["comment"] = .string(comment) }
        if let rate { body["rate"] = .int(rate) }
        let url = BangumiEndpoints.format(
            BangumiEndpoints.authMirrorDomain + BangumiEndpoints.setCollection,
            [subjectID]
        )
        do {
            _ = try await post(url, body: .object(body), requiresAuth: true)
            KazumiLog.network.debug("Update bangumi collection: \(subjectID, privacy: .public)")
            return true
        } catch {
            KazumiLog.network.error(
                "Update bangumi collection failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - 剧集

    /// 对应 getBangumiEpisodesByID：每页 100 条，按 total 续抓。
    static func episodes(subjectID: Int) async -> [BangumiEpisode] {
        var episodes: [BangumiEpisode] = []
        var raw: [JSONValue] = []
        var offset = 0
        let limit = 100
        var total: Int?
        repeat {
            do {
                let json = try await get(
                    BangumiEndpoints.apiDomain + BangumiEndpoints.episodes,
                    query: [
                        URLQueryItem(name: "subject_id", value: "\(subjectID)"),
                        URLQueryItem(name: "offset", value: "\(offset)"),
                        URLQueryItem(name: "limit", value: "\(limit)"),
                    ]
                )
                if total == nil { total = json["total"].intValue }
                let data = json["data"].arrayValue ?? []
                if data.isEmpty { break }
                raw.append(contentsOf: data)
                episodes.append(contentsOf: data.map(BangumiEpisode.fromJSON))
                offset += data.count
            } catch {
                KazumiLog.network.error(
                    "Resolve bangumi episode list failed: \(error.localizedDescription, privacy: .public)"
                )
                break
            }
        } while (total ?? Int.max) > offset
        if let total, offset < total { return [] }
        if !raw.isEmpty {
            await BangumiSubjectCache.shared.store(episodes: raw, for: subjectID)
        }
        return episodes
    }

    // MARK: - 季度时间表

    /// 对应 getCalendarBySearch：按季度日期区间抓取并放进 7 天的桶里。
    static func calendarBySearch(dateRange: [String], limit: Int, offset: Int) async -> [[BangumiItem]] {
        var items: [BangumiItem] = []
        var filter: [String: JSONValue] = [
            "type": .array([JSONValue.int(2)]),
            "tag": .array([JSONValue.string("日本")]),
            "rank": .array([JSONValue.string(">0"), JSONValue.string("<=99999")]),
            // 原实现这里允许 NSFW，保证季度表完整。
            "nsfw": .bool(true),
        ]
        if dateRange.count == 2 {
            filter["air_date"] = .array([
                JSONValue.string(">=\(dateRange[0])"),
                JSONValue.string("<\(dateRange[1])"),
            ])
        }
        let body: JSONValue = .object([
            "keyword": .string(""),
            "sort": .string("rank"),
            "filter": .object(filter),
        ])
        do {
            let url = BangumiEndpoints.format(
                BangumiEndpoints.apiDomain + BangumiEndpoints.rankSearch,
                [limit, offset]
            )
            let json = try await post(url, body: body)
            items = (json["data"].arrayValue ?? []).map(BangumiItem.fromJSON)
        } catch {
            KazumiLog.network.error("Resolve season calendar failed: \(error.localizedDescription, privacy: .public)")
        }
        return (1...7).map { weekday in
            items.filter { $0.airWeekday == weekday }
        }
    }

    /// 对应 getBangumiMirrorSeasonCalendar：镜像按 start / end 返回 7 天分组。
    static func mirrorSeasonCalendar(start: String, end: String) async -> [[BangumiItem]] {
        do {
            var components = URLComponents()
            components.path = BangumiEndpoints.mirrorSeasonCalendar
            components.queryItems = [
                URLQueryItem(name: "start", value: start),
                URLQueryItem(name: "end", value: end),
            ]
            let path = components.string ?? BangumiEndpoints.mirrorSeasonCalendar
            let json = try await get(BangumiEndpoints.mirrorDomain + path)
            return (1...7).map { day in
                (json["\(day)"].arrayValue ?? []).compactMap { entry in
                    guard !entry["subject"].isNull else { return nil }
                    return BangumiItem.fromJSON(entry["subject"])
                }
            }
        } catch {
            KazumiLog.network.error("Resolve mirror season calendar failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - HTTP

    /// 对应 BangumiClient.get。
    /// `requiresAuth` 默认 `false`：公开接口不带令牌（见 `send` 里那段注释）。
    private static func get(
        _ url: String,
        query: [URLQueryItem] = [],
        requiresAuth: Bool = false
    ) async throws -> JSONValue {
        try await send(url, method: "GET", query: query, body: nil, requiresAuth: requiresAuth)
    }

    /// 对应 BangumiClient.post。
    private static func post(
        _ url: String,
        body: JSONValue,
        requiresAuth: Bool = false
    ) async throws -> JSONValue {
        try await send(url, method: "POST", query: [], body: body, requiresAuth: requiresAuth)
    }

    /// 对应 BangumiClient.put（原版「单集进度」那条专用）。
    private static func put(
        _ url: String,
        body: JSONValue,
        requiresAuth: Bool = false
    ) async throws -> JSONValue {
        try await send(url, method: "PUT", query: [], body: body, requiresAuth: requiresAuth)
    }

    private static func send(
        _ url: String,
        method: String,
        query: [URLQueryItem],
        body: JSONValue?,
        requiresAuth: Bool = false
    ) async throws -> JSONValue {
        guard var components = URLComponents(string: url) else {
            throw NetworkError.transport("Bangumi 接口地址无效: \(url)")
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let finalURL = components.url else {
            throw NetworkError.transport("Bangumi 接口地址无效: \(url)")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = receiveTimeout
        // 头名与顺序对齐 http_headers.dart 的 bangumiHTTPHeader。
        request.setValue(
            "Predidit/Kazumi/\(KazumiAppInfo.version) (Android) (https://github.com/Predidit/Kazumi)",
            forHTTPHeaderField: "user-agent"
        )
        request.setValue("", forHTTPHeaderField: "referer")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if requiresAuth, let token = accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        if let body {
            request.httpBody = Data(body.serialized(pretty: false).utf8)
        }

        // notice 级而不是 debug：debug 不落盘，出问题时抓不到；这一行只有方法、地址和「带没带令牌」，不含令牌本身。
        KazumiLog.network.notice("\(method, privacy: .public) \(finalURL.absoluteString, privacy: .public) auth=\(Self.authState, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw NetworkError.cancelled }
            throw NetworkError.transport(error.localizedDescription)
        } catch {
            throw NetworkError.transport(error.localizedDescription)
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport("Bangumi 返回了非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.badResponse(status: http.statusCode, body: text, headers: [:])
        }
        // 2xx 但响应体是空的，是成功，不是解析失败。
        //
        // 写接口就是这样回的：`POST /v0/users/-/collections/{id}` 返回 202 Accepted、
        // 一个字节都没有（LP 3568 的抓包）。原版 main 那边 `post` 只把 `response.data`
        // 递出去，空的就当没有，状态码过了就算成功；这里原先无条件解码，
        // 空 body 抛错，于是 Bangumi 明明改好了，本机却回滚并报「同步失败」。
        // 评分、吐槽、单集进度走的是同一个 `send`，一起靠这一处兜住。
        if data.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .null
        }
        do {
            return try JSONValue.decode(data)
        } catch {
            throw NetworkError.decoding("Bangumi 响应解析失败: \(error.localizedDescription)")
        }
    }

    /// Bangumi 访问令牌由设置页写入；为空时不带 Authorization。
    private static let accessTokenBox = OSAllocatedUnfairLock<String>(initialState: "")

    static var accessToken: String? {
        get {
            let token = accessTokenBox.withLock { $0 }
            return token.isEmpty ? nil : token
        }
        set { accessTokenBox.withLock { $0 = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } }
    }

    /// 「检查令牌」的结果。
    ///
    /// 这个类型的意义在于把「令牌到底有没有穿到请求层」变成用户看得见的一件事：
    /// 用户自己粘的令牌，粘错了只会看到一片空白，分不清是令牌错、网络错还是 App 坏。
    enum TokenCheckResult: Sendable {
        /// 连上了，附用户名（昵称优先，没有昵称时退回用户名）、Bangumi 的数字用户 ID，
        /// 以及服务器给的原始用户名（同步引擎拼收藏列表地址要用它，见交接文档）。
        ///
        /// ID 只从这里来：它是在替令牌担保「你是谁」，所以不许本地方便行事存一个。
        case ok(name: String, id: String, username: String)
        /// 没填令牌，本地就直接停了，没有发出请求。
        case missing
        /// 服务器拒绝了这串令牌（401/403）。
        case rejected
        /// 请求根本没走通（断网、超时、DNS 等）。
        case unreachable(String)
    }

    /// 拿当前令牌请求自己的用户信息（`/v0/me`）。
    ///
    /// 走的是和别的接口同一个 `send`，所以 `Authorization` 头的拼接方式与真实请求完全一致；
    /// 能拿到用户名，就说明令牌确实穿过了请求层。
    static func checkToken() async -> TokenCheckResult {
        guard accessToken != nil else { return .missing }
        do {
            let json = try await send(
                "https://api.bgm.tv/v0/me",
                method: "GET",
                query: [],
                body: nil,
                requiresAuth: true
            )
            let nickname = json["nickname"].stringValue
            let username = json["username"].stringValue
            let name = (nickname?.isEmpty == false ? nickname : username) ?? ""
            // 6 位数字 ID：返回里没有它的时候给空串，由界面那行显示「无法确认」——
            // 空着不留上一次的值，免得屏幕替一个坏令牌担保身份。
            let id = json["id"].intValue.map(String.init) ?? ""
            return .ok(
                name: name.isEmpty ? "（未返回用户名）" : name,
                id: id,
                username: username ?? ""
            )
        } catch let error as NetworkError {
            if case let .badResponse(status, _, _) = error, status == 401 || status == 403 {
                return .rejected
            }
            return .unreachable(error.localizedDescription)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    // MARK: - 追番同步（收藏列表 / 单集标记）

    /// 用户在 Bangumi 上的一条收藏状态。
    ///
    /// 对应 lib/modules/bangumi/bangumi_collection.dart：只留同步引擎要用的字段。
    /// 远端条目要落进本地收藏库，所以这里也把条目的展示信息一起带回来，
    /// 否则「补全本地缺失状态」只能写一个没有名字的空壳。
    struct RemoteCollection: Sendable {
        var subjectID: Int
        /// Bangumi 的收藏类型：1 想看 / 2 看过 / 3 在看 / 4 搁置 / 5 抛弃。
        var type: Int
        var updatedAt: Date
        var name: String
        var nameCn: String
        var summary: String
        var airDate: String
        var rating: Double
        var rank: Int
        var totalEpisodes: Int
        var imageURL: String
        var tags: [String]

        init?(_ json: JSONValue) {
            let subject = json["subject"]
            let id = subject["id"].intValue ?? json["subject_id"].intValue ?? 0
            guard id > 0 else { return nil }
            // updated_at 是「最新优先」比较用的时间；缺了就跳过这一条，
            // 不能拿当前时间去顶——那会让它凭空赢下每一次冲突（原版同样跳过）。
            guard let raw = json["updated_at"].stringValue,
                  let updatedAt = DateTimeHelper.parseISO(raw) else { return nil }
            self.subjectID = id
            self.type = json["type"].intValue ?? 0
            self.updatedAt = updatedAt
            self.name = subject["name"].stringValue ?? ""
            self.nameCn = subject["name_cn"].stringValue ?? ""
            self.summary = subject["short_summary"].stringValue ?? ""
            self.airDate = subject["date"].stringValue ?? ""
            self.rating = subject["score"].doubleValue ?? 0
            self.rank = subject["rank"].intValue ?? 0
            self.totalEpisodes = subject["eps"].intValue ?? 0
            self.imageURL = subject["images"]["large"].stringValue ?? ""
            self.tags = (subject["tags"].arrayValue ?? []).compactMap { $0["name"].stringValue }
        }
    }

    /// 拉取某个用户的全部番剧收藏（`subject_type=2`，只看番剧）。
    ///
    /// 对应 getBangumiCollectibles：按 `total` 一页页续抓，进度用
    /// 「正在拉取 Bangumi 收藏」报出去。原版并发 3 页、限速 200ms；
    /// 这里改成顺序一页一页拉并保持 200ms 间隔 —— 收藏通常只有几百条，
    /// 页数很少，少一层并发就少一处可以出错的地方。
    static func remoteCollections(
        username: String,
        limit: Int = 50,
        onProgress: (@Sendable (String, Int, Int) -> Void)? = nil
    ) async throws -> [RemoteCollection] {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NetworkError.transport("还没确认 Bangumi 用户名，无法拉取收藏")
        }
        let endpoint = BangumiEndpoints.authMirrorDomain + "/v0/users/\(name)/collections"
        var collected: [RemoteCollection] = []
        var seen = Set<Int>()
        var offset = 0
        while true {
            let json = try await send(
                endpoint,
                method: "GET",
                query: [
                    URLQueryItem(name: "subject_type", value: "2"),
                    URLQueryItem(name: "limit", value: "\(limit)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                ],
                body: nil,
                requiresAuth: true
            )
            guard let page = json["data"].arrayValue else {
                throw NetworkError.decoding("Bangumi 收藏列表里没有 data 字段")
            }
            let total = json["total"].intValue ?? 0
            if total > 0, page.isEmpty, offset == 0 {
                throw NetworkError.decoding("Bangumi 说有 \(total) 条收藏，但第一页是空的")
            }
            for element in page {
                guard let item = RemoteCollection(element), item.type != 0 else { continue }
                if seen.insert(item.subjectID).inserted { collected.append(item) }
            }
            onProgress?("正在拉取 Bangumi 收藏", min(collected.count, total), total)
            offset += page.count
            if page.isEmpty || offset >= total { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        KazumiLog.network.notice("Bangumi: 拉取收藏 \(collected.count, privacy: .public) 条")
        return collected
    }

    /// 标记单集的四种结果。对应 bangumi_progress_service.dart 的 MarkResult。
    enum MarkOutcome: Sendable {
        case ok
        /// 番剧还没收藏（接口回 400）：要先收成「在看」再重试。
        case notCollected
        case unauthorized
        /// 这一集在 Bangumi 上不存在（404），重试也没用。
        case rejected
        case failed
    }

    /// 把一集在 Bangumi 上标为「看过」（`type = 2`）。
    ///
    /// 只给「自动标记看过」用：番剧本身还没收藏时接口会回 400，
    /// 调用方要先把番剧收成「在看」再试一次。
    static func markEpisodeWatched(episodeID: Int) async -> MarkOutcome {
        guard accessToken != nil else { return .unauthorized }
        let url = BangumiEndpoints.format(
            BangumiEndpoints.authMirrorDomain + BangumiEndpoints.setEpisode,
            [episodeID]
        )
        do {
            // **必须 PUT**：这条接口只认 PUT，POST 回 404（"This is default response…"）。
            // 之前写的是 post，于是每次都被当成「这一集不存在」丢掉，
            // 自动标记看过从来没成功过一次（LP 4744）。
            _ = try await put(url, body: .object(["type": .int(2)]), requiresAuth: true)
            return .ok
        } catch let error as NetworkError {
            if case let .badResponse(status, _, _) = error {
                switch status {
                case 200, 204: return .ok
                case 400: return .notCollected
                case 401, 403: return .unauthorized
                case 404: return .rejected
                default: return .failed
                }
            }
            KazumiLog.network.error(
                "Mark bangumi episode watched failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed
        } catch {
            KazumiLog.network.error(
                "Mark bangumi episode watched failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed
        }
    }

    /// 发出的请求究竟带没带令牌，只用于排查：只报是否带上与长度，绝不输出令牌本身。
    private static var authState: String {
        guard let token = accessToken, !token.isEmpty else { return "none" }
        return "bearer(\(token.count))"
    }
}
