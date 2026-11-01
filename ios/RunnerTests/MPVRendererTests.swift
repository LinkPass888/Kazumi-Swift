import Foundation
import GLKit
import Libmpv
import OpenGLES
import UIKit
import XCTest
@testable import Runner

/// Hosted, local-only renderer regressions. These XCTest methods run serially in one
/// class, and every EAGL operation stays on MainActor. This tests software-decoded
/// output on the simulator, NOT VideoToolbox/device hardware-decoder correctness.
@MainActor
final class MPVRendererTests: XCTestCase {
    /// Diagnostic only: deliberately does not establish renderer correctness.
    /// The two regression tests below remain strict; this reports every observation
    /// even when allocation/decoding fails so a broken pipeline is inspectable.
    func testDebugSingleFrameColors() async {
        executionTimeAllowance = 15
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-render-debug-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = try QuadrantFixture.write(to: directory, name: "debug-first", alternate: false)
            let renderer = try RendererHarness()
            defer { renderer.close() }
            print("[render-test] debug-only: start and load PNG (linked mpv has no PPM decoder)")
            try renderer.start()
            renderer.engine.load(url: url, referer: nil, userAgent: nil)
            for attempt in 1...40 {
                do {
                    if let frame = try renderer.display() {
                        print("[render-test] debug-only attempt=\(attempt) matches=\(frame.matchesFixture(alternate: false)) \(frame.summary)")
                    } else {
                        print("[render-test] debug-only attempt=\(attempt) no rendered callback")
                    }
                } catch {
                    print("[render-test] debug-only attempt=\(attempt) error=\(error)")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("[render-test] debug-only complete; NOT a correctness assertion\n\(renderer.diagnostics)")
        } catch {
            print("[render-test] debug-only setup/wait error=\(error)")
        }
    }

    func testLocalImageColorsOrientationConsecutiveFramesResizeAndReopen() async throws {
        executionTimeAllowance = 90
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-render-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let firstURL = try QuadrantFixture.write(to: fixtureDirectory, name: "first", alternate: false)
        let secondURL = try QuadrantFixture.write(to: fixtureDirectory, name: "reopened", alternate: true)
        let renderer = try RendererHarness()
        defer { renderer.close() }

        do {
            try renderer.start()
            try renderer.skipUnlessCVOutputAvailable()
            print("[render-test] step=load-initial-fixture")
            renderer.engine.load(url: firstURL, referer: nil, userAgent: nil)
            try await renderer.skipIfFixtureUndecodable()
            try await renderer.waitForImage(alternate: false)
            try renderer.requireCVOutputPath()
            attachFrame(renderer, name: "GLKView-initial-quadrants")

            // Do not just wait for one lucky good frame: every subsequent presentation
            // must contain the image. Clear/read occurs again on every display().
            print("[render-test] step=consecutive-frames")
            for _ in 0..<12 {
                let frame = try XCTUnwrap(renderer.display())
                try check(frame.matchesFixture(alternate: false), frame.summary)
                try await Task.sleep(for: .milliseconds(16))
            }

            // Grow, change aspect ratio (letterboxing), then shrink. Pixel dimensions
            // are deliberately independent of the simulator's Retina scale.
            for size in [CGSize(width: 320, height: 192), CGSize(width: 96, height: 160),
                         CGSize(width: 160, height: 96)] {
                renderer.resize(to: size)
                try await renderer.waitForImage(alternate: false)
                attachFrame(renderer, name: "GLKView-resized-\(Int(size.width))x\(Int(size.height))")
            }

            print("[render-test] step=stop-and-release-drawable")
            renderer.engine.stop()
            try check(renderer.engine.handle == nil, "stop() must release the mpv handle")
            try check(try renderer.display() == nil, "A stopped engine must not emit rendered frames")
            renderer.view.deleteDrawable()

            // Reuse the same engine/context after releasing all CV/GL output resources.
            // Different quadrant colors ensure an old retained image cannot pass.
            try renderer.start()
            print("[render-test] step=reopen-with-alternate-fixture")
            renderer.engine.load(url: secondURL, referer: nil, userAgent: nil)
            try await renderer.waitForImage(alternate: true)
            try renderer.requireCVOutputPath()
            attachFrame(renderer, name: "GLKView-reopened-alternate-quadrants")
            for _ in 0..<6 {
                let frame = try XCTUnwrap(renderer.display())
                try check(frame.matchesFixture(alternate: true), frame.summary)
                try await Task.sleep(for: .milliseconds(16))
            }
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    func testCVAllocationResizeAndBlitRestoreCallerGLBindings() throws {
        executionTimeAllowance = 30
        let renderer = try RendererHarness()
        defer { renderer.close() }
        do {
            try renderer.start()
            try renderer.skipUnlessCVOutputAvailable()
            // No image needed here: this checks first CV allocation, reallocation,
            // then target reuse. Image correctness is asserted by the test above.
            for size in [CGSize(width: 160, height: 96), CGSize(width: 320, height: 192),
                         CGSize(width: 320, height: 192)] {
                renderer.resize(to: size)
                try renderer.checkBindingRestoration()
            }
            try renderer.requireCVOutputPath()
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    private func attachFailure(_ renderer: RendererHarness, error: Error) {
        let message = "\(error)\n\(renderer.diagnostics)"
        // Record the real failure before attachment creation or UIKit teardown can
        // raise an unrelated framework error and replace XCTest's thrown error.
        print("[render-test] FAILURE\n\(message)")
        XCTFail(message)
        let diagnostic = XCTAttachment(string: message)
        diagnostic.name = "mpv-render-diagnostics"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        attachFrame(renderer, name: "GLKView-final-frame-readback-failure")
    }

    private func attachFrame(_ renderer: RendererHarness, name: String) {
        if let image = renderer.lastFrame?.image {
            let screenshot = XCTAttachment(image: image)
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}

private struct RendererFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw RendererFailure(description: message) }
}

private func required<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw RendererFailure(description: message) }
    return value
}

private enum QuadrantFixture {
    static let width = 160
    static let height = 96

    /// RGB byte triples in top-left, top-right, bottom-left, bottom-right order.
    static func colors(alternate: Bool) -> [[UInt8]] {
        alternate
            ? [[0, 255, 255], [255, 0, 255], [255, 255, 255], [255, 128, 0]]
            : [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
    }

    /// MPVKit omits FFmpeg's PPM decoder. Encode the same explicit top-to-bottom
    /// RGB pixels as PNG instead; no network, asset writer, or binary test resource.
    @MainActor
    static func write(to directory: URL, name: String, alternate: Bool) throws -> URL {
        let palette = colors(alternate: alternate)
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                bytes.append(contentsOf: palette[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)])
                bytes.append(255)
            }
        }
        let provider = try required(CGDataProvider(data: Data(bytes) as CFData), "Could not create PNG pixel provider")
        let image = try required(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ), "Could not construct PNG fixture image")
        let png = try required(UIImage(cgImage: image).pngData(), "Could not encode local PNG fixture")
        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        try png.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private final class RendererHarness {
    let engine: MPVEngine
    let view: MPVGLView
    private let window: UIWindow
    private var requestedSize = CGSize(width: 160, height: 96)
    private var logs: [String] = []
    private var errors: [String] = []
    private var frameCount = 0
    private var firstFrameCount = 0
    private var snapshot: MPVSnapshot?
    private var thisDisplayFrame: FrameReadback?
    private(set) var lastFrame: FrameReadback?

    init() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try required(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                 "A hosted iOS test window scene is required; rendering is never skipped")
        let engine = MPVEngine()
        self.engine = engine
        view = MPVGLView(frame: CGRect(x: 0, y: 0, width: 160, height: 96), context: engine.glContext)
        // Borrow the host window rather than replacing its key window/root
        // controller: Xcode 27's Gestures framework can throw during that teardown,
        // masking a real renderer failure. The drawable is still truly on-screen.
        window = try required(scene.windows.first(where: \.isKeyWindow)
                               ?? scene.windows.first(where: { !$0.isHidden }),
                               "A visible hosted test window is required")
        view.drawableColorFormat = .RGBA8888
        view.drawableDepthFormat = .formatNone
        view.drawableStencilFormat = .formatNone
        view.drawableMultisample = .multisampleNone
        view.isOpaque = true
        // Explicit display() drives the real MPVGLView.draw + present path. Automatic
        // UIKit redraws are disabled so callback counts belong to each test request.
        view.enableSetNeedsDisplay = false
        view.engine = engine
        engine.glView = view
        window.addSubview(view)
        view.contentScaleFactor = 1
        window.layoutIfNeeded()
        engine.hardwareDecodeEnabled = false
        engine.applyCacheSize(2 * 1024 * 1024)
        engine.onLog = { [weak self] message in
            guard let self else { return }
            if logs.count < 1_000 {
                logs.append(message)
                print("[render-test] mpv: \(message)")
            }
        }
        engine.onSnapshot = { [weak self] in self?.snapshot = $0 }
        // Diagnostic only: an early blank render can fire this before FILE_LOADED.
        engine.onFirstFrame = { [weak self] in self?.firstFrameCount += 1 }
    }

    func start() throws {
        print("[render-test] step=start-engine")
        try check(engine.glContext.api == .openGLES3, "CV output requires OpenGL ES 3")
        engine.start()
        let handle = try required(engine.handle, "mpv failed to start")
        for (name, value) in [("image-display-duration", "3600"), ("keep-open", "yes")] {
            let status = mpv_set_property_string(handle, name, value)
            try check(status >= 0, "Setting \(name)=\(value) failed: \(status)")
        }
        engine.onFrameRendered = { [weak self] framebuffer, width, height, _, _ in
            guard let self else { return }
            frameCount += 1
            do {
                // Read the final, screen-oriented GLKView FBO BEFORE GLKView presents
                // its non-retained renderbuffer. screenshot-raw bypasses this pipeline.
                let frame = try FrameReadback.read(framebuffer: framebuffer, width: width, height: height)
                thisDisplayFrame = frame
                lastFrame = frame
            } catch {
                errors.append(String(describing: error))
            }
        }
    }

    func resize(to size: CGSize) {
        print("[render-test] step=resize size=\(size)")
        requestedSize = size
        view.frame = CGRect(origin: .zero, size: size)
        view.contentScaleFactor = 1
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Returns only a frame emitted by THIS display call, never a stale callback.
    func display() throws -> FrameReadback? {
        let previousContext = EAGLContext.current()
        try check(EAGLContext.setCurrent(engine.glContext), "Could not make renderer context current")
        defer { EAGLContext.setCurrent(previousContext) }
        try bindDrawable()
        glDisable(GLenum(GL_SCISSOR_TEST))
        glColorMask(GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE))
        glViewport(0, 0, GLsizei(view.drawableWidth), GLsizei(view.drawableHeight))
        thisDisplayFrame = nil
        view.display()
        let glErrors = takeGLErrors()
        if !glErrors.isEmpty { print("[render-test] display GL errors=\(glErrors)") }
        try check(glErrors.isEmpty, "display/present GL errors: \(glErrors)")
        try check(errors.isEmpty, errors.joined(separator: "\n"))
        return thisDisplayFrame
    }

    private func bindDrawable() throws {
        view.bindDrawable()
        try check(view.drawableWidth == Int(requestedSize.width) && view.drawableHeight == Int(requestedSize.height),
                  "Drawable \(view.drawableWidth)x\(view.drawableHeight) != requested \(requestedSize)")
        try check(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE),
                  "GLKView drawable framebuffer is incomplete")
    }

