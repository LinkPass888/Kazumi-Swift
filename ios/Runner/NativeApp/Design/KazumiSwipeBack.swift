//
//  KazumiSwipeBack.swift
//  Kazumi
//
//  恢复系统原生的侧滑返回手势（从左缘右滑 `interactivePopGestureRecognizer`，
//  以及 iOS 26+ 内容区右滑 `interactiveContentPopGestureRecognizer`），并支持按需避开指定窗口区域（如播放器画面区）。
//
//  播放页使用了 `.toolbar(.hidden, for: .navigationBar)` 自绘顶栏：
//  1. push 转场完成那一拍，UINavigationController 会因为导航栏隐藏而把两个交互返回手势的
//     `isEnabled` 静默置回 `false`（且该内部标志位不触发 KVO）；
//  2. 这里使用透明无拦截的 `UIView` 探针（`point(inside:with:)` 恒返回 `false`，绝不吞任何触摸），
//     在每次 `UIWindow.hitTest` 阶段——即 UIKit 检查手势 `isEnabled` 之前——同步把返回手势重新打开，
//     并在转场结束回调与布局阶段双重兜底；
//  3. 通过 `probeView.isDescendant(of: topViewController.view)` 精确核对栈顶身份，
//     同时实现 `shouldBeRequiredToFailBy` 让竖向 `ScrollView`（选集网格 / 评论列表）礼让横向返回手势。
//

import SwiftUI
import UIKit

/// 读取视图在真实 `UIWindow` 坐标系下的矩形（与 `UITouch.location(in: window)` 完全同源）。
struct KazumiWindowRectReader: UIViewRepresentable {
    var onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> ProbeRectView {
        let view = ProbeRectView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onRectChange = onChange
        return view
    }

    func updateUIView(_ uiView: ProbeRectView, context: Context) {
        uiView.onRectChange = onChange
        uiView.reportIfNeeded()
    }

    @MainActor
    final class ProbeRectView: UIView {
        var onRectChange: ((CGRect) -> Void)?
        private var lastReported: CGRect = .null

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportIfNeeded()
        }

        func reportIfNeeded() {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            let rectInWindow = convert(bounds, to: nil)
            guard rectInWindow != lastReported else { return }
            lastReported = rectInWindow
            onRectChange?(rectInWindow)
        }
    }
}

