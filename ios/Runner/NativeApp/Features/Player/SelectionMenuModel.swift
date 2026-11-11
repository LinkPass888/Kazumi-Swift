//
//  SelectionMenuModel.swift
//  Kazumi
//
//  「从若干项里选一个」的菜单数据：只有选项、当前项和回调，不含任何渲染。
//
//  渲染交给平台，各自用原生控件：
//    * iOS   —— UIButton + UIMenu（`SystemMenuButton.swift`）
//    * macOS —— NSButton + NSMenu（`macos/Runner/Player/MacSelectionMenu.swift`）
//
//  为什么不用 SwiftUI `Menu`：播放状态每 250ms 刷新一次视图，SwiftUI 菜单会在
//  屏幕上留下一份点了不执行的旧副本，也不把开合状态告诉代码（控制条自动隐藏
//  要靠它）。
//

import Foundation

struct SelectionMenuModel {
    struct Option {
        var title: String
        var isSelected: Bool
        var action: () -> Void
    }

    var options: [Option]
}
