import Foundation
import GLKit
import Mpv
import OpenGLES
import UIKit
import XCTest
@testable import Runner

/// Hosted, local-only renderer regressions. These XCTest methods run serially in one
/// class, and every EAGL operation stays on MainActor. The media fixtures are tiny
/// local H.264 MP4 files decoded in software; this is NOT a VideoToolbox/device
/// hardware-decoder correctness test.
@MainActor
final class MPVRendererTests: XCTestCase {
    /// Strict software playback: top-left/top-right/bottom-left/bottom-right colors
    /// prove both orientation and the actual decoded image. The simulator cannot
    /// create a CVOpenGLESTextureCache target, so this accepts the engine's direct
    /// GL fallback there while still requiring the CV path wherever it is available.
    func testSoftwarePlaybackColorsOrientationAndOutputPath() async throws {
        executionTimeAllowance = 60
        let renderer = try RendererHarness()
        defer { renderer.close() }
        do {
            try renderer.start()
            renderer.engine.load(url: try fixtureURL(.primary), referer: nil, userAgent: nil)
            try await renderer.waitForImage(.primary)
            try renderer.requireSoftwareDecoding()
            try renderer.requireActiveOutputPath()
            attachFrame(renderer, name: "software-primary-quadrants")
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    /// Every display must present the real image, including after aspect-ratio
    /// changes, and the same engine must recover after stop() releases mpv and the
    /// drawable is deleted. The alternate palette makes a retained old frame fail.
    func testConsecutiveFramesResizeStopAndReopen() async throws {
        executionTimeAllowance = 90
        let renderer = try RendererHarness()
        defer { renderer.close() }
        do {
            try renderer.start()
            renderer.engine.load(url: try fixtureURL(.primary), referer: nil, userAgent: nil)
            try await renderer.waitForImage(.primary)
            try renderer.requireSoftwareDecoding()
            try renderer.requireActiveOutputPath()

            // Do not accept one lucky frame: every explicit display must emit a new
            // callback whose final drawable contents still contain the image.
            for index in 0..<12 {
                let frame = try XCTUnwrap(renderer.display())
                try check(frame.matches(.primary), "consecutive frame \(index + 1): \(frame.summary)")
                try await Task.sleep(for: .milliseconds(16))
            }

            // Grow, change aspect ratio (letterboxing), then shrink. Pixel dimensions
            // are deliberately independent of the simulator's Retina scale.
            for size in [CGSize(width: 320, height: 192), CGSize(width: 96, height: 160),
                         CGSize(width: 160, height: 96)] {
                renderer.resize(to: size)
                try await renderer.waitForImage(.primary)
                attachFrame(renderer, name: "software-resized-\(Int(size.width))x\(Int(size.height))")
            }

            print("[render-test] step=stop-and-release-drawable")
            renderer.engine.stop()
            try check(renderer.engine.handle == nil, "stop() must release the mpv handle")
            try check(renderer.engine.onFrameRendered == nil, "stop() must detach the frame callback")
            try check(try renderer.display() == nil, "A stopped engine must not emit rendered frames")
            renderer.view.deleteDrawable()
            renderer.resetPhase()

            // Reuse the same engine/context after releasing all output resources.
            // Different quadrant colors ensure an old retained image cannot pass.
            try renderer.start()
            renderer.engine.load(url: try fixtureURL(.alternate), referer: nil, userAgent: nil)
            try await renderer.waitForImage(.alternate)
            try renderer.requireSoftwareDecoding()
            // The engine deduplicates its "direct fallback" diagnostic for the life
            // of the process, so output-path selection is asserted before stop().
            // Here the alternate palette proves the reopened drawable is a fresh,
            // correctly oriented image rather than a retained old frame.
            attachFrame(renderer, name: "software-reopened-alternate-quadrants")
            for index in 0..<6 {
                let frame = try XCTUnwrap(renderer.display())
                try check(frame.matches(.alternate), "reopened frame \(index + 1): \(frame.summary)")
                try await Task.sleep(for: .milliseconds(16))
            }
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    /// The simulator's Apple Software Renderer rejects CVOpenGLESTextureCache
    /// (`CreateTextureFromImage rc=-6683`), so the engine must paint through its
    /// direct GL fallback. This test is strict where that fallback is required and
    /// clearly skipped on a host where CV output is available instead.
    func testDirectFallbackWhenCVOutputUnavailable() async throws {
        executionTimeAllowance = 60
        let renderer = try RendererHarness()
        defer { renderer.close() }
        do {
            try renderer.start()
            renderer.engine.load(url: try fixtureURL(.primary), referer: nil, userAgent: nil)
            try await renderer.waitForImage(.primary)
            guard renderer.cvOutputUnavailable else {
                // Only a proven CV path justifies skipping; an unexpected allocation
                // failure must not be mistaken for CV availability.
                try renderer.requireCVOutputPath()
                throw XCTSkip("CVOpenGLESTextureCache is available here; direct fallback is not the active path")
            }
            try renderer.requireSoftwareDecoding()
            try renderer.requireDirectFallback()
            for index in 0..<6 {
                let frame = try XCTUnwrap(renderer.display())
                try check(frame.matches(.primary), "direct fallback frame \(index + 1): \(frame.summary)")
                try await Task.sleep(for: .milliseconds(16))
            }
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    /// CV-only allocation/reallocation and GL-binding restoration. This method is
    /// explicitly skipped on hosts without CVOpenGLESTextureCache, never silently
    /// converted into a pass.
    func testCVOutputAllocationResizeAndBlitRestoreCallerGLBindings() async throws {
        executionTimeAllowance = 45
        let renderer = try RendererHarness()
        defer { renderer.close() }
        do {
            try renderer.start()
            try renderer.skipUnlessCVOutputAvailable()
            // Give the render context a real decoded frame so the CV allocation and
            // blit path are exercised, not just a blank drawable.
            renderer.engine.load(url: try fixtureURL(.primary), referer: nil, userAgent: nil)
            try await renderer.waitForImage(.primary)
            try renderer.requireCVOutputPath()
            // First CV allocation, reallocation, then target reuse. Image
            // correctness is also asserted by the tests above.
            var previousCVSuccesses = renderer.cvBlitLogCount
            for (index, size) in [CGSize(width: 160, height: 96), CGSize(width: 320, height: 192),
                                  CGSize(width: 320, height: 192)].enumerated() {
                renderer.resize(to: size)
                try renderer.checkBindingRestoration()
                if index < 2 {
                    try check(renderer.cvBlitLogCount > previousCVSuccesses,
                              "CV output did not survive reallocation at \(size). \(renderer.diagnostics)")
                } else {
                    try check(renderer.cvBlitLogCount == previousCVSuccesses,
                              "CV target reuse unexpectedly reallocated at \(size). \(renderer.diagnostics)")
                }
                previousCVSuccesses = renderer.cvBlitLogCount
            }
            try renderer.requireCVOutputPath()
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    /// Background rendering lock: the callback must stop while locked, the same
    /// engine and loaded video must resume after unlock, and hwdec-current must not
    /// change (the test never reloads or toggles a hardware-decoder property).
    func testRenderingLockStopsAndResumesSameVideoWithoutHwdecChange() async throws {
        executionTimeAllowance = 60
        let renderer = try RendererHarness()
        defer { renderer.close() }
        do {
            try renderer.start()
            renderer.engine.load(url: try fixtureURL(.primary), referer: nil, userAgent: nil)
            try await renderer.waitForImage(.primary)
            try renderer.requireSoftwareDecoding()
            let hwdecBefore = hwdecCurrent(renderer.engine)
            let callbacksBefore = renderer.renderedFrameCount
            let sourceSizeBefore = renderer.sourceSize

            renderer.engine.setRenderingLocked(true)
            try check(renderer.engine.renderingLocked, "setRenderingLocked(true) did not take effect")
            try check(renderer.engine.onFrameRendered != nil,
                      "Locking must preserve the frame callback for later resume")
            for _ in 0..<5 {
                try check(try renderer.display() == nil, "A locked engine must not emit rendered frames")
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(renderer.renderedFrameCount == callbacksBefore,
                      "Frame callback fired while rendering was locked")
            renderer.engine.requestRender()
            try check(try renderer.display() == nil,
                      "requestRender() while locked must not emit a rendered frame")

            renderer.engine.setRenderingLocked(false)
            try check(!renderer.engine.renderingLocked, "setRenderingLocked(false) did not take effect")
            try await renderer.waitForImage(.primary)
            try check(renderer.renderedFrameCount > callbacksBefore,
                      "Frame callback did not resume after rendering unlock")
            try check(renderer.engine.onFrameRendered != nil,
                      "Frame callback was detached across lock/unlock")
            try check(renderer.sourceSize == sourceSizeBefore,
                      "Lock/unlock changed the loaded video size: \(String(describing: sourceSizeBefore)) -> \(String(describing: renderer.sourceSize))")
            try check(hwdecCurrent(renderer.engine) == hwdecBefore,
                      "Lock/unlock changed hwdec-current: \(hwdecBefore ?? "nil") -> \(hwdecCurrent(renderer.engine) ?? "nil")")
            try renderer.requireSoftwareDecoding()
            try renderer.requireActiveOutputPath()
            attachFrame(renderer, name: "software-after-render-lock-resume")
            try renderer.requireNoGLErrors()
        } catch {
            if error is XCTSkip { throw error }
            attachFailure(renderer, error: error)
            throw error
        }
    }

    /// Regression for the matcher itself. The real engine log contains
    /// `...纹理FBO=0→GLKView FBO=1 GPU blit...`; the old matcher looked for the
    /// contiguous phrase `GLKView GPU blit`, which can never match that log.
    func testCVOutputLogMatcherRequiresFBOTransition() {
        let actual = "输出路径：mpv→CVPixelBuffer(BGRA/Metal兼容)纹理FBO=0→GLKView FBO=1 GPU blit；160×96 internal_format=0 flip_y=0 blit_y=翻转 CV=0 FBO=complete"
        XCTAssertTrue(RenderLog.isCVBlit(actual), "Matcher must accept the real FBO transition log")
        XCTAssertFalse(
            RenderLog.isCVBlit("输出路径：mpv→CVPixelBuffer(BGRA/Metal兼容)纹理FBO=0 GLKView GPU blit"),
            "Matcher must not accept a log without the drawable FBO transition"
        )
    }

    private func fixtureURL(_ video: QuadrantVideo) throws -> URL {
        let bundle = Bundle(for: MPVRendererTests.self)
        let candidates = [
            bundle.url(forResource: video.rawValue, withExtension: "mp4", subdirectory: "Fixtures"),
            bundle.url(forResource: video.rawValue, withExtension: "mp4")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw RendererFailure(
                description: "Bundled fixture \(video.rawValue).mp4 is missing from \(bundle.bundlePath)"
            )
        }
        try check(FileManager.default.fileExists(atPath: url.path),
                  "Bundled fixture does not exist: \(url.path)")
        return url
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

@MainActor
private func hwdecCurrent(_ engine: MPVEngine) -> String? {
    guard let handle = engine.handle else { return nil }
    var raw: UnsafeMutablePointer<CChar>?
    guard mpv_get_property(handle, "hwdec-current", MPV_FORMAT_STRING, &raw) >= 0, let raw else {
        return nil
    }
    defer { mpv_free(raw) }
    let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private enum QuadrantVideo: String {
    case primary = "quadrants-primary"
    case alternate = "quadrants-alternate"

    static let width = 160
    static let height = 96

    /// RGB byte triples in top-left, top-right, bottom-left, bottom-right order.
    var colors: [[UInt8]] {
        switch self {
        case .primary:
            return [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        case .alternate:
            return [[0, 255, 255], [255, 0, 255], [255, 255, 255], [255, 128, 0]]
        }
    }
}

private enum RendererOutputPath {
    case cv
    case direct
    case none
}

private enum RenderLog {
    /// Match the actual engine line, not a contiguous phrase that the FBO text
    /// interrupts: `纹理FBO=<n>→GLKView FBO=<n> GPU blit`.
    static func isCVBlit(_ line: String) -> Bool {
        line.contains("输出路径：mpv→CVPixelBuffer")
            && line.range(of: #"FBO=\d+→GLKView FBO=\d+ GPU blit"#, options: .regularExpression) != nil
    }

    static func isDirectFallback(_ line: String) -> Bool {
        line.contains("输出路径：直绘回退")
    }

    static func isCVUnavailable(_ line: String) -> Bool {
        line.range(of: #"CreateTextureFromImage rc=-6683(?:\s|$)"#,
                   options: .regularExpression) != nil
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
        try check(engine.hardwareDecodeEnabled == false,
                  "Renderer tests must force software decoding (hardwareDecodeEnabled=false)")
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

    func waitForImage(_ video: QuadrantVideo) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        var matchingFrames = 0
        var attempt = 0
        print("[render-test] step=wait-for-image fixture=\(video.rawValue)")
        while clock.now < deadline {
            attempt += 1
            try Task.checkCancellation()
            let frame = try display()
            try requireNoGLErrors()
            if let loadError = snapshot?.loadError {
                throw RendererFailure(description: "Local video failed to load: \(loadError)")
            }
            if let decoderFailure = logs.first(where: {
                $0.contains("no decoders") || $0.contains("Failed to initialize a decoder")
            }) {
                throw RendererFailure(description: "Bundled H.264 fixture failed to decode: \(decoderFailure)")
            }
            let sourceReady = snapshot?.videoWidth == Double(QuadrantVideo.width)
                && snapshot?.videoHeight == Double(QuadrantVideo.height)
            print("[render-test] wait attempt=\(attempt) sourceReady=\(sourceReady) matches=\(frame?.matches(video) ?? false) \(frame?.summary ?? "no rendered callback")")
            if sourceReady, let frame, frame.matches(video) {
                matchingFrames += 1
                if matchingFrames == 3 { return }
            } else {
                matchingFrames = 0
            }
            // Yield MainActor to libmpv's queued updates and the UIKit run loop.
            // Never block the main thread with waitForExpectations or mpv_wait_event.
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RendererFailure(description: "Timed out waiting for three actual color-correct frames (\(video.rawValue)). \(diagnostics)")
    }

    var renderedFrameCount: Int { frameCount }

    /// Forget logs, callbacks and snapshots from the previous load. Used after
    /// stop()/reopen so path assertions cannot pass on a stale earlier frame.
    func resetPhase() {
        logs.removeAll()
        errors.removeAll()
        snapshot = nil
        thisDisplayFrame = nil
        lastFrame = nil
        frameCount = 0
        firstFrameCount = 0
    }

    var sourceSize: CGSize? {
        guard let snapshot, snapshot.videoWidth > 0, snapshot.videoHeight > 0 else { return nil }
        return CGSize(width: CGFloat(snapshot.videoWidth), height: CGFloat(snapshot.videoHeight))
    }

    var outputPath: RendererOutputPath {
        if logs.contains(where: RenderLog.isCVBlit) { return .cv }
        if logs.contains(where: RenderLog.isDirectFallback) { return .direct }
        return .none
    }

    var cvBlitLogCount: Int {
        logs.filter { RenderLog.isCVBlit($0) }.count
    }

    /// True only when CV output never succeeded and the engine reported the known
    /// texture incompatibility (-6683). A transient failure followed by a successful CV frame
    /// is not treated as "unavailable".
    var cvOutputUnavailable: Bool {
        !logs.contains(where: RenderLog.isCVBlit) && logs.contains(where: RenderLog.isCVUnavailable)
    }

    /// The simulator's Apple Software Renderer cannot create a CVOpenGLESTextureCache
    /// texture (`CreateTextureFromImage` reports -6683); that path is device-only.
    /// This is a real XCTSkip, not a silent pass.
    func skipUnlessCVOutputAvailable() throws {
        resize(to: CGSize(width: 160, height: 96))
        _ = try display()
        if cvOutputUnavailable {
            throw XCTSkip("CVOpenGLESTextureCache is unavailable on this host (CreateTextureFromImage rc=-6683); CV pixel-buffer output must be verified on a device")
        }
    }

    func requireActiveOutputPath() throws {
        switch outputPath {
        case .cv:
            try requireCVOutputPath()
        case .direct:
            try requireDirectFallback()
        case .none:
            throw RendererFailure(description: "Neither CV nor direct output path was logged. \(diagnostics)")
        }
    }

    func requireCVOutputPath() throws {
        let present = logs.contains(where: RenderLog.isCVBlit)
        print("[render-test] successful CVPixelBuffer→GLKView FBO transition log present=\(present)")
        try check(present,
                  "No successful CVPixelBuffer → GLKView GPU blit diagnostic; direct rendering is not this test's target. \(diagnostics)")
    }

    func requireDirectFallback() throws {
        let direct = logs.contains(where: RenderLog.isDirectFallback)
        let cv = logs.contains(where: RenderLog.isCVBlit)
        print("[render-test] direct fallback log present=\(direct) CV blit present=\(cv)")
        try check(direct, "No direct GL fallback log; CV unavailable must fall back instead of going black. \(diagnostics)")
        try check(!cv, "CV output unexpectedly succeeded; direct fallback is not the active path")
    }

    func requireSoftwareDecoding() throws {
        let value = hwdecCurrent(engine)
        try check(engine.hardwareDecodeEnabled == false,
                  "hardwareDecodeEnabled must stay false in renderer tests")
        try check(value == "no",
                  "Renderer tests require software decoding, got hwdec-current=\(value ?? "nil")")
    }

    func requireNoGLErrors() throws {
        let failures = logs.filter { $0.contains("GL 排空：") || $0.contains("OpenGL error") }
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
        "outputPath=\(outputPath) cvUnavailable=\(cvOutputUnavailable) "
            + "requested=\(requestedSize) drawable=\(view.drawableWidth)x\(view.drawableHeight) "
            + "callbacks=\(frameCount) firstFrameCallbacks=\(firstFrameCount) "
            + "source=\(snapshot?.videoWidth ?? 0)x\(snapshot?.videoHeight ?? 0) "
            + "hwdec=\(hwdecCurrent(engine) ?? "nil") "
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
    /// glReadPixels rows start at the drawable's bottom, unlike the video fixture.
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
        let scale = min(Double(width) / Double(QuadrantVideo.width), Double(height) / Double(QuadrantVideo.height))
        let imageWidth = Double(QuadrantVideo.width) * scale
        let imageHeight = Double(QuadrantVideo.height) * scale
        let left = (Double(width) - imageWidth) / 2
        let top = (Double(height) - imageHeight) / 2
        return [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map {
            (min(max(Int(left + imageWidth * $0.0), 2), width - 3),
             min(max(Int(top + imageHeight * $0.1), 2), height - 3))
        }
    }

    func matches(_ video: QuadrantVideo) -> Bool {
        let expected = video.colors
        for (index, center) in sampleCenters.enumerated() {
            // Nine pixels well inside each quadrant avoid filtering-edge artifacts;
            // channel tolerance allows H.264 YUV 4:2:0 color-conversion rounding.
            for dy in -1...1 {
                for dx in -1...1 {
                    let actual = pixel(x: center.x + dx, topY: center.y + dy)
                    if !(0..<3).allSatisfy({ abs(Int(actual[$0]) - Int(expected[index][$0])) <= 48 }) { return false }
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
