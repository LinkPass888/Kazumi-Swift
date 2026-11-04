//
//  PlayerHaptics.swift
//  Kazumi
//
//  播放页的触控反馈（LP 3660，手感按 Colo 3662）：
//  双击播放/暂停、长按起手、横滑调进度、拖进度条。
//
//  只用轻碰和中碰两档，不用 `UISelectionFeedbackGenerator`——那档太轻，
//  手里几乎感觉不到（Colo 3662）。拖拽中途也不震，只震起手和松手两下。
//
//  反馈器自己持有实例：每次新建都要重新预热，连着拖时第一下手感会发闷。
//  系统「设置 › 声音与触感」里关掉触感时这些调用自然不出手，不用自己再判。
//

import UIKit

@MainActor
enum PlayerHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)

    /// 轻碰：双击播放/暂停、拖拽起手、拖拽松手落定。
    static func tap() {
        light.prepare()
        light.impactOccurred()
    }

    /// 中碰：长按进临时倍速那一下（松手不震）。
    static func bump() {
        medium.prepare()
        medium.impactOccurred()
    }
}
