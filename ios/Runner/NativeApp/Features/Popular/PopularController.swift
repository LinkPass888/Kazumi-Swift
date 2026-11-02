//
//  PopularController.swift
//  Kazumi
//
//  推荐页（竖版焦点区 + 横向货架）的数据装配。
//
//  四行固定（Ato 2739 / 2820）：热门番组 / 本季新番 / 综合排名 / 收藏榜，每行 10 条
//  （LP 2740：一个分组十条差不多，滑不到的点「更多」）。
//  焦点区吃第一行的前 5 条，不单独发请求。
//
//  取数口径（LP 2733 / Ato 2734 / LP 2827）：
//  * 进页面先把缓存画出来，再后台刷新，冷启动不空页等网；
//  * 没过期的行不重新拉（热门番组 7 天，其余三行 15 天）；
//  * 这页没有下拉刷新（LP 2823 / Colo 2824）：各行只按自己的过期时间换新。
//

import Foundation
import Observation

@MainActor
@Observable
final class PopularController {
    /// 每行条数。LP 定的「一个分组十条」。
    static let rowSize = 10
    /// 焦点区最多几张。
    static let heroLimit = 5

    private(set) var rows: [PopularRow] = []
    /// 首屏还在等第一批数据（缓存和网络都还没结果）。
    private(set) var isLoading = true
    /// 四行全空且网络也失败。
    private(set) var isFailed = false

    /// 焦点区那几张：热门番组的前 5 条。
    ///
    /// 单独存一份而不是从第一行取：热门番组那行要把这几部剔掉（LP 2809），
    /// 剔完之后焦点区就没法再从行里取到自己了。
    private(set) var heroItems: [PopularPoster] = []

    private let cache = PopularRowCache.shared
    /// 详情缓存（焦点区补简介复用这份，不另开一套）。
    private let subjectCache = BangumiSubjectCache.shared

    /// 四行的定义：键名、标题、过期时间。
    private struct RowSpec {
        let name: String
        let title: String
        let ttl: TimeInterval
        let list: PopularListSource
    }

    private var specs: [RowSpec] {
        [
            // LP 3044：这一行改名「热门番组」，原来挂在封面大标题上的标签菜单也挪到它头上。
            RowSpec(name: "trending", title: String(localized: "热门番组"), ttl: PopularRowCache.TTL.fast, list: .trending),
            RowSpec(name: "season", title: String(localized: "本季新番"), ttl: PopularRowCache.TTL.slow, list: .season),
            RowSpec(name: "ranked", title: String(localized: "综合排名"), ttl: PopularRowCache.TTL.slow, list: .ranked),
            // 收藏数变得慢，跟综合排名同档走慢缓存（Ato 2820）。
            RowSpec(name: "collected", title: String(localized: "收藏榜"), ttl: PopularRowCache.TTL.slow, list: .collected),
        ]
    }

    /// 某一行的缓存键（带镜像来源）。
    ///
    /// 本季新番、综合排名、收藏榜都带季度标签（LP 2983）：换季那一刻键就变了，
    /// 旧键自然失效、自动重取一次。热门番组不带——它本来就是 7 天一轮。
    private func cacheKey(for spec: RowSpec) -> String {
        let seasonScoped = spec.name == "season" || spec.name == "ranked" || spec.name == "collected"
        return PopularRowCache.key(
            spec.name,
            source: PopularRowCache.currentSource,
            extra: seasonScoped ? PopularRowCache.currentSeasonTag() : nil
        )
    }

    /// 用缓存把页面先画出来。返回是否画到了东西。
    @discardableResult
    func paintFromCache() -> Bool {
        var painted: [PopularRow] = []
        for spec in specs {
            guard let items = cache.items(for: cacheKey(for: spec)), !items.isEmpty else { continue }
            painted.append(makeRow(spec, items: items))
        }
        guard !painted.isEmpty else { return false }
        rows = painted
        isLoading = false
        return true
    }