    func waitForImage(alternate: Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        var matchingFrames = 0
        var attempt = 0
        print("[render-test] step=wait-for-image alternate=\(alternate)")
        while clock.now < deadline {
            attempt += 1
            try Task.checkCancellation()
            let frame = try display()
            try requireNoGLErrors()
            if let loadError = snapshot?.loadError {
                throw RendererFailure(description: "Local image failed to load: \(loadError)")
            }
            let sourceReady = snapshot?.videoWidth == Double(QuadrantFixture.width)
                && snapshot?.videoHeight == Double(QuadrantFixture.height)
            print("[render-test] wait attempt=\(attempt) sourceReady=\(sourceReady) matches=\(frame?.matchesFixture(alternate: alternate) ?? false) \(frame?.summary ?? "no rendered callback")")
            if sourceReady, let frame, frame.matchesFixture(alternate: alternate) {
                matchingFrames += 1
                if matchingFrames == 3 { return }
            } else {
                matchingFrames = 0
            }
            // Yield MainActor to libmpv's queued updates and the UIKit run loop.
            // Never block the main thread with waitForExpectations or mpv_wait_event.
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RendererFailure(description: "Timed out waiting for three actual color-correct frames (alternate=\(alternate)). \(diagnostics)")
    }

    /// 本机能不能建 CV 纹理目标。模拟器的 Apple Software Renderer 不支持
    /// CVOpenGLESTextureCache（CreateTextureFromImage 报 -6683），真机才行；
    /// 这条路径只能真机验，本机就明确跳过，而不是假装通过。
    func skipUnlessCVOutputAvailable() throws {
        resize(to: CGSize(width: 160, height: 96))
        _ = try? display()
        if logs.contains(where: { $0.contains("CreateTextureFromImage rc=-6683") }) {
            throw XCTSkip("本机 GL 渲染器不支持 CVOpenGLESTextureCache（-6683），CV 像素缓冲出图只能真机验")
        }
    }

    /// 链接的 mpv 没带图片解码器（png/ppm 都是 no decoders）。颜色测试要真画面，
    /// 素材解不了就明确跳过，而不是等到超时再报一个看不出原因的失败。
    func skipIfFixtureUndecodable() async throws {
        for _ in 0..<40 {
            let failed = logs.contains {
                $0.contains("no decoders") || $0.contains("Failed to initialize a decoder")
            }
            if failed {
                throw XCTSkip("链接的 mpv 没有图片解码器，颜色测试需要能解码的素材")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func requireCVOutputPath() throws {
        let present = logs.contains { $0.contains("mpv→CVPixelBuffer") && $0.contains("GLKView GPU blit") }
        print("[render-test] successful CVPixelBuffer/GLKView GPU blit log present=\(present)")
        try check(present,
                  "No successful CVPixelBuffer → GLKView GPU blit diagnostic; direct rendering is not this test's target")
    }

    func requireNoGLErrors() throws {
        let failures = logs.filter { $0.contains("CV 输出路径失败") || $0.contains("GL 排空：") || $0.contains("OpenGL error") }
        try check(failures.isEmpty && errors.isEmpty, (failures + errors).joined(separator: "\n"))
    }

    /// Exercises the private output-state helper via its real caller, without adding
    /// production test hooks. Distinct read/draw FBOs catch GL_FRAMEBUFFER-only saves.
    func checkBindingRestoration() throws {
        let previousContext = EAGLContext.current()
        try check(EAGLContext.setCurrent(engine.glContext), "Could not make renderer context current")
        defer { EAGLContext.setCurrent(previousContext) }
        try bindDrawable()
        let drawable = integer(GL_DRAW_FRAMEBUFFER_BINDING)
        var textures = [GLuint](repeating: 0, count: 2)
        var readFramebuffer: GLuint = 0
        var renderbuffer: GLuint = 0
        glGenTextures(2, &textures)
        glGenFramebuffers(1, &readFramebuffer)
        glGenRenderbuffers(1, &renderbuffer)
        defer {
            glDisable(GLenum(GL_SCISSOR_TEST))
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(drawable))
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), 0)
            glDeleteFramebuffers(1, &readFramebuffer)
            glDeleteRenderbuffers(1, &renderbuffer)
            glDeleteTextures(2, &textures)
            glActiveTexture(GLenum(GL_TEXTURE0))
        }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), renderbuffer)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8), 4, 4)
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
        glFramebufferRenderbuffer(GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                  GLenum(GL_RENDERBUFFER), renderbuffer)
        try check(glCheckFramebufferStatus(GLenum(GL_READ_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE),
                  "Sentinel read framebuffer is incomplete")
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), textures[0])
        glActiveTexture(GLenum(GL_TEXTURE3))
        glBindTexture(GLenum(GL_TEXTURE_2D), textures[1])
        glEnable(GLenum(GL_SCISSOR_TEST))
        glScissor(2, 3, 4, 5)
        glViewport(7, 11, GLsizei(view.drawableWidth - 14), GLsizei(view.drawableHeight - 22))
        let before = GLBindingSnapshot()
        try check(takeGLErrors().isEmpty, "Sentinel GL setup failed")
        let originalCallback = engine.onFrameRendered
        defer { engine.onFrameRendered = originalCallback }
        var callbackFramebuffer: GLint?
        var callbackSize: [Int] = []
        engine.onFrameRendered = { framebuffer, width, height, _, _ in
            callbackFramebuffer = framebuffer
            callbackSize = [width, height]
        }
        engine.render(in: view)
        let after = GLBindingSnapshot()
        try requireNoGLErrors()
        try check(before == after, "Caller GL bindings changed:\nbefore=\(before)\nafter=\(after)")
        try check(callbackFramebuffer == drawable, "PiP/render callback must receive the final drawable FBO, not the CV FBO")
        try check(callbackSize == [view.drawableWidth - 14, view.drawableHeight - 22],
                  "Render callback viewport size is wrong: \(callbackSize)")
        try check(takeGLErrors().isEmpty, "GL errors after CV allocation/blit/state restoration")
    }

    var diagnostics: String {
        "successfulCVBlitLog=\(logs.contains { $0.contains("mpv→CVPixelBuffer") && $0.contains("GLKView GPU blit") }) "
            + "requested=\(requestedSize) drawable=\(view.drawableWidth)x\(view.drawableHeight) "
            + "callbacks=\(frameCount) firstFrameCallbacks=\(firstFrameCount) "
            + "source=\(snapshot?.videoWidth ?? 0)x\(snapshot?.videoHeight ?? 0) "
            + "loadError=\(snapshot?.loadError ?? "none")\n"
            + (lastFrame?.summary ?? "No GLKView frame read back") + "\n"
            + (logs + errors).joined(separator: "\n")
    }

    func close() {
        print("[render-test] step=close-renderer-without-window-churn")
        engine.onFirstFrame = nil
        engine.onSnapshot = nil
        engine.stop()
        view.engine = nil
        engine.glView = nil
        let previousContext = EAGLContext.current()
        EAGLContext.setCurrent(engine.glContext)
        view.deleteDrawable()
        EAGLContext.setCurrent(previousContext)
        view.removeFromSuperview()
    }
}

