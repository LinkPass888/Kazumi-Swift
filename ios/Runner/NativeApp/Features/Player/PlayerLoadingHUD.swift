//
//  PlayerLoadingHUD.swift
//  Kazumi
//
//  播放器里那颗加载符号（LP 4810）。
//
//  圈就用系统的 `ProgressView()`：它自己会转、跟着深浅色走、开了「减弱动态效果」
//  也不会乱动，不用我们再维护一套动画（Ato 4812）。这里只多做一件事——在它下面
//  配一行网速，让「卡住了」和「在下、只是慢」能分得清。
//

import SwiftUI

/// 圈 + 加载信息 + 网速。用在三处：解析地址、起播等第一帧、播放中途缓冲 / 拖进度。
struct PlayerLoadingHUD: View {
    /// 当前下载速度（字节/秒）。0 表示拿不到或者没在下载。
    var bytesPerSecond: Double = 0

    /// 圈下面第一行：走到哪一步了（「正在解析播放地址…」）。nil 就不占位。
    var info: String? = nil

    /// 网速那行要不要一直显示（拿不到速度时显示横线）。
    /// 解析阶段还没有 mpv，速度永远是 0，占位只会把下面的字往下顶
    /// ——那里传 false，让「正在加载第 N 集」离底栏远一点。
    var reservesSpeedLine: Bool = true

    /// 圈本身的布局高度：`ProgressView()` 默认 20 见方，`scaleEffect` 只放大画出来的
    /// 那圈、不改布局。外面要把**圆心**钉在画面正中那条线上时按它算（LP 4913）。
    static let circleHeight: CGFloat = 20

    private var speedText: String? { Self.speedText(bytesPerSecond) }

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
            if let info {
                Text(info)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            // 没有读数时保留横线，避免网速行消失和加载圈跳动。
            // 等宽数字：不然「9.8 MB/s」跳成「10.0 MB/s」时整行会左右抖一下。
            if reservesSpeedLine || speedText != nil {
                Text(speedText ?? "— KB/s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .animation(.easeOut(duration: 0.15), value: speedText)
            }
        }
    }

    /// 「1.2 MB/s」「860 KB/s」。拿不到（0、非数、小到没有意义）时返回 nil，
    /// 界面上不挂一行「0 KB/s」。
    static func speedText(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1024 else { return nil }
        let megabytes = bytesPerSecond / 1024 / 1024
        if megabytes >= 1 {
            return String(format: "%.1f MB/s", megabytes)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}
