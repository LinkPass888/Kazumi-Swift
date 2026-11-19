//
//  PlayerGlassComponents.swift
//  Kazumi
//

import SwiftUI
import UIKit

struct SurfaceTouchGesturesModifier<Drag: Gesture>: ViewModifier {
    let isEnabled: Bool
    let allowsDrag: Bool
    let isSurfaceLocked: Bool
    let width: CGFloat
    let onDoubleTap: (CGFloat) -> Void
    let onSingleTap: () -> Void
    let dragGesture: Drag
    let onLongPressTriggered: () -> Void
    let onPressingChanged: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else {
            content
                .gesture(
                    ExclusiveGesture(SpatialTapGesture(count: 2), SpatialTapGesture(count: 1))
                        .onEnded { value in
                            switch value {
                            case .first(let tap):
                                onDoubleTap(tap.location.x)
                            case .second:
                                onSingleTap()
                            }
                        }
                )
                .simultaneousGesture(
                    dragGesture,
                    including: allowsDrag ? .all : .none
                )
                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                    onLongPressTriggered()
                } onPressingChanged: { pressing in
                    onPressingChanged(pressing)
                }
        }
    }
}

/// 画面框：竖屏里按画面比例的宽度占满（16:9 就是屏宽 × 屏宽×9/16），
/// 宽形态左栏或横屏全屏时铺满容器。`.fit` 保证不裁画面——原版竖屏同样不裁。
struct PlayerBoxModifier: ViewModifier {
    var fillsWindow: Bool
    var aspectRatio: CGFloat

    /// 不分叉。
    ///
    /// 这里原来是 `if fillsWindow { … } else { … }`，两种分支是两种视图类型，
    /// SwiftUI 会当成两棵不同的树：切横屏时整块画面被拆掉重建，mpv 跟着
    /// `dismantleUIView` 停引擎，进度从 0 重来（LP 2026-10-27「切横屏又丢失进度」）。
    /// 改成一条修饰符链，只让参数变、结构不变。
    func body(content: Content) -> some View {
        content
            // 全屏时 `aspectRatio` 传的是**容器自己的比例**（`boxAspectRatio`），
            // 不是 nil：传 nil 会退回内容的固有比例（mpv 视图是方的），
            // 于是横屏只铺了 382 宽（LP 2026-10-27）。
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: fillsWindow ? .infinity : nil)
    }
}

/// 系统分享面板：把媒体地址交给别的 App（VLC、Infuse 之类）打开。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 播放器横竖屏共用的弹幕符号：圆角框里两条错落横线代表飞过的弹幕，
/// 右下角压一颗小齿轮（设置版）。不写汉字，简繁体、字号糊不糊都不用管。
/// 外框 18.5×15.5、线宽 1.6，跟 18pt Medium 的 `speedometer` / `sidebar.left`
/// 墨水高度 15~16pt、线宽 1.5~1.7pt 对齐；整张画布仍锁 20×18 装下齿轮。
struct DanmakuSettingsGlyph: View {
    /// 颜色由调用方定：播放器里白色，「更多」菜单渲成模板图后跟系统 tint。
    var color: Color = .white

    var body: some View {
        ZStack {
            // 主体框：可视高 15.5pt、宽 18.5pt，线宽 1.6pt。
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1.6)
                .frame(width: 18.5, height: 15.5)
                .overlay {
                    // 两条错落的胶囊横线＝弹幕，免去一切中文字体和简繁问题。
                    VStack(spacing: 2.5) {
                        Capsule()
                            .frame(width: 9, height: 1.6)
                            .offset(x: -1.5)
                        Capsule()
                            .frame(width: 7, height: 1.6)
                            .offset(x: 2)
                    }
                }
                .offset(x: -1, y: -1)
                .overlay(alignment: .bottomTrailing) {
                    // 齿轮位置的镂空避让圆，避免框线和齿轮叠在一起。
                    Circle()
                        .frame(width: 9.5, height: 9.5)
                        .offset(x: 1, y: 1)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

            // 右下角小齿轮：8pt，精致但不抢主体。
            Image(systemName: "gearshape.fill")
                .font(.system(size: 8, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 0.5, y: 0.5)
        }
        .foregroundStyle(color)
        // 严格锁死 20×18，绝不撑大外面的按钮。
        .frame(width: 20, height: 18)
        .contentShape(Rectangle())
    }
}

struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 播放器浮层的玻璃底：iOS 26 用 SwiftUI 原生 `glassEffect`；
/// 低版本退回 `GlassBackdrop`，两边都能编译、观感一致。
/// 一律钉成深色（LP 2026-11-06）：播放器底下永远是画面，不跟系统浅色走。
struct PlayerGlassShapeModifier<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(true), in: shape)
        } else {
            content.background {
                GlassBackdrop()
                    .clipShape(shape)
            }
        }
    }
}

