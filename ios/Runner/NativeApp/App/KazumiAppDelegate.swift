//
//  KazumiAppDelegate.swift
//  Kazumi
//
//  仅保留 UIKit 侧必须的能力：
//   1. 忽略 SIGPIPE，免得对端关连接时把整个进程带走；
//   2. 静音网络下的启动检查入口（对应 MeteredNetworkService.refresh）；
//   3. 应用进入前台时刷新设置（对应 app_widget.dart 的 didChangeAppLifecycleState）。
//  窗口由 KazumiSceneDelegate 承载 SwiftUI 根视图。
//
//  **启动时一概不碰 AVAudioSession**（LP 4938）：这里以前会 `setCategory(.playback)`
//  再 `setActive(true)`，App 一冷启动就向系统申请独占的播放会话，首页还没点播放，
//  后台正在放歌的其它 App 就被掐断了。音频会话只由 `PlayerAudioSession` 管：
//  进播放器才配 `.playback` 并激活，退出时 `restore()` 退回去。
//  Info.plist 里的 `UIBackgroundModes: audio` 不受影响——它声明的是「允许」，
//  要不要出声由会话决定。
//

import SwiftUI
import Observation
import UIKit

/// UIKit 应用入口；场景代理负责创建承载 SwiftUI 的窗口。
/// 生命周期日志只记录回调和当时状态，不推断卡片点击结果或启动原因。
@main
final class KazumiAppDelegate: UIResponder, UIApplicationDelegate {
    /// 保留现有响应者能力；窗口创建后的实际请求在场景代理中。
    override var canBecomeFirstResponder: Bool { true }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PlaybackLifecycleDiagnostics.processBoot()
        // 忽略 SIGPIPE：往已经关掉的 socket 写数据时，默认行为是直接干掉整个进程
        // （日志里的 `terminated (exit 141)` 就是 128 + 13）。流媒体解析、换集、
        // 取消加载时连接被对端关掉是常事，不该因此把 App 杀掉。
        signal(SIGPIPE, SIG_IGN)
        UITabBar.appearance().isHidden = false
        UITableView.appearance().backgroundColor = .clear
        // 远程控制事件声明保留在场景窗口创建之后。
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PlaybackLifecycleDiagnostics.log("application.didBecomeActive")
        NotificationCenter.default.post(name: .kazumiAppDidBecomeActive, object: nil)
    }

    /// 保持现有 UIKit 场景配置，不改变场景或导航行为。
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.sceneClass = UIWindowScene.self
        config.delegateClass = KazumiSceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // WebDAV / 下载任务使用的后台 URLSession：尽快回调，避免系统终止任务。
        completionHandler()
    }
}

extension Notification.Name {
    static let kazumiAppDidBecomeActive = Notification.Name("com.example.kazumi.appDidBecomeActive")

    /// 弹幕屏蔽词被改过。同步那边靠它做 500ms 防抖后上传（原版
    /// danmaku_shield_sync_service.dart 也是改完就同步，不是只等下次启动）。
    static let kazumiDanmakuRulesChanged = Notification.Name("com.example.kazumi.danmakuRulesChanged")
}

/// 没有页面自己锁方向时允许的方向。
///
/// iPad 四向全开；iPhone 三向，不倒置。竖屏版面和以前一样（不写尺寸判断就没人转它），
/// 横屏由各页面按宽度档位自己排。
@MainActor
enum OrientationLock {
    static let appDefault: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    static var mask: UIInterfaceOrientationMask = appDefault

    /// 交还方向：把锁恢复成默认，并让系统重新算支持的方向。
    /// 不在这里请求某个具体方向——多方向时「请求转到横/竖」没有意义，交给设备姿态。
    static func release(scene: UIWindowScene?) {
        mask = appDefault
        guard let scene else { return }
        for window in scene.windows {
            markDirty(window.rootViewController)
        }
    }

    private static func markDirty(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let presented = controller.presentedViewController {
            markDirty(presented)
        }
        if let nav = controller as? UINavigationController {
            markDirty(nav.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            markDirty(tab.selectedViewController)
        }
    }
}

extension KazumiAppDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}


// MARK: - 场景

