//
//  PopularListReloadTests.swift
//  RunnerTests
//
//  #29：推荐页「更多」列表下拉之后进详情页，左滑返回有概率回到列表顶部。
//  这页的 `.task` 在视图重新出现时会再跑一次，而取第一页原来无条件
//  `items.removeAll()` —— 第一页只要不是立刻回来，网格先空一帧，ScrollView
//  的偏移就被夹回 0。这里钉住规则：列表里已经有内容就不重新取第一页。
//

import Testing
@testable import Runner

struct PopularListReloadTests {
    @Test("空列表（首次进入或上次失败）要取数")
    func emptyListLoadsFirstPage() {
        #expect(PopularListScreen.Controller.shouldReloadFirstPage(itemCount: 0))
    }

    @Test("已经有内容时返回上一页不再重取，滚动位置也就不会被清掉")
    func populatedListKeepsItsContent() {
        #expect(!PopularListScreen.Controller.shouldReloadFirstPage(itemCount: 1))
        #expect(!PopularListScreen.Controller.shouldReloadFirstPage(itemCount: 24))
    }
}