private func integer(_ name: Int32) -> GLint {
    var value: GLint = 0
    glGetIntegerv(GLenum(name), &value)
    return value
}

private func takeGLErrors() -> [String] {
    var errors: [String] = []
    for _ in 0..<16 {
        let error = glGetError()
        if error == GLenum(GL_NO_ERROR) { break }
        errors.append("0x" + String(error, radix: 16))
    }
    return errors
}

private struct GLBindingSnapshot: Equatable {
    let draw = integer(GL_DRAW_FRAMEBUFFER_BINDING)
    let read = integer(GL_READ_FRAMEBUFFER_BINDING)
    let renderbuffer = integer(GL_RENDERBUFFER_BINDING)
    let activeTexture = integer(GL_ACTIVE_TEXTURE)
    let activeTextureBinding = integer(GL_TEXTURE_BINDING_2D)
    let scissorEnabled = glIsEnabled(GLenum(GL_SCISSOR_TEST))
    var textureZeroBinding: GLint = 0
    var viewport = [GLint](repeating: 0, count: 4)
    var scissorBox = [GLint](repeating: 0, count: 4)

    init() {
        glActiveTexture(GLenum(GL_TEXTURE0))
        textureZeroBinding = integer(GL_TEXTURE_BINDING_2D)
        glActiveTexture(GLenum(activeTexture))
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        glGetIntegerv(GLenum(GL_SCISSOR_BOX), &scissorBox)
    }
}

