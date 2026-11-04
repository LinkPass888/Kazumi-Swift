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

    private init() {}

    /// 交出控制器，由根层弹面板。
    func present(
        controller: InfoController,
        onPlay: @escaping (String, SearchItem) -> Void,
        onOpenRuleShop: @escaping () -> Void
    ) {
        self.controller = controller
        self.onPlay = onPlay
        self.onOpenRuleShop = onOpenRuleShop
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
