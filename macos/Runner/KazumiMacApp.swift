//
//  KazumiMacApp.swift
//  Kazumi (macOS)
//
//  macOS 侧入口。这一版只立骨架：一个窗口、一套侧边栏、一个「关于」设置页，
//  加上已经能和 iOS 共用的底层（规则模型 / 规则引擎 / 规则网络层）随同一个
//  target 编译——每移植一层就往 project.yml 的 sources 里加一条，CI 编过算数。
//
//  这不是「Designed for iPad」：那个路子是把 iOS target 丢给 macOS SDK，
//  UIKit 模块直接解析不了；这里是真正的 macOS target + macOS 自己的界面。
//

import SwiftUI

@main
struct KazumiMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacRootView()
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