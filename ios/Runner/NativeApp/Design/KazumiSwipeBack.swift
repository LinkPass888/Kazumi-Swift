//
//  KazumiSwipeBack.swift
//  Kazumi
//
//  恢复系统原生的侧滑返回手势（从左缘右滑 `interactivePopGestureRecognizer`，
//  以及 iOS 26+ 内容区右滑 `interactiveContentPopGestureRecognizer`），并支持按需避开指定区域（如播放器画面区）。
//
//  播放页等页面使用了 `.toolbar(.hidden, for: .navigationBar)` 自绘顶栏，导航栏一隐藏，
//  UINavigationController 默认的交互返回代理就会拒绝触发侧滑返回。
//  这里在目标页面处于栈顶时按页面规则（是否启用、避让矩形）放行系统原生转场；
//  切到栈内其它普通页面时自动转发回 UIKit 原生默认代理，互不干扰。
//

import SwiftUI
import UIKit

struct KazumiSwipeBackEnabler: UIViewControllerRepresentable {
    var isEnabled: Bool = true
    /// 窗口坐标系（`.global`）下需要避让侧滑返回的区域（例如非全屏播放页顶部的播放器区域）。
    var excludedWindowRect: CGRect = .zero

    func makeUIViewController(context: Context) -> Enabler {
        let controller = Enabler()
        controller.isEnabled = isEnabled
        controller.excludedWindowRect = excludedWindowRect
        return controller
    }

    func updateUIViewController(_ uiViewController: Enabler, context: Context) {
        uiViewController.isEnabled = isEnabled
        uiViewController.excludedWindowRect = excludedWindowRect
        uiViewController.installIfNeeded()
    }

    /// 挂在页面上的空控制器，只负责把导航栈的侧滑手势接回来并同步当前页面的避让规则。
    @MainActor
    final class Enabler: UIViewController {
        var isEnabled: Bool = true
        var excludedWindowRect: CGRect = .zero

        init() {
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIfNeeded()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            installIfNeeded()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfNeeded()
        }

        func installIfNeeded() {
            guard let navigation = navigationController
                ?? parent?.navigationController
                ?? resolveNavigationController() else { return }
            KazumiSwipeBack.install(on: navigation, enabler: self)
        }

        func belongs(to topViewController: UIViewController?) -> Bool {
            guard let topViewController, viewIfLoaded?.window != nil else { return false }
            var cursor: UIViewController? = self
            while let current = cursor {
                if current === topViewController { return true }
                cursor = current.parent
            }
            return false
        }

        func shouldExclude(pointInWindow point: CGPoint, windowBounds: CGRect) -> Bool {
            guard !excludedWindowRect.isEmpty else { return false }
            let padded = excludedWindowRect.insetBy(dx: -2, dy: -2)
            if padded.contains(point) { return true }
            // 竖屏上下单栈下，播放器横跨整屏顶部：连同播放器上方的状态栏安全区一并避开，只允许下方选集/评论区侧滑返回。
            if excludedWindowRect.minX <= 2,
               excludedWindowRect.maxX >= windowBounds.width - 2,
               point.y <= excludedWindowRect.maxY + 2 {
                return true
            }
            return false
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

    static func install(
        on navigation: UINavigationController,
        enabler: KazumiSwipeBackEnabler.Enabler? = nil
    ) {
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

        if let enabler {
            coordinator.register(enabler)
        }
        coordinator.attachIfNeeded(to: navigation)
    }
}

@MainActor
final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    private struct WeakEnabler {
        weak var value: KazumiSwipeBackEnabler.Enabler?
    }

    /// 弱引用：代理被导航栈缓存，不能反过来把导航控制器吊住。
    weak var navigation: UINavigationController?
    private weak var originalEdgeDelegate: UIGestureRecognizerDelegate?
    private weak var originalContentDelegate: UIGestureRecognizerDelegate?
    private var enablers: [WeakEnabler] = []

    init(navigation: UINavigationController) {
        self.navigation = navigation
        super.init()
    }

