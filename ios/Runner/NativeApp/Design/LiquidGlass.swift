//
//  LiquidGlass.swift
//  Kazumi
//
//  iOS 26 原生液态玻璃封装：
//   * glassEffect / GlassEffectContainer 直接由系统渲染（折射、镜面高光、形变）；
//   * 关闭玻璃时退回可读的实色卡片，避免低性能设备上出现闪烁。
//

import SwiftUI

/// 顶栏玻璃按钮的统一度量（1:1 对照 lib/bean/liquid_glass/kazumi_glass.dart）。
///
/// 原版所有顶栏按钮都走同一套数值：按钮 40×40、按钮间距 6、屏幕边距 10，
/// 推荐页右上角那两个按钮、详情页的返回 / 更多按钮都用它，
/// 这样换到 iOS 后按钮的直径与间距仍然和原版一致。
enum KazumiGlassMetrics {
    /// 圆形玻璃按钮的边长。44pt 是 Apple HIG 的最低点击区域标准。
    static let barButtonSize: CGFloat = 44
    /// 相邻两个顶栏按钮之间的空隙。
    static let barButtonGap: CGFloat = 6
    /// 最后一个顶栏按钮离屏幕边缘的留白。
    static let barEdgeInset: CGFloat = 10
}

extension View {
    /// 悬浮胶囊：Tab 栏、顶部工具条、播放器 OSD 的通用外观。
    ///
    /// 40×40 的正方形用胶囊形状渲染出来就是正圆，顶栏按钮因此不需要另写一份形状。
    func kazumiGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(KazumiGlassShapeModifier(shape: AnyShape(Capsule(style: .continuous)), tint: tint, interactive: interactive))
    }

    /// 浮动卡片：选集面板、弹幕设置、详情页信息块。
    func kazumiGlassCard(cornerRadius: CGFloat = KazumiPalette.cardCornerRadius, tint: Color? = nil) -> some View {
        modifier(
            KazumiGlassShapeModifier(
                shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)),
                tint: tint,
                interactive: false
            )
        )
    }

    /// 让相邻玻璃元素可以互相融合（Apple TV 风格的分组浮层）。
    func kazumiGlassContainer(spacing: CGFloat = 16) -> some View {
        modifier(KazumiGlassContainerModifier(spacing: spacing))
    }
}

private struct KazumiGlassShapeModifier: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        content.background { backdrop }
            .contentShape(shape)
            .modifier(KazumiNativeGlassEffect(shape: shape, tint: tint, interactive: interactive))
    }

    /// 玻璃底下垫的那一层。
    ///
    /// iOS 26 上系统 `glassEffect` 自己就是底，再垫一层 `ultraThinMaterial` 只会把它
    /// 变成一块不透的亮纱——压在深色封面上尤其明显，看着就是「玻璃不透」（LP 2884 / 2893）。
    /// 垫底本来就是给没有系统玻璃的低版本留的退路（Colo 2898），所以只在低版本上出现；
    /// iOS 26 上只留一圈描边做边缘高光。
    @ViewBuilder
    private var backdrop: some View {
        if #available(iOS 26.0, *) {
            if let tint {
                shape.fill(tint.opacity(0.18))
            }
            rim
        } else {
            if let tint {
                shape.fill(tint.opacity(0.18))
            }
            shape.fill(.ultraThinMaterial)
            rim
        }
    }

    /// AnyShape 擦除了 InsettableShape 约束，只能用 stroke（strokeBorder 不可用）。
    private var rim: some View {
        shape.stroke(Color.white.opacity(0.16), lineWidth: 0.5)
    }
}

/// iOS 26 原生玻璃效果，独立成 ViewModifier 以便编译期做可用性判断。
private struct KazumiNativeGlassEffect: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                content.glassEffect(.regular.interactive(interactive), in: shape)
            }
        } else {
            content
        }
    }
}

private struct KazumiGlassContainerModifier: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 播放器与首页共用的玻璃进度条（16:9 卡片内嵌）。
struct KazumiGlassProgressBar: View {
    var progress: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 4)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }
}
