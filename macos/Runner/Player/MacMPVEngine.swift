//
//  MacMPVEngine.swift
//  Kazumi (macOS)
//
//  macOS 侧的 mpv 内核：直接对 Libmpv 的 C API 说话，绑定方式和 iOS 那份一致
//  —— `wid` 指向一个 CAMetalLayer，`vo=gpu-next` 经 MoltenVK 直接提交 drawable，
//  不建 mpv_render_context。
//
//  比 iOS 的 `MPVEngine`（1800 行）小得多：那一份里投屏、画中画、弹幕叠加、
//  断流自愈、命令 FIFO、画中画帧统计都揉在一起。macOS 这一版只做「打开就播」
//  这一圈：起播 / 暂停 / 跳转 / 音量 / 倍速 / 全屏。等 macOS 页面移植到对应
//  阶段再往上叠，别在这里先把复杂度抄一遍。
//
//  选项取值照抄 iOS：起播先 1 秒预取窗口出画面，FILE_LOADED 之后再放开长缓存；
//  UA / Referer 走 mpv 自己的选项，Cookie 才进 http-header-fields。
//

import Foundation
import Libmpv
import Observation
import QuartzCore

/// 一次播放请求：地址 + 规则站要的三个可选请求头。
struct MacPlaybackRequest: Equatable, Sendable {
    var url: URL
    var referer: String?
    var userAgent: String?
    var cookie: String?
}

/// 引擎对外的一份状态快照（事件线程写、主线程读）。
struct MacPlaybackState: Equatable, Sendable {
    var position: Double = 0
    var duration: Double = 0
    var isPaused: Bool = true
    var endOfFile: Bool = false
    /// mpv 的 `core-idle`：缓冲/等数据时空转。
    var isBuffering: Bool = false
    var hasVideo: Bool = false
    /// 失败原因；正常播放时为 nil。
    var message: String?
}

// MARK: - 内核线程

