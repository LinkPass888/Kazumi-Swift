//
//  MPVMetalView.swift
//  Kazumi
//
//  承载 mpv gpu-next / MoltenVK 输出的原生 Metal 视图（iOS 是 UIView，macOS 是 NSView）。
//  mpv 通过 wid 持有 metalLayer，并在自己的渲染线程直接提交 drawable。
//

import Metal
import QuartzCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// MoltenVK 在切换 drawable 时会临时写入 1×1 尺寸，直接用会让画面闪烁。
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            if Thread.isMainThread {
                super.drawableSize = newValue
            } else {
                performSelector(
                    onMainThread: #selector(applyDrawableSize(_:)),
                    with: Self.boxSize(newValue),
                    waitUntilDone: false
                )
            }
        }
    }

    @objc private func applyDrawableSize(_ value: NSValue) {
        #if os(iOS)
        drawableSize = value.cgSizeValue
        #else
        drawableSize = value.sizeValue
        #endif
    }

    private static func boxSize(_ size: CGSize) -> NSValue {
        #if os(iOS)
        // iOS 的 NSValue 走 cgSize:/cgSizeValue（UIKit 加的类别）。
        return NSValue(cgSize: size)
        #else
        // macOS 上 NSSize 就是 CGSize，只有 size:/sizeValue。
        return NSValue(size: size)
        #endif
    }
}

#if os(iOS)
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
#else
final class MPVMetalView: NSView {
    /// 同上：独立 sublayer + 无 delegate，别让 vo 线程的事务进到 NSView 的布局里。
    private let videoLayer = MPVMetalLayer()

    var metalLayer: MPVMetalLayer { videoLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMetalLayer()
    }

    private func configureMetalLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.delegate = nil
        layer?.addSublayer(videoLayer)
        videoLayer.frame = bounds
        videoLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.wantsExtendedDynamicRangeContent = false
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.masksToBounds = true
        updateDrawableSize()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
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
#endif
