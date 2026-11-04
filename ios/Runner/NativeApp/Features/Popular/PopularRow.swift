//
//  PopularRow.swift
//  Kazumi
//
//  推荐页的一行「货架」。行数跟着数据走：哪一组取回 0 条，整行连标题一起不渲染
//  （Colo 规格 §5「空（某一行没数据）」），所以这里没有任何占位行。
//

import Foundation

/// 「更多」点进去是哪一页。每一行都有对应列表页（Ato 2739），
/// 没有列表页的行不放「更多」——点了没地方去比没有更糟。
enum PopularListSource: Hashable, Sendable {
    /// 趋势榜：next.bgm.tv，按 offset 续接。行名和点进去的列表页标题都叫「热门番组」
    /// （LP 3044 把行名从「本周热门」改成了这个）。
    case trending
    /// 本季新番：镜像季度接口，一次给全季。
    case season
    /// 综合排名（原名「评分最高」）：官方搜索按固定名次区间（不是随机名次）。
    case ranked
    /// 收藏榜：官方搜索按 heat（收藏人数）降序。
    case collected
    /// 顶栏菜单里选的标签。
    case tag(String)

    var title: String {
        switch self {
        case .trending: String(localized: "热门番组")
        case .season: String(localized: "本季新番")
        case .ranked: String(localized: "综合排名")
        case .collected: String(localized: "收藏榜")
        case .tag(let tag): tag
        }
    }
}

/// 一行货架。
struct PopularRow: Identifiable, Sendable {
    /// 稳定 id：用数据源而不是行号，重新加载后行的身份不会错位。
    var id: String
    var title: String
    var items: [PopularPoster]
    /// 这一行的「更多」去哪；nil 表示没有列表页，不放那颗字。
    var list: PopularListSource?

    init(id: String, title: String, items: [PopularPoster], list: PopularListSource?) {
        self.id = id
        self.title = title
        self.items = items
        self.list = list
    }
}