struct KazumiSwipeBackEnabler: UIViewRepresentable {
    var isEnabled: Bool = true
    /// `UIWindow` 坐标系下需要避让侧滑返回的区域（例如非全屏播放页的播放器画面区）。
    var excludedWindowRect: CGRect = .zero

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isEnabled = isEnabled
        view.excludedWindowRect = excludedWindowRect
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.isEnabled = isEnabled
        uiView.excludedWindowRect = excludedWindowRect
        uiView.syncIfNeeded()
    }

    /// 挂在页面背景里的零拦截探针视图：
    /// `point(inside:with:)` 永远返回 `false`（不参与命中、不拦截点击或滑动），
    /// 但在手指触屏做 `hitTest` 的第一时间先把被隐藏导航栏关掉的系统返回手势重新打开。
    @MainActor
    final class ProbeView: UIView {
        var isEnabled: Bool = true
        var excludedWindowRect: CGRect = .zero
        private weak var cachedNavigation: UINavigationController?
        private weak var cachedCoordinator: SwipeBackCoordinator?
        private weak var hookedTransitionCoordinator: (any UIViewControllerTransitionCoordinator)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            // 轻量快路径：直接复用已缓存的 navigation/coordinator 恢复手势开关，
            // 不再每次命中测试都遍历响应链或重建协调器字典。
            if let navigation = cachedNavigation, let coordinator = cachedCoordinator {
                coordinator.attachIfNeeded(to: navigation)
            }
            return false
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                cachedNavigation = nil
                cachedCoordinator = nil
                hookedTransitionCoordinator = nil
                return
            }
            installAndSync()
            // push 动画结束时 UINavigationController 会关一次 isEnabled，这里跨帧补两次确保常开。
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                self?.syncIfNeeded()
                try? await Task.sleep(for: .milliseconds(350))
                self?.syncIfNeeded()
            }
        }

        func syncIfNeeded() {
            guard window != nil else { return }
            if let navigation = cachedNavigation, let coordinator = cachedCoordinator {
                coordinator.attachIfNeeded(to: navigation)
            } else {
                installAndSync()
            }
        }

        func installAndSync() {
            guard window != nil else { return }
            guard let navigation = cachedNavigation ?? resolveNavigationController() else { return }
            cachedNavigation = navigation
            let coordinator = KazumiSwipeBack.install(on: navigation, probe: self)
            cachedCoordinator = coordinator
            if let transition = navigation.transitionCoordinator,
               transition !== hookedTransitionCoordinator {
                hookedTransitionCoordinator = transition
                transition.animate(alongsideTransition: nil) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncIfNeeded()
                    }
                }
            }
        }

        func belongs(to topViewController: UIViewController?) -> Bool {
            guard let topView = topViewController?.view, window != nil else { return false }
            return isDescendant(of: topView)
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

        private func resolveNavigationController() -> UINavigationController? {
            var responder: UIResponder? = superview
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    return navigation
                }
                if let controller = current as? UIViewController,
                   let navigation = controller.navigationController {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}

/// 侧滑返回手势的接管入口。
@MainActor
enum KazumiSwipeBack {
    private static var coordinators: [ObjectIdentifier: SwipeBackCoordinator] = [:]

    @discardableResult
    static func install(
        on navigation: UINavigationController,
        probe: KazumiSwipeBackEnabler.ProbeView? = nil
    ) -> SwipeBackCoordinator {
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

        if let probe {
            coordinator.register(probe)
        }
        coordinator.attachIfNeeded(to: navigation)
        return coordinator
    }
}

@MainActor
final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    private struct WeakProbe {
        weak var value: KazumiSwipeBackEnabler.ProbeView?
    }

    weak var navigation: UINavigationController?
    private weak var originalEdgeDelegate: UIGestureRecognizerDelegate?
    private weak var originalContentDelegate: UIGestureRecognizerDelegate?
    private var probes: [WeakProbe] = []

    init(navigation: UINavigationController) {
        self.navigation = navigation
        super.init()
    }

    func register(_ probe: KazumiSwipeBackEnabler.ProbeView) {
        probes.removeAll { $0.value == nil || $0.value === probe }
        probes.append(WeakProbe(value: probe))
    }

    func attachIfNeeded(to navigation: UINavigationController) {
        if let edgeGesture = navigation.interactivePopGestureRecognizer {
            if let existing = edgeGesture.delegate, existing !== self {
                originalEdgeDelegate = existing
            }
            if edgeGesture.delegate !== self {
                edgeGesture.delegate = self
            }
            if !edgeGesture.isEnabled {
                edgeGesture.isEnabled = true
            }
        }

        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *),
           let contentGesture = navigation.interactiveContentPopGestureRecognizer {
            if let existing = contentGesture.delegate, existing !== self {
                originalContentDelegate = existing
            }
            if contentGesture.delegate !== self {
                contentGesture.delegate = self
            }
            if !contentGesture.isEnabled {
                contentGesture.isEnabled = true
            }
        }
        #endif
    }

    private func activeProbe() -> KazumiSwipeBackEnabler.ProbeView? {
        probes.removeAll { $0.value == nil }
        guard let top = navigation?.topViewController else { return nil }
        return probes.last { $0.value?.belongs(to: top) == true }?.value
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
        guard let probe = activeProbe() else {
            if let delegate = fallbackDelegate(for: gestureRecognizer),
               let result = delegate.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) {
                return result
            }
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }

        guard navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil,
              probe.isEnabled else {
            return false
        }

        if let window = navigation.view.window {
            let point = touch.location(in: window)
            if probe.shouldExclude(pointInWindow: point, windowBounds: window.bounds) {
                return false
            }
        }

        // 内容区右滑不抢分段选择器、按钮、滑杆、输入框的点击；左边缘屏幕侧滑不受影响。
        if isContentPopGesture(gestureRecognizer) {
            var view = touch.view
            while let current = view {
                if current is UIControl
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
        guard let probe = activeProbe() else {
            if let delegate = fallbackDelegate(for: gestureRecognizer),
               let result = delegate.gestureRecognizerShouldBegin?(gestureRecognizer) {
                return result
            }
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }

        guard navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil,
              probe.isEnabled else {
            return false
        }

        if let window = navigation.view.window {
            let point = gestureRecognizer.location(in: window)
            if probe.shouldExclude(pointInWindow: point, windowBounds: window.bounds) {
                return false
            }
        }

        if isContentPopGesture(gestureRecognizer),
           let pan = gestureRecognizer as? UIPanGestureRecognizer {
            // 内容区全宽右滑用实时速度判定方向，避免把列表竖向滚动误判为返回，
            // 同时避免起手瞬间 translation 尚未累积导致误拒。
            let velocity = pan.velocity(in: gestureRecognizer.view)
            if velocity.x <= 0 || abs(velocity.y) >= abs(velocity.x) {
                return false
            }
        } else if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            // 左边缘 UIScreenEdgePanGestureRecognizer 自身已完成左缘横向识别，仅排除向左回退。
            let velocity = pan.velocity(in: gestureRecognizer.view)
            if velocity.x < 0 {
                return false
            }
        }

        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let navigation else { return false }
        guard let probe = activeProbe() else {
            if let delegate = fallbackDelegate(for: gestureRecognizer),
               let result = delegate.gestureRecognizer?(
                   gestureRecognizer,
                   shouldBeRequiredToFailBy: otherGestureRecognizer
               ) {
                return result
            }
            return false
        }
        guard probe.isEnabled else { return false }

        // 左边缘返回手势优先于内部所有滑动手势（与系统原生导航栏可见时一致）。
        if gestureRecognizer === navigation.interactivePopGestureRecognizer {
            return otherGestureRecognizer is UIPanGestureRecognizer
        }

        // 内容区右滑返回优先于仅竖向滚动的 ScrollView（如选集网格、评论列表），
        // 但不抢横向滚动条（如标签栏、操作胶囊横滑区）。
        if isContentPopGesture(gestureRecognizer),
           let scrollView = otherGestureRecognizer.view as? UIScrollView {
            let scrollsHorizontally = scrollView.alwaysBounceHorizontal
                || scrollView.contentSize.width > scrollView.bounds.width + 1
            return !scrollsHorizontally
        }

        return false
    }
}
