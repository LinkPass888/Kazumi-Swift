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

/// 全屏播放的临时方向锁。
///
/// `requestGeometryUpdate` 只有在 `supportedInterfaceOrientations` 也允许那个方向时才会生效，
/// 本工程由应用代理返回这个值。播放器进全屏时把 `mask` 改成横屏，
/// 退出时改回竖屏；其它页面一律 `portrait`，与 Info.plist 声明一致（竖横都支持，只改运行时锁）。
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait
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

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        PlaybackLifecycleDiagnostics.log("scene.willConnectTo", scene: scene)
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = RemoteControlHostingController(rootView: KazumiRootView())
        // 画面自己铺满；背景交给 SwiftUI 的主题色，别让窗口底色在转场时闪一下白。
        host.view.backgroundColor = .clear
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()

        // 保留现有顺序：窗口就绪后请求 FirstResponder 并声明远程控制事件。
        Self.declareRemoteControlEvents(on: host)
        PlaybackLifecycleDiagnostics.log("scene.windowReady", scene: scene,
                                         details: "beginReceivingRemoteControlEvents=called")
    }

    /// 把宿主控制器顶成 FirstResponder，再向系统声明「这个 App 要收远程控制事件」。
    ///
    /// `UIHostingController` 的 `canBecomeFirstResponder` 默认是 false、而且是只读的，
    /// 所以用下面那个子类把它打开。拿不到第一响应者也照样要调
    /// `beginReceivingRemoteControlEvents()`——后者是 App 级声明，不依赖响应者链。
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
}
