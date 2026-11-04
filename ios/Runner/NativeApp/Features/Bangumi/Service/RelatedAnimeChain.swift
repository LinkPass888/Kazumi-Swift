//
//  RelatedAnimeChain.swift
//  Kazumi
//
//  1:1 移植 lib/modules/bangumi/bangumi_relation.dart 的
//  selectRelatedAnime / resolveRelatedAnimeChain。
//
//  原版详情页的「关联」不是把接口返回的关系原样铺开：
//    1. 先只保留 type == 2（动画）、去掉自己、按 id 去重；
//    2. 再沿着「前传 / 续集」逐层往上/往下走，最多 12 层、最多 20 次请求，
//       把整条主线都串起来；
//    3. 每个条目显示的关系名不是接口给的原文，而是**遍历出来的方向**
//       —— 所以「动画 / 书籍」这类原始标签会被换成「前传 / 续集」。
//
//  结果顺序：前传（由远及近）→ 续集（由近及远）→ 其余动画关联。
//

import Foundation

enum RelatedAnimeChain {
    /// 与 Dart 的 bangumiPrequelRelation / bangumiSequelRelation 一致。
    static let prequel = String(localized: "前传")
    static let sequel = String(localized: "续集")
    static let mainlineRelations: Set<String> = [prequel, sequel]

    private struct Node {
        let subjectID: Int
        let direction: String
    }

    /// 只保留动画、去掉自己、按 id 去重（对应 selectRelatedAnime）。
    static func selectRelatedAnime(
        _ relations: [BangumiRelationItem],
        currentSubjectID: Int
    ) -> [BangumiRelationItem] {
        var seen = Set<Int>()
        var result: [BangumiRelationItem] = []
        for relation in relations {
            let item = relation.item
            guard item.type == 2 else { continue }
            guard item.id != currentSubjectID else { continue }
            guard seen.insert(item.id).inserted else { continue }
            result.append(relation)
        }
        return result
    }

    /// 串出整条前传 / 续集主线（对应 resolveRelatedAnimeChain）。
    static func resolve(
        currentSubjectID: Int,
        maxDepth: Int = 12,
        maxFetchCount: Int = 20,
        fetchRelations: @Sendable (Int) async -> [BangumiRelationItem]
    ) async -> [BangumiRelationItem] {
        guard maxDepth >= 1, maxFetchCount >= 1 else { return [] }

        var fetchCount = 1
        let rootRelations = await fetchRelations(currentSubjectID)
        let directRelations = selectRelatedAnime(rootRelations, currentSubjectID: currentSubjectID)

        var relationByID: [Int: BangumiRelationItem] = [:]
        for relation in directRelations where relationByID[relation.item.id] == nil {
            relationByID[relation.item.id] = relation
        }

        var mainlineDirection: [Int: String] = [:]
        var layers: [String: [[BangumiRelationItem]]] = [prequel: [], sequel: []]
        var directLayers: [String: [BangumiRelationItem]] = [prequel: [], sequel: []]
        var scheduled = Set<Int>()
        var frontier: [Node] = []

        for relation in rootRelations {
            let item = relation.item
            let direction = relation.relation
            guard mainlineRelations.contains(direction) else { continue }
            guard item.type == 2, item.id != currentSubjectID else { continue }

            let display: BangumiRelationItem
            if let existing = relationByID[item.id] {
                display = existing
            } else {
                let created = BangumiRelationItem(relation: direction, item: item)
                relationByID[item.id] = created
                display = created
            }

            if mainlineDirection[item.id] == nil {
                mainlineDirection[item.id] = direction
                directLayers[direction, default: []].append(display)
            }
            if scheduled.insert(item.id).inserted {
                frontier.append(Node(subjectID: item.id, direction: direction))
            }
        }
        for direction in mainlineRelations {
            if let layer = directLayers[direction], !layer.isEmpty {
                layers[direction, default: []].append(layer)
            }
        }

        var depth = 1
        while !frontier.isEmpty, depth < maxDepth, fetchCount < maxFetchCount {
            var nextFrontier: [Node] = []
            var nextLayers: [String: [BangumiRelationItem]] = [prequel: [], sequel: []]

            let budget = maxFetchCount - fetchCount
            let nodes = Array(frontier.prefix(budget))
            var fetched: [[BangumiRelationItem]] = []
            for node in nodes {
                fetched.append(await fetchRelations(node.subjectID))
            }
            fetchCount += nodes.count

            for (index, node) in nodes.enumerated() {
                for relation in fetched[index] {
                    let item = relation.item
                    guard relation.relation == node.direction else { continue }
                    guard item.type == 2, item.id != currentSubjectID else { continue }

                    let display: BangumiRelationItem
                    if let existing = relationByID[item.id] {
                        display = existing
                    } else {
                        let created = BangumiRelationItem(relation: node.direction, item: item)
                        relationByID[item.id] = created
                        display = created
                    }

                    if mainlineDirection[item.id] == nil {
                        mainlineDirection[item.id] = node.direction
                        nextLayers[node.direction, default: []].append(display)
                    }
                    if scheduled.insert(item.id).inserted {
                        nextFrontier.append(Node(subjectID: item.id, direction: node.direction))
                    }
                }
            }
            for direction in mainlineRelations {
                if let layer = nextLayers[direction], !layer.isEmpty {
                    layers[direction, default: []].append(layer)
                }
            }
            frontier = nextFrontier
            depth += 1
        }

        var result: [BangumiRelationItem] = []
        for layer in (layers[prequel] ?? []).reversed() {
            result.append(contentsOf: layer)
        }
        for layer in layers[sequel] ?? [] {
            result.append(contentsOf: layer)
        }
        result.append(contentsOf: directRelations.filter { mainlineDirection[$0.item.id] == nil })
        return result
    }
}