extension View {
    /// HUD 胶囊统一走这一个入口，调用点只写形状。
    func playerGlass<S: Shape>(in shape: S) -> some View {
        modifier(PlayerGlassShapeModifier(shape: shape))
    }
}

struct GlassBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.overrideUserInterfaceStyle = .dark
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

/// 转屏被拒时系统给的那句话，从后台队列交回主线程的盒子。
///
/// UIKit 在自己的队列（崩溃报告里是 `com.apple.root.default-qos`）上回调
/// `requestGeometryUpdate` 的 errorHandler。闭包字面量写在 `@MainActor` 的
/// `Task` 里会继承主线程隔离，UIKit 在后台队列上一叫就撞
/// `_swift_task_checkIsolatedSwift` 断言、整页闪退——平时看不出来，只有系统
/// **拒绝**这次转屏（回调真的被调）才死（LP 4753 的崩溃报告，真机一进全屏被拒）。
///
/// 所以回调里一个字都不碰主线程状态，只往这个带锁的盒子里放一句话，
/// 主线程那边轮询时再取出来。
final class OrientationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (generation: Int, message: String)?

    func record(generation: Int, message: String) {
        lock.lock()
        defer { lock.unlock() }
        // 旧请求迟到的回调不许盖掉新请求的结论。
        if let stored, stored.generation > generation { return }
        stored = (generation, message)
    }

    /// 取走属于这一代请求的那句话；不是这一代的就当没发生过。
    func take(generation: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored, stored.generation == generation else { return nil }
        self.stored = nil
        return stored.message
    }
}

/// 沿着圆角矩形边框走一圈的进度线，起点是左边正中、方向顺时针（LP 5499）。
///
/// 不用 `RoundedRectangle().trim`：`trim` 的起点由路径自己决定（落在上边一带），
/// 换不了，只能自己按段的长度铺。
struct EdgeProgressRing: Shape {
    /// 0…1，画满整圈的多少。
    var fraction: Double
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let arc = CGFloat.pi * r / 2
        let straightV = max(0, rect.height - 2 * r) / 2   // 单侧竖直线（上下一半）
        let straightH = max(0, rect.width - 2 * r)        // 单侧水平线
        // 九段都在这里排好：从左边正中往上，绕一圈回到左边正中。
        let lengths: [CGFloat] = [straightV, arc, straightH, arc, 2 * straightV, arc, straightH, arc, straightV]
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Path() }
        var remaining = total * max(0, min(1, fraction))

        let midY = rect.midY
        var cursor = CGPoint(x: rect.minX, y: midY)
        var path = Path()
        path.move(to: cursor)

        for (index, length) in lengths.enumerated() where remaining > 0 {
            let take = min(length, remaining)
            remaining -= take
            switch index {
            case 0: // 左中 → 左上角起点
                cursor.y -= take
                path.addLine(to: cursor)
            case 1: // 左上角
                let center = CGPoint(x: rect.minX + r, y: rect.minY + r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(.pi),
                            endAngle: .radians(.pi + (take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: .pi + (take / max(arc, 0.0001)) * (.pi / 2))
            case 2: // 上边
                cursor.x += take
                path.addLine(to: cursor)
            case 3: // 右上角
                let center = CGPoint(x: rect.maxX - r, y: rect.minY + r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(.pi * 1.5),
                            endAngle: .radians(.pi * 1.5 + (take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: .pi * 1.5 + (take / max(arc, 0.0001)) * (.pi / 2))
            case 4: // 右边
                cursor.y += take
                path.addLine(to: cursor)
            case 5: // 右下角
                let center = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(0),
                            endAngle: .radians((take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: (take / max(arc, 0.0001)) * (.pi / 2))
            case 6: // 下边
                cursor.x -= take
                path.addLine(to: cursor)
            case 7: // 左下角
                let center = CGPoint(x: rect.minX + r, y: rect.maxY - r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(.pi / 2),
                            endAngle: .radians(.pi / 2 + (take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: .pi / 2 + (take / max(arc, 0.0001)) * (.pi / 2))
            default: // 左边 → 回到正中
                cursor.y -= take
                path.addLine(to: cursor)
            }
        }
        return path
    }

    private static func point(center: CGPoint, r: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }
}
