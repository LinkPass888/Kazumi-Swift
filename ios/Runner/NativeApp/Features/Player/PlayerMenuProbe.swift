//
//  PlayerMenuProbe.swift
//  Kazumi
//
//  「系统菜单这会儿开没开」——控制层的自动隐藏要知道这件事。
//

import SwiftUI
import UIKit

/// 系统菜单（SwiftUI `Menu`）这会儿是不是开着。
///
/// `Menu` 不把开合状态告诉代码，控制层的自动隐藏就不知道菜单还开着，
/// 几秒一到连菜单一起收掉（LP 2026-10-25）。这颗 app 不上架，所以直接看
/// 系统内部那一层在不在。
@MainActor
enum SystemMenuProbe {
    static var isPresented: Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where hasMenu(in: window) {
                return true
            }
        }
        return false
    }


    private static func hasMenu(in window: UIWindow) -> Bool {
        if isMenuView(window) { return true }
        if let root = window.rootViewController, isMenuView(root.view) { return true }
        for subview in window.subviews where isMenuView(subview) { return true }
        return false
    }

    private static func isMenuView(_ view: UIView) -> Bool {
        if String(describing: type(of: view)).contains("ContextMenu") { return true }
        for subview in view.subviews where isMenuView(subview) { return true }
        return false
    }
}