/// 创建承载 SwiftUI 的窗口；Objective-C 类名与 Info.plist 中的配置一致。
@objc(KazumiSceneDelegate)
final class KazumiSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment?
    private var isDismissingForLink = false
    private var isWaitingForLinkRoot = false
    private var preparedRequestRevision: UInt?
    private weak var retiringSurface: PlayerSurfaceModel?

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        receive(URLContexts)
    }

    private func receive(_ contexts: Set<UIOpenURLContext>) {
        // File/document URLs remain outside the Kazumi navigation handler.
        for context in contexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
            environment?.router.openURL(context.url)
        }
    }

    /// All navigation enters through the scene's existing environment/router.
    /// A queued cold link is released only after SwiftUI and its navigation controller mount.
    private func processPendingLink() {
        guard let router = environment?.router, router.pendingExternalLink != nil,
              router.isRootMounted, router.externalNavigationDeferralCount == 0,
              let host = window?.rootViewController, host.viewIfLoaded?.window != nil,
              !isDismissingForLink else { return }

        let controllers = visibleControllers(in: host)
        if let transition = controllers.compactMap(\.transitionCoordinator).first {
            isDismissingForLink = true
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isDismissingForLink = false
                    self?.processPendingLink()
                }
            }
            return
        }
        // Respect protected exports/edit operations rather than forcibly dismissing them.
        guard !controllers.contains(where: { $0.isModalInPresentation }) else { return }

        if isWaitingForLinkRoot {
            // Source callbacks have already been invalidated. Do not push a new route until
            // the old player's normal onDisappear has stopped its engine and the root is visible.
            guard retiringSurface?.engine == nil else {
                if let surface = retiringSurface {
                    withObservationTracking { _ = surface.engine } onChange: { [weak self] in
                        Task { @MainActor in self?.processPendingLink() }
                    }
                }
                return
            }
            let navigationControllers = controllers.compactMap { $0 as? UINavigationController }
            guard !navigationControllers.isEmpty,
                  navigationControllers.allSatisfy({ $0.viewControllers.count == 1 }) else { return }
            isWaitingForLinkRoot = false
            if preparedRequestRevision != router.externalRequestRevision {
                // A newer request arrived while dismissal/pop was in flight; newest wins.
                prepareLinkRoot(router, host: host)
            } else {
                router.finishExternalNavigation()
            }
            return
        }

        router.beginExternalNavigation()
        SourceSheetCoordinator.shared.controller?.closeSourceSearch()
        // Dismiss UIKit first and only then release the root sheet's retained controller.
        // This also closes sheets owned by pushed pages, share sheets and full-screen covers.
        if let presenter = controllers.first(where: { $0.presentedViewController != nil }) {
            isDismissingForLink = true
            presenter.dismiss(animated: true) { [weak self] in
                SourceSheetCoordinator.shared.dismiss()
                SourceSheetCoordinator.shared.clearIfNeeded()
                self?.isDismissingForLink = false
                guard let self, let router = self.environment?.router else { return }
                self.prepareLinkRoot(router, host: host)
            }
        } else {
            SourceSheetCoordinator.shared.dismiss()
            SourceSheetCoordinator.shared.clearIfNeeded()
            prepareLinkRoot(router, host: host)
        }
    }

    private func prepareLinkRoot(_ router: AppRouter, host: UIViewController) {
        router.externalModalsDidDismiss()
        retiringSurface = PlayerAudioSession.shared.surface
        preparedRequestRevision = router.externalRequestRevision
        isWaitingForLinkRoot = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { _ = router.prepareExternalNavigation() }
        // A layout/transition completion, not an elapsed-time guess, releases the new route.
        host.view.setNeedsLayout()
        DispatchQueue.main.async { [weak self] in self?.processPendingLink() }
    }

    private func visibleControllers(in root: UIViewController) -> [UIViewController] {
        var result = [root]
        let children: [UIViewController]
        if let tabs = root as? UITabBarController {
            children = tabs.selectedViewController.map { [$0] } ?? []
        } else if let navigation = root as? UINavigationController {
            children = navigation.visibleViewController.map { [$0] } ?? []
        } else {
            children = root.children.filter { $0.viewIfLoaded?.window != nil }
        }
        for child in children {
            result += visibleControllers(in: child)
        }
        if let presented = root.presentedViewController {
            result += visibleControllers(in: presented)
        }
        return result
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        PlaybackLifecycleDiagnostics.log("scene.willConnectTo", scene: scene)
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let launch = AppEnvironment.makeAtLaunch()
        environment = launch.environment
        launch.environment.router.onExternalNavigationRequested = { [weak self] in
            self?.processPendingLink()
        }
        let host = RemoteControlHostingController(rootView: KazumiRootView(
            environment: launch.environment, storageFailure: launch.failure
        ))
        host.onNavigationLayout = { [weak self] in self?.processPendingLink() }
        // 画面自己铺满；背景交给 SwiftUI 的主题色，别让窗口底色在转场时闪一下白。
        host.view.backgroundColor = .clear
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()
        receive(connectionOptions.urlContexts)

        // 旧路径保留窗口就绪后的声明；现代路径启动时不接旧远程事件。
        if !NowPlayingCenter.modernSupported {
            Self.declareRemoteControlEvents(on: host)
        }
        PlaybackLifecycleDiagnostics.log(
            "scene.windowReady", scene: scene,
            details: "beginReceivingRemoteControlEvents=\(NowPlayingCenter.modernSupported ? "skipped-modern" : "called")"
        )
    }

    /// 只供不支持现代框架的启动路径使用；播放器激活后的补充声明仍由音频会话管理。
    @MainActor
    private static func declareRemoteControlEvents(on host: UIViewController) {
        _ = host.becomeFirstResponder()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        PlaybackLifecycleDiagnostics.log("scene.willEnterForeground", scene: scene)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        PlaybackLifecycleDiagnostics.log("scene.didEnterBackground", scene: scene)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        PlaybackLifecycleDiagnostics.log("scene.willResignActive", scene: scene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        PlaybackLifecycleDiagnostics.log("scene.didBecomeActive", scene: scene)
        // 保留现有的设置刷新通知。
        NotificationCenter.default.post(name: .kazumiAppDidBecomeActive, object: nil)
        processPendingLink()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        PlaybackLifecycleDiagnostics.log("scene.didDisconnect", scene: scene)
    }
}

/// 能成为第一响应者的宿主控制器。
///
/// 允许现有窗口初始化流程请求成为第一响应者，不据此判断媒体卡片点击结果。
private final class RemoteControlHostingController<Content: View>: UIHostingController<Content> {
    override var canBecomeFirstResponder: Bool { true }
    var onNavigationLayout: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onNavigationLayout?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Avoid mutating SwiftUI state from within its current layout pass.
        DispatchQueue.main.async { [weak self] in self?.onNavigationLayout?() }
    }
}