    /// 刷新：没过期的行不重新拉，已经画出来的行保持原样，页面不闪。
    func load() async {
        let specs = self.specs
        let stale = specs.filter { !cache.isFresh(cacheKey(for: $0), ttl: $0.ttl) }
        guard !stale.isEmpty else {
            isLoading = false
            isFailed = rows.isEmpty
            // 四行都在缓存期内时上面就返回了，这里也得补一次焦点区简介，
            // 否则第二次冷启动永远拿不到简介（缓存里那份本来就没存）。
            if let hero = heroItems.first {
                await enrichHero(hero.id)
            }
            return
        }

        // 四条并行拉，谁先回来都不影响别人。
        async let trending = Self.fetchTrending()
        async let season = Self.fetchSeason()
        async let ranked = Self.fetchRanked()
        async let collected = Self.fetchCollected()
        let fetched = await (trending: trending, season: season, ranked: ranked, collected: collected)

        let results: [String: [PopularPoster]] = [
            "trending": fetched.trending,
            "season": fetched.season,
            "ranked": fetched.ranked,
            "collected": fetched.collected,
        ]

        var updated: [PopularRow] = []
        for spec in specs {
            let key = cacheKey(for: spec)
            let needsFetch = stale.contains { $0.name == spec.name }
            if needsFetch, let fresh = results[spec.name], !fresh.isEmpty {
                cache.store(fresh, for: key)
                updated.append(makeRow(spec, items: fresh))
            } else if let cached = cache.items(for: key), !cached.isEmpty {
                // 拉失败或本轮不用拉：有缓存就继续用旧的，别把已经画出来的行弄没。
                updated.append(makeRow(spec, items: cached))
            }
        }

        rows = updated
        isLoading = false
        isFailed = updated.isEmpty

        // 焦点区那一张补简介（Ato 2761 破例）：只为当前这张发一次详情请求，
        // 而且先读详情页那份 24 小时缓存，缓存里有就一次请求都不发。
        if let hero = heroItems.first {
            await enrichHero(hero.id)
        }
    }

    /// 把一组条目装成一行。
    ///
    /// 热门番组那行要把焦点区露过面的几条剔掉（LP 2809，按 bangumi id 去重）：
    /// 焦点区吃这份清单的前 5 条，那一行只放剩下的，所以这一行取数要一次多要 5 条，
    /// 剔完才还是满的 10 条。
    private func makeRow(_ spec: RowSpec, items: [PopularPoster]) -> PopularRow {
        guard spec.name == "trending" else {
            return PopularRow(id: spec.name, title: spec.title, items: items, list: spec.list)
        }
        heroItems = Array(items.prefix(Self.heroLimit))
        let heroIDs = Set(heroItems.map(\.id))
        return PopularRow(
            id: spec.name,
            title: spec.title,
            items: Array(items.filter { !heroIDs.contains($0.id) }.prefix(Self.rowSize)),
            list: spec.list
        )
    }

    // MARK: - 焦点区简介

    /// 已经从详情缓存里读过的条目，不重复读。
    private var enrichedHeroIDs: Set<Int> = []

    /// 给焦点区的某一张补上简介、年份、话数。
    ///
    /// 趋势榜给的是精简条目（无简介、无日期、无话数），完整信息只在详情接口里。
    /// 顺序是：详情缓存 → 没有才发一次请求。命中缓存时冷启动零额外请求。
    func enrichHero(_ id: Int) async {
        guard !enrichedHeroIDs.contains(id) else { return }
        enrichedHeroIDs.insert(id)

        // 缓存里有就直接用（详情页那份，24 小时有效）。
        if let cached = subjectCache.item(for: id), !cached.summary.isEmpty {
            applyHeroDetail(cached)
            return
        }
        guard let fresh = await BangumiAPI.info(id: id) else { return }
        applyHeroDetail(fresh)
    }

    /// 把详情里的完整信息换回焦点区那一张，其他字段（封面地址）保持不动。
    private func applyHeroDetail(_ item: BangumiItem) {
        guard let itemIndex = heroItems.firstIndex(where: { $0.id == item.id }) else { return }
        let old = heroItems[itemIndex]
        var enriched = PopularPoster(item)
        if enriched.imageURL.isEmpty { enriched = PopularPoster(
            id: old.id,
            name: old.name,
            nameCn: old.nameCn,
            imageURL: old.imageURL,
            summary: item.summary,
            airDate: item.airDate,
            rating: item.ratingScore,
            totalEpisodes: item.eps
        ) }
        guard enriched != old else { return }
        heroItems[itemIndex] = enriched
    }

    // MARK: - 取数（不碰 UI 状态，方便并行）

    private static func fetchTrending() async -> [PopularPoster] {
        // 多要 5 条：焦点区拿走前 5，下面那行剔掉它们之后才还是满的 10 条。
        let limit = rowSize + heroLimit
        let items = BangumiAcceleration.isMirrorEnabled
            ? await BangumiAPI.mirrorPopular(limit: limit, offset: 0)
            : await BangumiAPI.trends(limit: limit, offset: 0)
        return (items ?? []).map(PopularPoster.init)
    }

    private static func fetchSeason() async -> [PopularPoster] {
        let range = AnimeSeason.seasonRange(for: Date())
        let groups = await BangumiAPI.mirrorSeasonCalendar(start: range.start, end: range.end)
        // 接口按周一到周日分 7 组，铺一行就按星期顺序平铺。
        let flat = groups.flatMap { $0 }
        return flat.prefix(rowSize).map(PopularPoster.init)
    }

    private static func fetchRanked() async -> [PopularPoster] {
        let items = await BangumiAPI.ranked(limit: rowSize, offset: 0)
        return (items ?? []).map(PopularPoster.init)
    }

    private static func fetchCollected() async -> [PopularPoster] {
        let items = await BangumiAPI.collected(limit: rowSize, offset: 0)
        return (items ?? []).map(PopularPoster.init)
    }
}