    func register(_ enabler: KazumiSwipeBackEnabler.Enabler) {
        enablers.removeAll { $0.value == nil || $0.value === enabler }
        enablers.append(WeakEnabler(value: enabler))
    }

    func attachIfNeeded(to navigation: UINavigationController) {
        if let edgeGesture = navigation.interactivePopGestureRecognizer {
            if edgeGesture.delegate !== self {
                originalEdgeDelegate = edgeGesture.delegate
                edgeGesture.delegate = self
            }
            if !edgeGesture.isEnabled {
                edgeGesture.isEnabled = true
            }
        }

        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let contentGesture = navigation.interactiveContentPopGestureRecognizer
            if contentGesture.delegate !== self {
                originalContentDelegate = contentGesture.delegate
                contentGesture.delegate = self
            }
            if !contentGesture.isEnabled {
                contentGesture.isEnabled = true
            }
        }
        #endif
    }

    private func activeEnabler() -> KazumiSwipeBackEnabler.Enabler? {
        enablers.removeAll { $0.value == nil }
        guard let top = navigation?.topViewController else { return nil }
        return enablers.last { $0.value?.belongs(to: top) == true }?.value
    }

    private func fallbackDelegate(for gestureRecognizer: UIGestureRecognizer) -> UIGestureRecognizerDelegate? {
        if gestureRecognizer === navigation?.interactivePopGestureRecognizer {
            return originalEdgeDelegate
        }
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *),
           gestureRecognizer === navigation?.interactiveContentPopGestureRecognizer {
            return originalContentDelegate
        }
        #endif
        return originalEdgeDelegate
    }

    private func isContentPopGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return gestureRecognizer === navigation?.interactiveContentPopGestureRecognizer
        }
        #endif
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard let navigation else { return false }
        guard let enabler = activeEnabler() else {
            if let delegate = fallbackDelegate(for: gestureRecognizer),
               let result = delegate.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) {
                return result
            }
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }

        guard navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil,
              enabler.isEnabled else {
            return false
        }

        if let window = navigation.view.window {
            let point = touch.location(in: window)
            if enabler.shouldExclude(pointInWindow: point, windowBounds: window.bounds) {
                return false
            }
        }

        // 内容区全宽右滑不抢分段选择器、滑杆与开关的拖拽交互。
        if isContentPopGesture(gestureRecognizer) {
            var view = touch.view
            while let current = view {
                if current is UISlider
                    || current is UISegmentedControl
                    || current is UISwitch
                    || current is UITextField
                    || current is UITextView {
                    return false
                }
                view = current.superview
            }
        }

        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation else { return false }
        guard let enabler = activeEnabler() else {
            if let delegate = fallbackDelegate(for: gestureRecognizer),
               let result = delegate.gestureRecognizerShouldBegin?(gestureRecognizer) {
                return result
            }
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }

        guard navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil,
              enabler.isEnabled else {
            return false
        }

        if let window = navigation.view.window {
            let point = gestureRecognizer.location(in: window)
            if enabler.shouldExclude(pointInWindow: point, windowBounds: window.bounds) {
                return false
            }
        }

        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let translation = pan.translation(in: navigation.view)
            guard translation.x > 0, abs(translation.x) > abs(translation.y) else {
                return false
            }
        }

        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard activeEnabler() != nil else {
            return fallbackDelegate(for: gestureRecognizer)?
                .gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer)
                ?? false
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard activeEnabler() != nil else {
            return fallbackDelegate(for: gestureRecognizer)?
                .gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: otherGestureRecognizer)
                ?? false
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard activeEnabler() != nil else {
            return fallbackDelegate(for: gestureRecognizer)?
                .gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer)
                ?? false
        }
        if gestureRecognizer === navigation?.interactivePopGestureRecognizer,
           otherGestureRecognizer is UIPanGestureRecognizer,
           otherGestureRecognizer.view is UIScrollView {
            return true
        }
        return false
    }
}
