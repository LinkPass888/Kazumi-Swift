//
//  KazumiApp.swift
//  Kazumi
//
//  纯 SwiftUI 应用入口（取代 Flutter 的 main.dart / AppWidget）。
//  Flutter 引擎、GeneratedPluginRegistrant、Modular 路由树全部移除，
//  启动流程与原 lib/main.dart 对齐：先初始化本地存储，失败时进入存储错误页。
//

import SwiftUI

struct KazumiRootView: View {
    // The UIKit scene owns this environment, including its one router.
    let environment: AppEnvironment
    var storageFailure: AppEnvironment.StartupFailure?

    var body: some View {
        AppRoot(failure: storageFailure)
            .environment(environment)
            .environment(environment.settings)
            .environment(environment.downloadDirectory)
            .environment(environment.library)
            .environment(environment.router)
            .environment(environment.plugins)
            .environment(environment.updates)
            .preferredColorScheme(environment.settings.themeMode.preferredColorScheme)
            // UIKit 仍按窗口 trait 解析它自己的动态色（material、系统语义色），
            // 把同一套亮度写到窗口上，免得系统亮度与应用主题不一致时那些颜色串档。
            // 强调色（`.tint`）不在这里设：这里读不到 `colorScheme`，由 AppRoot
            // 按 SwiftUI 的当前明暗显式取（见 `KazumiPalette.accent(for:)`）。
            .kazumiWindowStyle(environment.settings.themeMode)
            // 配色方案、OLED 纯黑与主题模式都是全局状态（`KazumiPalette` 为静态取值），
            // 换一次要让读它的视图重画一次。这里**不再**用 id 重建整棵树：
            // 那样标签栏也会跟着重新创建，选中胶囊会在重建瞬间从默认那格滑到当前这格
            // （LP 报到「开 OLED 底部 tab 自己切换」就是这个）。重画的范围收到
            // `KazumiTabShell` 里每个标签页的内容上，见那里的 themeRevision。
    }
}