/// mpv 句柄的持有者。命令走一条串行队列（同步 `mpv_command` 可能等 demuxer，
/// 不能堵事件循环），事件走另一条队列。
final class MacMPVWorker: @unchecked Sendable {
    var onState: (@Sendable (MacPlaybackState) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private let commandQueue = DispatchQueue(label: "kazumi.mpv.mac.command", qos: .userInitiated)
    private let eventQueue = DispatchQueue(label: "kazumi.mpv.mac.event", qos: .userInteractive)
    private var handle: OpaquePointer?
    private var currentRequest: MacPlaybackRequest?
    private var stopped = false
    private var lastPublished = MacPlaybackState()
    private var message: String?

    // 与 iOS 侧同一套：1500 MiB 上限，时间窗口起播 1 秒、出画面后放长。
    private static let cacheBytes = 1500 * 1024 * 1024

    // MARK: 生命周期

    /// 绑定 CAMetalLayer 并起内核。只会成功一次。
    func start(binding layer: CAMetalLayer) {
        commandQueue.sync {
            guard handle == nil else { return }
            guard let mpv = mpv_create() else {
                onLog?("mpv_create 失败")
                return
            }
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            let widStatus = mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
            guard widStatus >= 0 else {
                onLog?("绑定 CAMetalLayer 失败：\(Self.errorText(widStatus))")
                mpv_terminate_destroy(mpv)
                return
            }

            // 渲染：gpu-next + Vulkan(MoltenVK) 直接输出到 CAMetalLayer，和 iOS 一致。
            setOption(mpv, "vo", "gpu-next")
            setOption(mpv, "gpu-api", "vulkan")
            setOption(mpv, "gpu-context", "moltenvk")
            setOption(mpv, "fbo-format", "rgba16hf")
            // 硬解：macOS 上就是 VideoToolbox（iOS 那条按画中画需求算出来的逻辑不适用）。
            setOption(mpv, "hwdec", "videotoolbox")
            setOption(mpv, "hwdec-codecs", "all")

            // 只留我们自己的控件。
            setOption(mpv, "input-default-bindings", "no")
            setOption(mpv, "input-vo-keyboard", "no")
            setOption(mpv, "terminal", "no")
            setOption(mpv, "osd-level", "0")
            setOption(mpv, "keep-open", "yes")
            setOption(mpv, "idle", "yes")
            setOption(mpv, "audio-display", "no")
            setOption(mpv, "scale", "spline36")
            setOption(mpv, "cscale", "spline36")
            setOption(mpv, "dscale", "mitchell")
            setOption(mpv, "subs-fallback", "yes")
            setOption(mpv, "deband", "no")
            setOption(mpv, "dither-depth", "no")
            setOption(mpv, "screenshot-sw", "yes")

            setOption(mpv, "demuxer-max-bytes", String(Self.cacheBytes))
            setOption(mpv, "demuxer-max-back-bytes", String(Self.cacheBytes))
            setOption(mpv, "cache-secs", "1")
            setOption(mpv, "demuxer-readahead-secs", "1")
            // HLS keepalive 复用会被源站回 400 / EOF：每个分片新建连接 + 短超时 + 允许重连。
            setOption(mpv, "network-timeout", "10")
            setOption(mpv, "demuxer-lavf-o", "http_persistent=0")
            setOption(
                mpv,
                "stream-lavf-o",
                "multiple_requests=0,reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=7"
            )

            let initStatus = mpv_initialize(mpv)
            guard initStatus >= 0 else {
                onLog?("mpv_initialize 失败：\(Self.errorText(initStatus))")
                mpv_terminate_destroy(mpv)
                return
            }

            let logStatus = mpv_request_log_messages(mpv, "warn")
            if logStatus < 0 {
                onLog?("内核日志订阅失败：\(Self.errorText(logStatus))")
            }
            let clientVersion = mpv_client_api_version()
            onLog?("内核 \(stringProperty(mpv, "mpv-version") ?? "未知") / 客户端 API \(clientVersion >> 16).\(clientVersion & 0xffff)")

            handle = mpv
            stopped = false
            eventQueue.async { [self] in eventLoop(mpv) }
        }
    }

    func stop() {
        commandQueue.sync {
            guard let mpv = handle else { return }
            stopped = true
            handle = nil
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: 命令

    func load(_ request: MacPlaybackRequest) {
        commandQueue.async { [self] in
            guard let mpv = handle else { return }
            currentRequest = request
            // UA / Referer 用 mpv 自己的选项：拼进 http-header-fields 容易被整条塞成
            // 一个带换行的畸形头（iOS 侧 LP 5504/5506 踩过）。
            mpv_set_property_string(mpv, "user-agent", request.userAgent ?? "")
            mpv_set_property_string(mpv, "referrer", request.referer ?? "")
            if let cookie = request.cookie, !cookie.isEmpty {
                mpv_set_property_string(mpv, "http-header-fields", "Cookie: \(cookie)")
            } else {
                mpv_set_property_string(mpv, "http-header-fields", "")
            }
            // 起播阶段先给 1 秒窗口，FILE_LOADED 之后放开（见 eventLoop）。
            mpv_set_property_string(mpv, "cache-secs", "1")
            mpv_set_property_string(mpv, "demuxer-readahead-secs", "1")
            mpv_set_property_string(mpv, "pause", "no")
            run(mpv, ["loadfile", request.url.absoluteString, "replace"])
        }
    }

    func setPaused(_ paused: Bool) {
        commandQueue.async { [self] in
            guard let mpv = handle else { return }
            mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
        }
    }

    func seek(to seconds: Double) {
        commandQueue.async { [self] in
            guard let mpv = handle, seconds.isFinite else { return }
            run(mpv, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds)), "absolute"])
        }
    }