private struct FrameReadback {
    let width: Int
    let height: Int
    /// glReadPixels rows start at the drawable's bottom, unlike the PNG fixture.
    let rgba: [UInt8]

    static func read(framebuffer: GLint, width: Int, height: Int) throws -> Self {
        try check(width > 0 && height > 0, "Render callback returned empty dimensions")
        let readFramebuffer = integer(GL_READ_FRAMEBUFFER_BINDING)
        let packBuffer = integer(GL_PIXEL_PACK_BUFFER_BINDING)
        let packNames = [GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH, GL_PACK_SKIP_ROWS, GL_PACK_SKIP_PIXELS]
        let packValues = packNames.map(integer)
        defer {
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(readFramebuffer))
            glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), GLuint(packBuffer))
            for (name, value) in zip(packNames, packValues) { glPixelStorei(GLenum(name), value) }
        }
        let precedingErrors = takeGLErrors()
        try check(precedingErrors.isEmpty, "GL errors before final drawable readback: \(precedingErrors)")
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(framebuffer))
        glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
        glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
        for name in packNames { glPixelStorei(GLenum(name), name == GL_PACK_ALIGNMENT ? 1 : 0) }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes {
            glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
        }
        let errors = takeGLErrors()
        try check(errors.isEmpty, "Final drawable glReadPixels failed: \(errors)")
        return Self(width: width, height: height, rgba: rgba)
    }

    private func pixel(x: Int, topY: Int) -> [UInt8] {
        let start = ((height - 1 - topY) * width + x) * 4
        return Array(rgba[start..<(start + 4)])
    }

    private var sampleCenters: [(x: Int, y: Int)] {
        let scale = min(Double(width) / Double(QuadrantFixture.width), Double(height) / Double(QuadrantFixture.height))
        let imageWidth = Double(QuadrantFixture.width) * scale
        let imageHeight = Double(QuadrantFixture.height) * scale
        let left = (Double(width) - imageWidth) / 2
        let top = (Double(height) - imageHeight) / 2
        return [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map {
            (Int(left + imageWidth * $0.0), Int(top + imageHeight * $0.1))
        }
    }

    func matchesFixture(alternate: Bool) -> Bool {
        let expected = QuadrantFixture.colors(alternate: alternate)
        for (index, center) in sampleCenters.enumerated() {
            // Nine pixels well inside each quadrant avoid filtering-edge artifacts;
            // channel tolerance allows small GPU color conversion/rounding differences.
            for dy in -1...1 {
                for dx in -1...1 {
                    let actual = pixel(x: center.x + dx, topY: center.y + dy)
                    if !(0..<3).allSatisfy({ abs(Int(actual[$0]) - Int(expected[index][$0])) <= 32 }) { return false }
                    if actual[3] < 240 { return false }
                }
            }
        }
        return true
    }

    var summary: String {
        "readback=\(width)x\(height) RGBA top-left/top-right/bottom-left/bottom-right="
            + sampleCenters.map { "\(pixel(x: $0.x, topY: $0.y))" }.joined(separator: ", ")
    }

    @MainActor
    var image: UIImage? {
        var topDown = [UInt8]()
        topDown.reserveCapacity(rgba.count)
        for y in (0..<height).reversed() {
            topDown.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
        }
        guard let provider = CGDataProvider(data: Data(topDown) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
