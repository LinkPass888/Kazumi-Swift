//
//  SearchController.swift
//  Kazumi
//
//  1:1 翻译 lib/pages/search/search_controller.dart 的核心路径：
//  * 每页 20 条，最多连续自动翻 3 页补齐结果；
//  * id: 语法直接按 ID 取详情，只有一条结果；
//  * 代数（generation）机制丢弃过期响应，避免快速改词时串结果。
//

import Observation

@MainActor
@Observable
final class SearchController {
    static let pageSize = 20
    static let maxPagesPerSearch = 3

    private var searchOffset = 0
    private var searchGeneration = 0

    private(set) var hasMoreSearchResults = true
    private(set) var isLoading = false
    private(set) var isTimeOut = false
    private(set) var bangumiList: [BangumiItem] = []

    /// 对应 searchBangumi：type == "add" 时续页，否则重新搜。
    func searchBangumi(_ input: String, type: String = "add") async {
        if type == "add" && (isLoading || !hasMoreSearchResults) { return }
        let generation: Int
        if type == "add" {
            generation = searchGeneration
        } else {
            searchGeneration += 1
            generation = searchGeneration
        }

        isLoading = true
        isTimeOut = false
        if type != "add" {
            bangumiList = []
            searchOffset = 0
            hasMoreSearchResults = true
        }
        guard generation == searchGeneration else { return }

        let filterState = SearchParser(input).toFilterState()
        if let id = Int(filterState.id), !filterState.id.isEmpty {
            let item = await BangumiAPI.info(id: id)
            guard generation == searchGeneration else { return }
            if let item { bangumiList = [item] }
            hasMoreSearchResults = false
            isLoading = false
            isTimeOut = bangumiList.isEmpty
            return
        }

        var pagesFetched = 0
        repeat {
            let page = await BangumiAPI.search(
                keyword: filterState.keyword,
                tags: filterState.tags,
                limit: Self.pageSize,
                offset: searchOffset,
                sort: filterState.sort,
                airDateRange: filterState.effectiveDateRange.map { [$0.start, $0.end] },
                rankFilter: filterState.rankRange.map { range in
                    var filter: [String] = []
                    if let min = range.min { filter.append(">=\(min)") }
                    if let max = range.max { filter.append("<=\(max)") }
                    return filter
                },
                scoreFilter: filterState.scoreRange.map { range in
                    var filter: [String] = []
                    if let min = range.min { filter.append(">=\(min)") }
                    if let max = range.max { filter.append("<=\(max)") }
                    return filter
                },
                weekdays: filterState.weekdays
            )
            guard generation == searchGeneration else { return }
            guard let page else { break }
            pagesFetched += 1
            searchOffset += page.rawCount
            hasMoreSearchResults = page.rawCount == Self.pageSize
            bangumiList.append(contentsOf: page.items)
            // 原实现会连续补齐到至少一页可见结果。
            if !bangumiList.isEmpty || !hasMoreSearchResults { break }
        } while pagesFetched < Self.maxPagesPerSearch

        isLoading = false
        isTimeOut = bangumiList.isEmpty
    }

    func clear() {
        searchGeneration += 1
        bangumiList = []
        searchOffset = 0
        hasMoreSearchResults = true
        isTimeOut = false
        isLoading = false
    }
}
