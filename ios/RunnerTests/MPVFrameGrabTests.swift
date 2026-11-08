import CoreVideo
import Testing
@testable import Runner

struct MPVFrameGrabTests {
    @Test("BGRA 画中画帧可直接按行复制且像素不变")
    func bgraFrameUsesDirectCopyWithoutChangingPixels() throws {
        let source: [UInt8] = [
            1, 2, 3, 255,
            4, 5, 6, 255,
            99, 99, 99, 99,
            7, 8, 9, 255,
            10, 11, 12, 255,
            88, 88, 88, 88,
        ]
        let frame = MPVRawFrame(
            width: 2,
            height: 2,
            stride: 12,
            format: "bgra",
            pixels: source
        )

        #expect(frame.canDirectCopyToBGRA)
        let pixelBuffer = try #require(frame.makePixelBuffer())
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        #expect(Array(UnsafeBufferPointer(start: bytes, count: 8)) == Array(source[0..<8]))
        #expect(Array(UnsafeBufferPointer(start: bytes + stride, count: 8)) == Array(source[12..<20]))
    }

    @Test("非 BGRA 帧不能误走直接复制")
    func rgbaFrameKeepsChannelConversion() {
        let frame = MPVRawFrame(
            width: 1,
            height: 1,
            stride: 4,
            format: "rgba",
            pixels: [10, 20, 30, 255]
        )
        #expect(!frame.canDirectCopyToBGRA)
    }

    @Test("BGRA 帧的 alpha 统一补成不透明，避免小窗整块透明")
    func bgraAlphaIsForcedOpaque() throws {
        let frame = MPVRawFrame(
            width: 2,
            height: 1,
            stride: 8,
            format: "bgra",
            pixels: [1, 2, 3, 0, 4, 5, 6, 0]
        )
        let pixelBuffer = try #require(frame.makePixelBuffer())
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 255)
        #expect(bytes[7] == 255)
        #expect(Array(UnsafeBufferPointer(start: bytes, count: 3)) == [1, 2, 3])
    }

    @Test("负 stride 自下而上时行序被翻正")
    func negativeStrideIsUnflipped() throws {
        // stride = -8：缓冲里先放的是画面最下面那一行。
        let frame = MPVRawFrame(
            width: 2,
            height: 2,
            stride: -8,
            format: "bgra",
            pixels: [
                1, 2, 3, 255, 4, 5, 6, 255,      // 画面第 1 行（底）
                7, 8, 9, 255, 10, 11, 12, 255,   // 画面第 0 行（顶）
            ]
        )
        let pixelBuffer = try #require(frame.makePixelBuffer())
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        #expect(Array(UnsafeBufferPointer(start: bytes, count: 8)) == [7, 8, 9, 255, 10, 11, 12, 255])
        #expect(Array(UnsafeBufferPointer(start: bytes + stride, count: 8)) == [1, 2, 3, 255, 4, 5, 6, 255])
    }

    @Test("24 位打包帧按每像素三字节还原，不斜行")
    func rgb24FrameUsesThreeBytesPerPixel() throws {
        let frame = MPVRawFrame(
            width: 2,
            height: 2,
            stride: 8,
            format: "bgr24",
            pixels: [
                1, 2, 3, 4, 5, 6, 0, 0,
                7, 8, 9, 10, 11, 12, 0, 0,
            ]
        )
        let image = try #require(frame.makeCGImage())
        #expect(image.width == 2)
        #expect(image.height == 2)
    }
}
