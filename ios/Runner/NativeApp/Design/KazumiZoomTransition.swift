//
//  KazumiZoomTransition.swift
//  Kazumi
//
//  iOS 18 起的共享元素缩放转场（`.matchedTransitionSource` + `.navigationTransition(.zoom)`）：
//   * 卡片侧用 `kazumiZoomSource(id:namespace:)` 登记转场源，ID 统一取番剧 id；
//   * 详情页侧用 `kazumiZoomDestination(id:namespace:)` 绑定同一个 ID 与命名空间，
//     点击后卡片会原地放大成详情页，返回时再收回去；
//   * 两边都读 `accessibilityReduceMotion`：开启「减弱动态效果」时完全不加这两个修饰符，
//     退化成系统默认的横向推入，避免大面积缩放动画引起不适；
//   * 命名空间传 nil 时同样什么也不加，这样没有拿到命名空间的调用点
//     （预览、测试、未来新增的入口）不会因为缺少源视图而出现异常表现；
//   * 命名空间里找不到同 ID 的源视图时（比如详情页是从播放页推入的），
//     系统自动回落到默认转场，不需要额外兜底。
//
//  命名空间按「导航栈」分配（见 KazumiTabShell.KazumiNavigationStack）：
//  同一个 Tab 里的根页面、搜索结果页、详情页共用一份，跨 Tab 互不影响。
//

import SwiftUI

/// 卡片侧的转场源。
struct KazumiZoomSourceModifier: ViewModifier {
    let id: Int
    let namespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion, namespace != nil {
            content
        } else if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// 详情页侧的转场目的地。
struct KazumiZoomDestinationModifier: ViewModifier {
    let id: Int
    let namespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    /// 把当前视图登记成缩放转场的源（点击后展开成详情页的那张卡片）。
    func kazumiZoomSource(id: Int, namespace: Namespace.ID?) -> some View {
        modifier(KazumiZoomSourceModifier(id: id, namespace: namespace))
    }

    /// 给推入的详情页绑定缩放转场，源 ID 与卡片侧保持一致。
    func kazumiZoomDestination(id: Int, namespace: Namespace.ID?) -> some View {
        modifier(KazumiZoomDestinationModifier(id: id, namespace: namespace))
    }
}
