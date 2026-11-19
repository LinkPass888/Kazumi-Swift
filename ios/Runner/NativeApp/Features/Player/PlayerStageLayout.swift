//
//  PlayerStageLayout.swift
//  Kazumi
//

import SwiftUI

enum PlayerStageRole: Sendable {
    case player
    case wideInfo
    case episodes
}

struct PlayerStageRoleKey: LayoutValueKey {
    static let defaultValue: PlayerStageRole = .player
}

/// 播放页单一扁平自适应舞台布局：
/// - 全屏：播放器铺满整个区域；
/// - 宽屏非全屏（Duo 展开 / iPad / 桌面窗口）：左栏顶部 16:9 播放器 + 左栏下方番剧信息与操作工作台，右栏（336–420pt）专职选集与评论；
/// - 竖屏非全屏：顶部 16:9 播放器 + 下方选集与评论。
/// `player` 始终作为第 0 个子视图保留在同一层级，转屏、折叠与全屏切换零视图重建。
struct PlayerStageLayout: Layout {
    var isFullscreen: Bool
    var isWideSplit: Bool
    var videoAspectRatio: CGFloat

    private static let minWideInfoHeight: CGFloat = 148

    private static func wideSidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        min(max((totalWidth * 0.39).rounded(), 336), 420)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(
            width: proposal.width ?? 393,
            height: proposal.height ?? 852
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        if isFullscreen {
            for subview in subviews where subview[PlayerStageRoleKey.self] == .player {
                subview.place(
                    at: bounds.origin,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
                )
            }
            return
        }

        let ratio = max(videoAspectRatio, 0.1)

        if isWideSplit {
            let sidebarWidth = min(bounds.width * 0.5, Self.wideSidebarWidth(for: bounds.width))
            let leftWidth = max(1, bounds.width - sidebarWidth)
            let idealPlayerHeight = (leftWidth / ratio).rounded()
            let maxPlayerHeight = max(180, bounds.height - Self.minWideInfoHeight)
            let playerHeight = min(bounds.height, min(idealPlayerHeight, maxPlayerHeight))
            let infoHeight = max(0, bounds.height - playerHeight)

            for subview in subviews {
                switch subview[PlayerStageRoleKey.self] {
                case .player:
                    subview.place(
                        at: bounds.origin,
                        anchor: .topLeading,
                        proposal: ProposedViewSize(width: leftWidth, height: playerHeight)
                    )
                case .wideInfo:
                    subview.place(
                        at: CGPoint(x: bounds.minX, y: bounds.minY + playerHeight),
                        anchor: .topLeading,
                        proposal: ProposedViewSize(width: leftWidth, height: infoHeight)
                    )
                case .episodes:
                    subview.place(
                        at: CGPoint(x: bounds.minX + leftWidth, y: bounds.minY),
                        anchor: .topLeading,
                        proposal: ProposedViewSize(width: sidebarWidth, height: bounds.height)
                    )
                }
            }
            return
        }

        let playerHeight = min(
            (bounds.width / ratio).rounded(),
            (bounds.height * 0.65).rounded()
        )
        let episodesHeight = max(0, bounds.height - playerHeight)

        for subview in subviews {
            switch subview[PlayerStageRoleKey.self] {
            case .player:
                subview.place(
                    at: bounds.origin,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: playerHeight)
                )
            case .episodes:
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY + playerHeight),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: episodesHeight)
                )
            case .wideInfo:
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bounds.maxY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: 0, height: 0)
                )
            }
        }
    }
}
