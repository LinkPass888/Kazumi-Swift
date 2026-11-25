//
//  MPVMetalView.swift
//  Kazumi
//
//  承载 mpv gpu-next / MoltenVK 输出的原生 Metal 视图（UIView；Mac Catalyst 共用同一份实现）。
//  mpv 通过 wid 持有 metalLayer，并在自己的渲染线程直接提交 drawable。
//

import Metal
import QuartzCore
import UIKit

/// MoltenVK 在切换 drawable 时会临时写入 1×1 尺寸，直接用会让画面闪烁；
/// 且 MoltenVK 会在转屏过程中在后台线程用旧交换链尺寸覆写 drawableSize，
/// 必须防止后台线程覆盖宿主视图已算好的全屏目标物理尺寸。
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            if Thread.isMainThread {
                super.drawableSize = newValue
            } else {
                // 如果当前 layer 已经具备有效 bounds，严禁后台线程使用不一致的旧交换链尺寸
                // 覆盖宿主视图计算出的目标尺寸；否则切全屏时异步派发的旧尺寸会冲掉主线程
                // 刚设好的全屏 drawableSize，导致 MoltenVK 交换链无法重配并停留在左下角。
                let scale = contentsScale > 0 ? contentsScale : 1
                let expectedSize = CGSize(
                    width: max(1, bounds.width * scale),
                    height: max(1, bounds.height * scale)
                )
                guard bounds.width <= 1 || bounds.height <= 1 || newValue == expectedSize else {
                    return
                }
                performSelector(
                    onMainThread: #selector(applyDrawableSize(_:)),
                    with: Self.boxSize(newValue),
                    waitUntilDone: false
                )
            }
        }
    }

    @objc private func applyDrawableSize(_ value: NSValue) {
        let size = value.cgSizeValue
        let scale = contentsScale > 0 ? contentsScale : 1
        let expectedSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        guard bounds.width <= 1 || bounds.height <= 1 || size == expectedSize else {
            return
        }
        super.drawableSize = size
    }

    private static func boxSize(_ size: CGSize) -> NSValue {
        // NSValue 的 cgSize:/cgSizeValue 是 UIKit 加的类别。
        NSValue(cgSize: size)
    }
}

final class MPVMetalView: UIView {
    /// 不把 metalLayer 当 UIView 的 backing layer：mpv 的 vo 线程会直接改它的
    /// drawableSize，退场时 CoreAnimation 会在 vo 线程提交残留的布局事务，
    /// 进而从 vo 线程调进 UIView 的 layoutSubviews，撞上 MainActor 检查。
    /// 作为无 delegate 的独立 sublayer，那条事务不会再进入任何 UIView。
    private let videoLayer = MPVMetalLayer()

    var metalLayer: MPVMetalLayer { videoLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMetalLayer()
    }

    private func configureMetalLayer() {
        backgroundColor = .black
        isOpaque = true

        videoLayer.delegate = nil
        layer.addSublayer(videoLayer)
        videoLayer.frame = bounds
        videoLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.wantsExtendedDynamicRangeContent = false
        // 转屏那一拍 layer.frame 和 drawableSize 不是同时更新的：旧的一帧
        // 如果按 stretch 铺满新 bounds，就会先被拉宽/压扁。保持比例缩放，
        // 等 mpv 下一帧按新 drawable 重画，稳态下两者比例一致，没有副作用。
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.masksToBounds = true
        updateDrawableSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        // MoltenVK 交换链创建时可能会将 contentsGravity 改为 kCAGravityBottomLeft；
        // 布局时强行锁定为 .resizeAspect，避免任何过渡阶段画面靠左下角。
        if videoLayer.contentsGravity != .resizeAspect {
            videoLayer.contentsGravity = .resizeAspect
        }
        CATransaction.commit()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        // 倍率走 trait collection（iOS 26 起 `UIScreen.main` 弃用，而且 displayScale 变化时
        // 系统会自动再走一次布局，不用自己盯屏）。
        let scale = traitCollection.displayScale
        let scaleValue = scale > 0 ? scale : 1
        if metalLayer.contentsScale != scaleValue {
            metalLayer.contentsScale = scaleValue
        }
        let targetSize = CGSize(
            width: max(1, bounds.width * scaleValue),
            height: max(1, bounds.height * scaleValue)
        )
        if metalLayer.drawableSize != targetSize {
            metalLayer.drawableSize = targetSize
        }
    }
}
