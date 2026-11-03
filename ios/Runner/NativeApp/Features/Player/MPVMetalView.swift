//
//  MPVMetalView.swift
//  Kazumi
//
//  承载 mpv gpu-next / MoltenVK 输出的原生 Metal 视图。
//  mpv 通过 wid 持有 metalLayer，并在自己的渲染线程直接提交 drawable。
//

import Metal
import QuartzCore
import UIKit

/// MoltenVK 在切换 drawable 时会临时写入 1×1 尺寸，直接用会让画面闪烁。
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            super.drawableSize = newValue
        }
    }
}

final class MPVMetalView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer {
        // layerClass 已固定为 MPVMetalLayer。
        layer as! MPVMetalLayer
    }

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

        let metalLayer = metalLayer
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.wantsExtendedDynamicRangeContent = false
        updateDrawableSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
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
