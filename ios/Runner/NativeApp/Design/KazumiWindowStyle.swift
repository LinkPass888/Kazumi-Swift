//
//  KazumiWindowStyle.swift
//  Kazumi
//
//  让 UIKit 侧的主题与 SwiftUI 的主题保持一致。
//
//  `.preferredColorScheme` 只改 SwiftUI 的环境，`Color(uiColor:)` 这类
//  UIKit 动态色仍然按**窗口的 trait collection** 解析。系统是浅色、应用
//  设成深色（或反过来）时，动态色会取到相反那一档，界面上的强调色、
//  material 底色就整体对调了 —— 这正是「浅色 / 深色配色反了」的来源。
//
//  这里把窗口的 `overrideUserInterfaceStyle` 同步成当前主题模式：UIKit
//  动态色与 SwiftUI 环境从此用同一套亮度，配色不再串档。
//

import SwiftUI
import UIKit

/// 把当前主题模式写进窗口的 `overrideUserInterfaceStyle`。
private struct KazumiWindowStyleModifier: ViewModifier {
    let mode: KazumiThemeMode

    func body(content: Content) -> some View {
        content
            .background {
                KazumiWindowStyleSync(style: mode.uiStyle)
                    .frame(width: 0, height: 0)
            }
    }
}

extension View {
    /// 在根视图上调用一次即可。
    func kazumiWindowStyle(_ mode: KazumiThemeMode) -> some View {
        modifier(KazumiWindowStyleModifier(mode: mode))
    }
}

private extension KazumiThemeMode {
    /// 对应的 UIKit 界面风格；跟随系统时为 `.unspecified`（交给系统）。
    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 空控制器，只负责在挂载与更新时把风格写到窗口上。
private struct KazumiWindowStyleSync: UIViewControllerRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIViewController(context: Context) -> Controller {
        Controller(style: style)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.apply(style)
    }

    final class Controller: UIViewController {
        private var style: UIUserInterfaceStyle

        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(style)
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self else { return }
                self.apply(self.style)
            }
        }

        /// 写到所在的窗口上；窗口变化（分屏、外接屏）时重新写一次。
        func apply(_ style: UIUserInterfaceStyle) {
            self.style = style
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
