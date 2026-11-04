//
//  MPVFrameGrab.swift
//  Kazumi
//
//  截图取帧（LP 5012，参考 main）：走 mpv 的 `screenshot-raw`，拿的是**解码后的原始帧**，
//  跟窗口、跟播放区大小、跟横竖屏、跟 fit/crop/stretch 都没有关系。
//
//  为什么不是 `screenshot-to-file … video`：那条依赖窗口渲染层（我们的 VO 是 `gpu-next`），
//  真机上一直回失败，失败后我们退到「读屏幕那一帧」，于是截出来只有播放区那么大、
//  还跟着屏幕比例被裁过（LP 5002 的 402×226 / 716×402 就是播放区的点尺寸）。
//
//  `screenshot-raw` 回的是一个 mpv node：
//    { w, h, stride, format, data }
//  其中 `data` 是 MPV_FORMAT_BYTE_ARRAY。node 只在事件处理那一刻有效，所以当场拷走。
//

import CoreGraphics
import CoreVideo
import Foundation
import Libmpv

/// 一块从 mpv 取回来的原始帧。
struct MPVRawFrame: Sendable {
    var width: Int
    var height: Int
    var stride: Int
    /// mpv 的像素格式名（`bgr0` / `rgb0` / `rgba` / `bgr24` …）。
    var format: String
    var pixels: [UInt8]

    /// 从 `screenshot-raw` 的回执 node 里读出来。读不到关键字段就返回 nil。
    init?(node: mpv_node) {
        guard node.format == MPV_FORMAT_NODE_MAP, let rawList = node.u.list else { return nil }
        let list = rawList.pointee
        guard list.num > 0, let keys = list.keys, let values = list.values else { return nil }

        var width = 0
        var height = 0
        var stride = 0
        var format = ""
        var pixels: [UInt8] = []

        for index in 0..<Int(list.num) {
            guard let keyPointer = keys[index] else { continue }
            let key = String(cString: keyPointer)
            let value = values[index]
            switch key {
            case "w":
                width = Int(value.u.int64)
            case "h":
                height = Int(value.u.int64)
            case "stride":
                stride = Int(value.u.int64)
            case "format":
                if let string = value.u.string { format = String(cString: string) }
            case "data":
                guard value.format == MPV_FORMAT_BYTE_ARRAY,
                      let byteArray = value.u.ba?.pointee,
                      let start = byteArray.data
                else { continue }
                pixels = Array(
                    UnsafeBufferPointer(
                        start: start.assumingMemoryBound(to: UInt8.self),
                        count: Int(byteArray.size)
                    )
                )
            default:
                continue
            }
        }

        guard width > 0, height > 0, !pixels.isEmpty else { return nil }
        // stride 没给就按最紧的排法算（一个像素 3 字节还是 4 字节由格式决定）。
        let bytesPerPixel = Self.layout(of: format)?.bytesPerPixel ?? 4
        self.width = width
        self.height = height
        self.stride = stride > 0 ? stride : width * bytesPerPixel
        self.format = format
        self.pixels = pixels
    }

    /// 这块帧的像素尺寸，写日志用。
    var pixelSize: CGSize { CGSize(width: width, height: height) }

    /// 转成 CGImage。mpv 给的是打包好的 RGB 变体，这里统一还原成 RGBA 再建图。
    func makeCGImage() -> CGImage? {
        guard let layout = Self.layout(of: format) else { return nil }
        // 一个像素占几个字节要按格式算，**不能拿 `map.count`**：那张表永远是四项
        // （源里没有的通道填 -1），`rgb24`/`bgr24` 只占 3 字节却会被当成 4 字节，
        // 整个图就斜着花了（Fuck 5017）。
        let bytesPerPixel = layout.bytesPerPixel
        let channels = layout.map
        guard bytesPerPixel > 0, pixels.count >= stride * height || pixels.count >= width * bytesPerPixel * height
        else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rowStride = stride > 0 && stride >= width * bytesPerPixel
            ? stride
            : width * bytesPerPixel

        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            rgba.withUnsafeMutableBufferPointer { target in
                guard let out = target.baseAddress else { return }
                for y in 0..<height {
                    let rowStart = base.advanced(by: y * rowStride)
                    let outRow = out.advanced(by: y * width * 4)
                    for x in 0..<width {
                        let pixel = rowStart.advanced(by: x * bytesPerPixel)
                        let destination = outRow.advanced(by: x * 4)
                        // channels 记的是 RGBA 各通道在源像素里的字节偏移。
                        // 16-bit RGB 取高字节即可直接降到 8-bit 显示。
                        destination[0] = pixel[channels[0]]
                        destination[1] = pixel[channels[1]]
                        destination[2] = pixel[channels[2]]
                        destination[3] = channels[3] >= 0 ? pixel[channels[3]] : 255
                    }
                }
            }
        }