    func skip(by seconds: Double) {
        commandQueue.async { [self] in
            guard let mpv = handle else { return }
            run(mpv, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds), "relative"])
        }
    }

    func setVolume(_ volume: Double) {
        commandQueue.async { [self] in
            guard let mpv = handle else { return }
            mpv_set_property_string(mpv, "volume", String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), min(max(volume, 0), 100)))
        }
    }

    func setSpeed(_ speed: Double) {
        commandQueue.async { [self] in
            guard let mpv = handle else { return }
            var value = min(max(speed, 0.25), 4)
            mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &value)
        }
    }

    // MARK: 事件循环

    private func eventLoop(_ mpv: OpaquePointer) {
        while !stopped {
            guard let event = mpv_wait_event(mpv, 0.2) else { break }
            let id = event.pointee.event_id
            if id == MPV_EVENT_SHUTDOWN { break }
            if id == MPV_EVENT_END_FILE, let raw = event.pointee.data {
                let endFile = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(raw)).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    message = "播放失败：\(Self.errorText(endFile.error))"
                }
            }
            if id == MPV_EVENT_FILE_LOADED {
                message = nil
                // 画面出来了，放开长缓存（iOS 侧 promoteCacheAfterFirstFrame 的同一手）。
                mpv_set_property_string(mpv, "cache-secs", "36000")
                mpv_set_property_string(mpv, "demuxer-readahead-secs", "5")
            }
            publish(mpv)
        }
    }

    private func publish(_ mpv: OpaquePointer) {
        var position: Double = 0
        var duration: Double = 0
        var paused: Int32 = 1
        var endOfFile: Int32 = 0
        var idle: Int32 = 0
        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        mpv_get_property(mpv, "eof-reached", MPV_FORMAT_FLAG, &endOfFile)
        mpv_get_property(mpv, "core-idle", MPV_FORMAT_FLAG, &idle)
        let hasVideo = stringProperty(mpv, "video-format") != nil

        let next = MacPlaybackState(
            position: position.isFinite ? position : 0,
            duration: duration.isFinite ? duration : 0,
            isPaused: paused != 0,
            endOfFile: endOfFile != 0,
            isBuffering: idle != 0,
            hasVideo: hasVideo,
            message: message
        )
        guard next != lastPublished else { return }
        lastPublished = next
        onState?(next)
    }

    // MARK: 小工具

    private func setOption(_ mpv: OpaquePointer, _ name: String, _ value: String) {
        let status = mpv_set_option_string(mpv, name, value)
        if status < 0 {
            onLog?("选项 \(name)=\(value) 设置失败：\(Self.errorText(status))")
        }
    }

    private func run(_ mpv: OpaquePointer, _ arguments: [String]) {
        // 和 iOS 侧下命令的写法一致：strdup 出来的指针在调用期间有效，调用完再释放。
        var strings: [UnsafeMutablePointer<CChar>] = []
        for argument in arguments {
            strings.append(strdup(argument))
        }
        var pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        pointers.append(nil)
        let status = mpv_command(mpv, &pointers)
        for string in strings { free(string) }
        if status < 0 {
            onLog?("命令 \(arguments.first ?? "?") 失败：\(Self.errorText(status))")
        }
    }

    private func stringProperty(_ mpv: OpaquePointer, _ name: String) -> String? {
        guard let raw = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(raw) }
        let text = String(cString: raw)
        return text.isEmpty ? nil : text
    }

    private static func errorText(_ status: Int32) -> String {
        String(cString: mpv_error_string(status))
    }
}

// MARK: - 主线程外壳

/// SwiftUI 直接用的那一层：持有 worker，把状态搬到主线程。
@MainActor
@Observable
final class MacMPVEngine {
    private(set) var state = MacPlaybackState()
    private(set) var attached = false
    private(set) var currentTitle: String?

    var volume: Double = 100 {
        didSet { worker.setVolume(volume) }
    }

    var speed: Double = 1 {
        didSet { worker.setSpeed(speed) }
    }

    @ObservationIgnored private let worker = MacMPVWorker()

    init() {
        worker.onState = { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
        worker.onLog = { message in
            KazumiLog.player.notice("mac mpv: \(message, privacy: .public)")
        }
    }

    /// 视图进窗口后绑一次 CAMetalLayer；重复调用不会重建内核。
    func attach(_ layer: CAMetalLayer) {
        guard !attached else { return }
        attached = true
        worker.start(binding: layer)
    }

    func play(_ request: MacPlaybackRequest) {
        currentTitle = request.url.lastPathComponent
        worker.load(request)
        worker.setVolume(volume)
        worker.setSpeed(speed)
    }

    func togglePause() {
        worker.setPaused(!state.isPaused)
    }

    func seek(to seconds: Double) {
        worker.seek(to: seconds)
    }

    func skip(by seconds: Double) {
        worker.skip(by: seconds)
    }

    func stop() {
        worker.stop()
        attached = false
        state = MacPlaybackState()
        currentTitle = nil
    }
}