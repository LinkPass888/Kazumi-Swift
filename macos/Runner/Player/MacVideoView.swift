//
//  MacVideoView.swift
//  Kazumi (macOS)
//
//  mpv 的输出面：一个只有 CAMetalLayer 子层的 NSView。
//  iOS 那份（MPVMetalView）用的是同样的做法，只是宿主换成 UIView。
//

import AppKit
import Metal
import QuartzCore
import SwiftUI

/// MoltenVK 切 drawable 时会临时写 1×1，直接用会让画面闪一下（iOS 侧同一个坑）。
final class MacMPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            if Thread.isMainThread {
                super.drawableSize = newValue
            } else {
                // macOS 这边的 NSValue 走 AppKit 的 size:（NSSize 就是 CGSize），
                // iOS 那套 cgSize:/cgSizeValue 在这边没有。
                performSelector(
                    onMainThread: #selector(applyDrawableSize(_:)),
                    with: NSValue(size: newValue),
                    waitUntilDone: false
                )
            }
        }
    }

    @objc private func applyDrawableSize(_ value: NSValue) {
        drawableSize = value.sizeValue
    }
}

/// 承载 mpv 画面的视图。
///
/// 不把 metalLayer 当 NSView 的 backing layer：mpv 的 vo 线程会直接改它的
/// drawableSize，退场时 CoreAnimation 会在那条线程提交残留事务。作为无 delegate
/// 的独立 sublayer 就没有这条链路。
final class MacVideoHostView: NSView {
    let videoLayer = MacMPVMetalLayer()

    /// 视图有了窗口、且尺寸已经量出来之后回调一次：引擎拿这一刻的 layer 去设 `wid`。
    var onLayerReady: ((CAMetalLayer) -> Void)?
    private var delivered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.delegate = nil
        layer?.addSublayer(videoLayer)
        videoLayer.device = MTLCreateSystemDefaultDevice()
        videoLayer.pixelFormat = .bgra8Unorm
        videoLayer.framebufferOnly = true
        videoLayer.isOpaque = true
        videoLayer.wantsExtendedDynamicRangeContent = false
        // 转尺寸那一拍 layer.frame 和 drawableSize 不同步：保持比例缩放，
        // 让过渡帧先留边，等 mpv 按新 drawable 重画。
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.masksToBounds = true
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        updateDrawableSize()
        deliverIfPossible()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        deliverIfPossible()
    }

    private func deliverIfPossible() {
        guard !delivered, window != nil, bounds.width >= 2, bounds.height >= 2 else { return }
        delivered = true
        onLayerReady?(videoLayer)
    }

    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        let scaleValue = scale > 0 ? scale : 1
        if videoLayer.contentsScale != scaleValue {
            videoLayer.contentsScale = scaleValue
        }
        let target = CGSize(
            width: max(1, bounds.width * scaleValue),
            height: max(1, bounds.height * scaleValue)
        )
        if videoLayer.drawableSize != target {
            videoLayer.drawableSize = target
        }
    }
}

/// SwiftUI 里的视频面。
struct MacVideoSurface: NSViewRepresentable {
    let onLayerReady: (CAMetalLayer) -> Void

    func makeNSView(context: Context) -> MacVideoHostView {
        let view = MacVideoHostView()
        view.onLayerReady = onLayerReady
        return view
    }

    func updateNSView(_ nsView: MacVideoHostView, context: Context) {
        nsView.onLayerReady = onLayerReady
    }
}