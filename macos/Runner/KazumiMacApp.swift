//
//  KazumiMacApp.swift
//  Kazumi (macOS)
//
//  macOS 侧入口：一个窗口、一套侧边栏、一个「关于」设置页。
//  已经能用的部分是「规则」与「搜索 → 线路/剧集 → 播放器」这条路，
//  底层（规则模型 / 规则引擎 / 规则网络层 / 播放内核）与 iOS 共用同一份源码。
//
//  这不是「Designed for iPad」：那个路子是把 iOS target 丢给 macOS SDK，
//  UIKit 模块直接解析不了；这里是真正的 macOS target + macOS 自己的界面。
//

import SwiftUI

@main
struct KazumiMacApp: App {
    /// 规则与播放请求的共享状态。
    /// 规则文件落在 Application Support/Kazumi/rules/v2/ 下，目录不在的话第一次装规则
    /// 会写盘失败，所以进窗口之前先把存储目录建好（与 iOS 启动那一步同一份实现）。
    @State private var appModel = MacAppModel()

    init() {
        _ = try? AppStoragePaths.prepareDirectories()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(appModel)
                // 窗口最小尺寸按三栏（侧边栏 + 内容 + 播放器预留）算，别小到正文挤成一条。
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            // macOS 版暂时没有「新建窗口」的语义，别留一个点了什么也不发生的菜单项。
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            MacAboutView()
        }
    }
}