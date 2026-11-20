//
//  SourceSheetCoordinator.swift
//  Kazumi
//
//  选源面板挂在哪一层：以前挂在推荐页的轮播那一页上。点「开始观看」时把
//  `isPresented` 置真，系统要先重排那一页（整页大图、轮播克隆页都在），
//  面板的 body 要 3.6 秒才第一次跑——2026-10-28 量的 r0 / b3610 / a3631。
//
//  现在改成挂在根层：按钮只把控制器和两个回调交出来，根层去弹。根层没有
//  轮播那种重页面，弹之前没什么可重排的（Colo 2026-10-28「挪到 App 根层」）。
//

import SwiftUI

@MainActor
@Observable
final class SourceSheetCoordinator {
    static let shared = SourceSheetCoordinator()

    /// 这一次要弹的面板用哪个控制器。
    private(set) var controller: InfoController?
    /// 根层拿它决定弹不弹。
    var isPresented = false
    /// 点了某条结果：由交出控制器的那一页决定往哪儿推进。
    private(set) var onPlay: ((String, SearchItem) -> Void)?
    /// 空规则时点「去规则仓库添加」。
    private(set) var onOpenRuleShop: (() -> Void)?

    /// 记录因播放失败主动点「返回选源」时需要重弹面板的番剧 ID（按 bangumiID 隔离，避免跨 Tab 误弹）。
    private(set) var reopenSourcesBangumiID: Int?

    /// 兼容属性：是否存在待重弹选源的标记。
    var shouldReopenSourcesOnReturn: Bool {
        get { reopenSourcesBangumiID != nil }
        set { if !newValue { reopenSourcesBangumiID = nil } }
    }

    /// 按 `bangumiID` 缓存最近使用过的 `InfoController`（含已搜结果与别名，U3）。
    private var cachedControllers: [Int: InfoController] = [:]
    private var cacheOrder: [Int] = []
    private let maxCachedControllers = 5

    func markFailedReturnToSources(bangumiID: Int) {
        reopenSourcesBangumiID = bangumiID
    }

    func clearFailedReturnToSources() {
        reopenSourcesBangumiID = nil
    }

    /// 仅当目标番剧 ID 匹配时消费重弹标记，防止非来源页或隐藏 Tab 误消费。
    func consumeShouldReopenSourcesOnReturn(for bangumiID: Int) -> Bool {
        guard reopenSourcesBangumiID == bangumiID else { return false }
        reopenSourcesBangumiID = nil
        return true
    }

    /// 外部跳转等场景统一清空重弹标记。
    func consumeShouldReopenSourcesOnReturn() -> Bool {
        let value = reopenSourcesBangumiID != nil
        reopenSourcesBangumiID = nil
        return value
    }

    func cacheController(_ controller: InfoController) {
        let id = controller.item.id
        cachedControllers[id] = controller
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > maxCachedControllers {
            let evicted = cacheOrder.removeFirst()
            cachedControllers.removeValue(forKey: evicted)
        }
    }

    func cachedController(for bangumiID: Int) -> InfoController? {
        guard let hit = cachedControllers[bangumiID] else { return nil }
        cacheOrder.removeAll { $0 == bangumiID }
        cacheOrder.append(bangumiID)
        return hit
    }

    private init() {}

    /// 交出控制器，由根层弹面板。
    func present(
        controller: InfoController,
        onPlay: @escaping (String, SearchItem) -> Void,
        onOpenRuleShop: @escaping () -> Void
    ) {
        cacheController(controller)
        self.controller = controller
        self.onPlay = onPlay
        self.onOpenRuleShop = onOpenRuleShop
        reopenSourcesBangumiID = nil
        isPresented = true
    }

    /// 面板已经关掉（或者那一页不在了）：把回调一起放掉，别抓着上一页的状态。
    func dismiss() {
        isPresented = false
    }

    /// 关掉之后清干净。关闭动画走完再调，免得面板半路没了控制器。
    func clearIfNeeded() {
        guard !isPresented else { return }
        controller = nil
        onPlay = nil
        onOpenRuleShop = nil
    }
}
