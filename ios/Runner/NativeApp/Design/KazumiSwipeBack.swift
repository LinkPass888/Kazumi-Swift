//
//  KazumiSwipeBack.swift
//  Kazumi
//
//  恢复系统「从屏幕左缘右滑返回」的手势。
//
//  详情页用了 `.toolbar(.hidden, for: .navigationBar)` 自绘顶栏，导航栏一隐藏，
//  UINavigationController 会连带把 interactivePopGestureRecognizer 关掉
//  （它的 delegate 只看导航栏返回按钮），于是只剩自定义返回键能退出。
//  这里把代理换成自己的实现：只要栈里还有上一页就允许侧滑，栈底则不允许
//  —— 直接置 nil 会在根页面把导航栈卡死。
//
//  两个容易踩的坑，这里都绕开了：
//   1. 手势代理是 weak 的。页面弹出后如果代理对象跟着释放，代理就回落成 nil，
//      手势退回到「没人管」的默认状态（根页面也能滑，会把导航栈卡死）。
//      因此代理对象按导航控制器缓存，导航栈活着它就活着。
//   2. 不能从 `gestureRecognizer.view?.window` 沿 next 找导航控制器：
//      UIWindow 的 next 直接指向 UIApplication，永远走不到 UINavigationController，
//      那样写会让手势永远不开始。这里改由页面自己在响应链上解析出导航控制器，
//      再交给代理，代理只持有它的弱引用。
//

import SwiftUI
import UIKit

struct KazumiSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Enabler()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    /// 挂在页面上的空控制器，只负责把导航栈的侧滑手势接回来。
    private final class Enabler: UIViewController {
        init() {
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        private func install() {
            // 刚挂到父控制器上时 navigationController 可能还是 nil，沿父控制器
            // 与响应链各兜底找一次。
            guard let navigation = navigationController
                ?? parent?.navigationController
                ?? resolveNavigationController() else { return }
            KazumiSwipeBack.install(on: navigation)
        }

        /// 沿响应链往上找最近的 UINavigationController。
        private func resolveNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let navigation = current as? UINavigationController { return navigation }
                responder = current.next
            }
            return nil
        }
    }
}

/// 侧滑返回手势的接管入口。
///
/// 代理对象按导航控制器缓存：`gesture.delegate` 是 weak，只有被这里强引用着，
/// 页面来回切换时才不会退回到「导航栏隐藏即禁用」的系统默认状态。
@MainActor
enum KazumiSwipeBack {
    private static var coordinators: [ObjectIdentifier: SwipeBackCoordinator] = [:]

    /// 把 `navigation` 的侧滑返回手势接到我们的代理上（可重复调用）。
    static func install(on navigation: UINavigationController) {
        guard let gesture = navigation.interactivePopGestureRecognizer else { return }

        // 顺手清掉已经销毁的导航控制器留下的条目（Tab 只有几个，不会堆积）。
        coordinators = coordinators.filter { $0.value.navigation != nil }

        let key = ObjectIdentifier(navigation)
        let coordinator: SwipeBackCoordinator
        if let existing = coordinators[key] {
            coordinator = existing
        } else {
            let created = SwipeBackCoordinator(navigation: navigation)
            coordinators[key] = created
            coordinator = created
        }

        if gesture.delegate !== coordinator {
            gesture.delegate = coordinator
        }
        if !gesture.isEnabled {
            gesture.isEnabled = true
        }
    }
}

/// 只回答「这次侧滑该不该开始」，其余行为保持系统默认。
final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    /// 弱引用：代理被导航栈缓存，不能反过来把导航控制器吊住。
    weak var navigation: UINavigationController?

    init(navigation: UINavigationController) {
        self.navigation = navigation
        super.init()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation else { return false }
        // 栈底没有上一页，侧滑不应触发（否则会把导航栈卡死）。
        guard navigation.viewControllers.count > 1 else { return false }
        // 已有转场在进行时不再开始新的返回，避免连续快速侧滑打乱栈。
        guard navigation.transitionCoordinator == nil else { return false }
        // 列表里明显偏竖直的拖动留给列表滚动，只有横向拖动才算返回。
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let translation = pan.translation(in: gestureRecognizer.view)
            if abs(translation.y) > abs(translation.x) { return false }
        }
        return true
    }
}
