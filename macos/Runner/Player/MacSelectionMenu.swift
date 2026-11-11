//
//  MacSelectionMenu.swift
//  Kazumi (macOS)
//
//  macOS 的原生下拉菜单：`NSButton` + `NSMenu`。
//
//  和 iOS 那边（`UIButton` + `UIMenu`，见 SystemMenuButton.swift）同一套思路：
//  菜单对象活在 SwiftUI 之外，播放状态每 250ms 刷新也不会让屏幕上的菜单
//  变成「点了不执行」的旧副本。数据模型两边共用 `SelectionMenuModel`。
//
//  `NSMenu.popUp` 是阻塞式的：调用前是展开、返回后就是收起，所以开合状态
//  不用像 iOS 那样去探窗口层级。
//

import SwiftUI

#if os(macOS)
import AppKit

struct MacSelectionMenu: NSViewRepresentable {
    let model: SelectionMenuModel
    var title: String
    var minWidth: CGFloat = 52
    /// 菜单展开 / 收起。控制条的自动隐藏要靠它让开。
    var onOpenChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.onOpenChanged = onOpenChanged

        let menu = NSMenu()
        for (index, option) in model.options.enumerated() {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(Coordinator.pick(_:)),
                keyEquivalent: ""
            )
            item.target = coordinator
            item.tag = index
            item.state = option.isSelected ? .on : .off
            menu.addItem(item)
        }
        button.menu = menu
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: SelectionMenuModel?
        var onOpenChanged: ((Bool) -> Void)?

        @objc func showMenu(_ sender: NSButton) {
            guard let menu = sender.menu else { return }
            onOpenChanged?(true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
            onOpenChanged?(false)
        }

        @objc func pick(_ sender: NSMenuItem) {
            guard let options = model?.options, options.indices.contains(sender.tag) else { return }
            options[sender.tag].action()
        }
    }
}
#endif