        let provider = CGDataProvider(data: Data(rgba) as CFData)
        guard let provider else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// 转成画中画可直接消费的 32BGRA `CVPixelBuffer`。
    func makePixelBuffer() -> CVPixelBuffer? {
        guard let layout = Self.layout(of: format) else { return nil }
        let bytesPerPixel = layout.bytesPerPixel
        let channels = layout.map
        let rowStride = stride > 0 && stride >= width * bytesPerPixel
            ? stride
            : width * bytesPerPixel
        guard pixels.count >= rowStride * height else { return nil }

        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)

        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            let output = destination.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let sourceRow = base.advanced(by: y * rowStride)
                let destinationRow = output.advanced(by: y * destinationStride)
                for x in 0..<width {
                    let pixel = sourceRow.advanced(by: x * bytesPerPixel)
                    let target = destinationRow.advanced(by: x * 4)
                    target[0] = pixel[channels[2]]
                    target[1] = pixel[channels[1]]
                    target[2] = pixel[channels[0]]
                    target[3] = channels[3] >= 0 ? pixel[channels[3]] : 255
                }
            }
        }
        return buffer
    }

    /// 一种打包像素格式的读法。
    private struct PixelLayout {
        /// 一个像素占几个字节：8-bit 是 3/4，16-bit RGB 是 6/8。
        let bytesPerPixel: Int
        /// RGBA 四个字节分别取源里的第几位，-1 表示源里没有这个通道。
        let map: [Int]
    }

    /// mpv 的格式名 → 读法。名字的读法跟 mpv 文档一致：`bgr0` 是 B,G,R,X（第 4 个
    /// 字节没用），`0bgr` 是 X,B,G,R，`bgra` / `rgba` 就是字面顺序。
    private static func layout(of format: String) -> PixelLayout? {
        switch format.lowercased() {
        case "rgb0", "rgbx": return PixelLayout(bytesPerPixel: 4, map: [0, 1, 2, -1])
        case "bgr0", "bgrx": return PixelLayout(bytesPerPixel: 4, map: [2, 1, 0, -1])
        case "0rgb", "xrgb": return PixelLayout(bytesPerPixel: 4, map: [1, 2, 3, -1])
        case "0bgr", "xbgr": return PixelLayout(bytesPerPixel: 4, map: [3, 2, 1, -1])
        case "rgba": return PixelLayout(bytesPerPixel: 4, map: [0, 1, 2, 3])
        case "bgra": return PixelLayout(bytesPerPixel: 4, map: [2, 1, 0, 3])
        case "argb": return PixelLayout(bytesPerPixel: 4, map: [1, 2, 3, 0])
        case "abgr": return PixelLayout(bytesPerPixel: 4, map: [3, 2, 1, 0])
        case "rgb24": return PixelLayout(bytesPerPixel: 3, map: [0, 1, 2, -1])
        case "bgr24": return PixelLayout(bytesPerPixel: 3, map: [2, 1, 0, -1])
        case "rgb48le", "rgb48": return PixelLayout(bytesPerPixel: 6, map: [1, 3, 5, -1])
        case "bgr48le", "bgr48": return PixelLayout(bytesPerPixel: 6, map: [5, 3, 1, -1])
        case "rgb48be": return PixelLayout(bytesPerPixel: 6, map: [0, 2, 4, -1])
        case "bgr48be": return PixelLayout(bytesPerPixel: 6, map: [4, 2, 0, -1])
        case "rgba64le", "rgba64": return PixelLayout(bytesPerPixel: 8, map: [1, 3, 5, 7])
        case "bgra64le", "bgra64": return PixelLayout(bytesPerPixel: 8, map: [5, 3, 1, 7])
        case "rgba64be": return PixelLayout(bytesPerPixel: 8, map: [0, 2, 4, 6])
        case "bgra64be": return PixelLayout(bytesPerPixel: 8, map: [4, 2, 0, 6])
        default: return nil
        }
    }
}
