//
//  MPVEngine.swift
//  Kazumi
//
//  mpv 内核（LP 3671–3673：放弃 KSPlayer，换 MPVKit + Anime4K）。
//
//  MPVKit 只给 libmpv 的 C 接口，这一层是给它套的 Swift 壳：
//   * 建 mpv 句柄、设选项、按集 loadfile；
//   * 建 OpenGL ES 渲染上下文（GLSL 着色器只认这条渲染路径，Metal 那条不认，
//     而且 mpv 的 Metal 是补丁版）；
//   * 把 time-pos / duration / pause / eof 这些属性推给上层；
//   * 命令封装：seek、倍速、挂/摘 Anime4K 着色器、截图。
//
//  参考实现：MPVKit 自带 demo 的 MPVViewController，以及 Kazumi 现在 iOS 上
//  真在跑的那份 media_kit_video（TextureHW.swift，同样是 OPENGL + EAGLContext）。
//

import Foundation
import GLKit
import ImageIO
import Libmpv
import OpenGLES
import UIKit

/// 上层的播放时钟接口：弹幕层只关心「现在播到哪」「在不在播」。
@MainActor
protocol PlayerClockProvider: AnyObject {
    var currentPlaybackTime: Double { get }
    var isPlayingNow: Bool { get }
    /// 画面真的走起来了（首帧 + 进度过 0.15）。换集/停止时由 `PlayerSurfaceModel` 自己复位。
    /// 弹幕层拿它当「起播」判据（LP 5033）：`isPlayingNow` 只表示内核没暂停，
    /// 加载阶段也为 true，用它放行会提前放 0 秒那批弹幕。
    var hasStartedPlayback: Bool { get }
}

/// 当前文件的编码规格，给「播放信息」半屏页用。
/// 每一项都是「拿得到才有值」，页面拿不到的补「—」。
struct PlaybackInfo: Sendable, Equatable {
    var videoCodec: String? = nil
    var resolution: String? = nil
    var frameRate: String? = nil
    var videoBitrate: String? = nil
    var audioCodec: String? = nil
    var audioChannels: String? = nil
    var sampleRate: String? = nil
    var container: String? = nil
}

/// 一次属性快照，从 mpv 的事件线程递回主线程。
/// 一次加载走到哪一步。由 mpv 事件推，不由计时器推（LP 4818）。
///
/// `FILE_LOADED` 只说明文件打开了，不代表首帧已经画上屏；真正的判据是本进程
/// 渲染回调里那一帧（见 `MPVEngine.render(in:)`）。所以中间要有
/// `awaitingFirstFrame` 这一档，别把两件事合成一件。
enum MPVLoadPhase: Sendable {
    /// 没有文件在加载（播放器刚建好，或者这一集已经结束）。
    case idle
    /// 收到 START_FILE：正在打开 / 连源。
    case opening
    /// FILE_LOADED / PLAYBACK_RESTART 之后：等第一帧真的画上屏。
    case awaitingFirstFrame
    /// 第一帧已经在本进程的渲染回调里画过。
    case playing
}

struct MPVSnapshot: Sendable {
    var time: Double
    var duration: Double
    var isPaused: Bool
    var isIdle: Bool
    var hasVideo: Bool
    var ended: Bool
    /// 这一集加载失败时的原因（源挂了、404、403 之类）；成功时是 nil。
    var loadError: String?
    /// 视频的显示尺寸（已算过像素宽高比，mpv 的 dwidth/dheight）。
    /// 弹幕层与控制层要用它算出画面在容器里的真实矩形。
    var videoWidth: Double = 0
    var videoHeight: Double = 0
    /// 当前下载速度（字节/秒）。没在下载（缓存够、本地文件、播完）时是 0。
    /// 加载符号下面那行网速用它（LP 4810）。
    var downloadSpeed: Double = 0
    /// 内核正在 seek（拖进度、换集）。加载符号在这段时间也要转，
    /// 不然拖完进度就是一整块静止的黑屏。
    var isSeeking: Bool = false
    /// 这次加载走到哪一步了（LP 4818）。
    var loadPhase: MPVLoadPhase = .idle
}

@MainActor
final class MPVEngine {
    private(set) var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    /// 画面和渲染上下文必须共用这一个：两个上下文各画各的，屏幕上什么都出不来。
    let glContext: EAGLContext
    private var pump: MPVEventPump?

    /// 渲染视图（GL 那一层），由容器在 makeUIView 里塞进来。
    weak var glView: MPVGLView?

    var onSnapshot: ((MPVSnapshot) -> Void)?
    /// 这一集**第一帧真的画上屏了**（不是「拿到 video-params」）。
    /// 加载符号要靠它才能一直转到画面出来为止（LP 2026-10-28 第 4 条）。
    var onFirstFrame: (() -> Void)?
    /// 本次加载是否已经报过首帧。
    private var reportedFirstFrame = false
    var onLog: ((String) -> Void)?

    /// 硬件解码开不开：容器按设置页那颗开关传进来，只在建内核时读一次
    /// （`hwdec` 对已经打开的文件不生效，换集才换得过来）。
    var hardwareDecodeEnabled = true

    /// 解复用缓存大小（字节）。进来之前由容器按低内存模式的档位算好；
    /// 之后档位或网络变了就调 `applyCacheSize(_:)` 立刻改，不用重建内核。
    private var cacheBytes = PlaybackCachePolicy.fullBytes

    /// 换解复用缓存大小：启动前设属性，启动后改属性都走这里。
    ///
    /// 内核已经在跑的时候改这一项不会重开文件，只影响后面还要读多少——
    /// 缓冲被打空的当下改小也会立刻生效，所以「移动数据→低内存」不用重开这一集。
    func applyCacheSize(_ bytes: Int) {
        cacheBytes = bytes
        guard let mpv = handle else { return }
        let value = String(bytes)
        mpv_set_property_string(mpv, "demuxer-max-bytes", value)
        mpv_set_property_string(mpv, "demuxer-max-back-bytes", value)
    }

    /// 内联画面刚画完时同步回调（主线程、GL 上下文 current）。
    /// 画中画拿这一帧去 `glBlitFramebuffer` 到 CVPixelBuffer，不需要第二个 mpv 上下文。
    var onFrameRendered: (@MainActor (GLint, Int, Int, Double, Double) -> Void)?

    private var lastSnapshot = MPVSnapshot(
        time: 0, duration: 0, isPaused: true, isIdle: true, hasVideo: false, ended: false
    )

    /// 上一次记过的画面几何，变了才写日志（每帧写会把日志冲爆）。
    private var lastGeometry = ""

    /// 已下发、还没回执的异步命令。
    private var pendingCommands: [UInt64: CommandRequest] = [:]
    /// 正在等的 `screenshot-raw`：回执回来时按命令号把原始帧交给对应的等待者。
    ///
    /// 用字典而不是单个槽：连点两下截图时第二下会把第一下的等待者挤掉，
    /// 被挤掉那条 `withCheckedContinuation` 再也没人 resume（它的超时兜底
    /// 拿的也是自己的 id，比不中），那条 task 就永久挂在那儿（Fuck 5017）。
    private var rawShotWaiters: [UInt64: CheckedContinuation<MPVRawFrame?, Never>] = [:]
    private var nextCommandID: UInt64 = 1
    /// 截图回执的超时。mpv 要从关键帧重解，网络流上慢；但这是单条命令、
    /// 回执到了才算，不用像原来那样两条路各等一轮，也不用给到几十秒。
    private static let screenshotTimeoutSeconds: Double = 10

    init() {
        glContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)!
    }

    // MARK: - 生命周期

    /// 建 mpv 与渲染上下文。只做一次，换集走 `load(url:)`。
    func start() {
        guard handle == nil else { return }
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(nil) }

        guard let mpv = mpv_create() else {
            log("mpv_create 失败")
            return
        }
        handle = mpv

        // 只留我们自己的控件：mpv 自带的 OSC、输入绑定、终端输出全关掉。
        setOption("vo", "libmpv")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("terminal", "no")
        setOption("osd-level", "0")
        setOption("keep-open", "yes")
        setOption("idle", "yes")
        setOption("audio-display", "no")
        // 独占音频：mpv 的 audiounit 输出每次初始化音频都会自己重设一次会话类别，
        // 而它默认加的是 `mixWithOthers`——混音的会话不会被 iOS 当成「正在播放」，
        // 控制中心 / 锁屏那张卡就永远不出来。开了这个，它不再加 mixWithOthers。
        setOption("audio-exclusive", "yes")
        // 保持现有硬解策略：模拟器 no，真机按开关使用 auto-safe。
        setOption("hwdec", Self.hwdec(enabled: hardwareDecodeEnabled))
        // 逐帧交给我们的 GL 视图，不走独立窗口。渲染 API 在
        // `mpv_render_context_create` 里指定，不用再设 gpu-api（设了会被拒）。
        // 不用 gpu-hq：它的 ewa_lanczos + 去色带很吃 GPU，会掉帧；
        // 真要画质靠 Anime4K 着色器，基础缩放用双线性就够。
        // spline36：动漫放大到 2x 时比双线性明显清楚，1080p 在手机上开销扛得住
        // （Colo 3701；真机还卡再退回双线性）。
        setOption("scale", "spline36")
        setOption("cscale", "spline36")
        setOption("deband", "no")
        setOption("dither-depth", "no")
        // 截图一律走 mpv 的软件那条路（LP 5002）。
        //
        // 我们的 VO 是 `libmpv`（渲染 API），真机上 `screenshot-to-file … video`
        // 那条走 VO 的路一直回失败，于是每次都退到「读屏幕那一帧」：只有屏幕分辨率、
        // 还被我们按画面矩形裁过一刀，存下来根本不是完整视频帧。软件那条直接拿解码后的
        // 整帧，尺寸是片源分辨率，也不受 fit/crop/stretch 这些填充方式影响。
        setOption("screenshot-sw", "yes")
        // 解复用缓存对齐 main（`playback_cache_policy.dart`）：常规 1500 MiB，
        // 低内存模式降到 2 MiB（LP 5547）。取多少由 `PlaybackCachePolicy` 按档位和
        // 当前网络算，之后设置或网络变了走 `applyCacheSize()` 立刻改。
        setOption("demuxer-max-bytes", String(cacheBytes))
        setOption("demuxer-max-back-bytes", String(cacheBytes))

        let initStatus = mpv_initialize(mpv)
        guard initStatus >= 0 else {
            log("mpv_initialize 失败：\(String(cString: mpv_error_string(initStatus)))")
            return
        }

        // C API 只接受一个级别，不接受 msg-level 的分模块语法。
        // v 收集解码 / 色彩 / 渲染；接收端白名单、脱敏、限流，不开 HTTP debug。
        let logStatus = mpv_request_log_messages(mpv, "v")
        if logStatus >= 0 {
            log("内核日志订阅成功：级别=v rc=\(logStatus)")
        } else {
            log("内核日志订阅失败：级别=v rc=\(logStatus)（\(String(cString: mpv_error_string(logStatus)))）")
        }
        let clientVersion = mpv_client_api_version()
        log("内核版本 \(stringProperty("mpv-version") ?? "未知") / 客户端 API \(clientVersion >> 16).\(clientVersion & 0xffff)")

        setupRenderContext(mpv)
        setupEvents(mpv)
    }

    private func setupRenderContext(_ mpv: OpaquePointer) {
        let api = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
        )
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in MPVEngine.procAddress(name) },
            get_proc_address_ctx: nil
        )
        let created: Int32 = withUnsafeMutablePointer(to: &initParams) { paramsPtr in
            var params = [
                mpv_render_param(
                    type: MPV_RENDER_PARAM_API_TYPE,
                    data: api
                ),
                mpv_render_param(
                    type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                    data: UnsafeMutableRawPointer(paramsPtr)
                ),
                mpv_render_param()
            ]
            return mpv_render_context_create(&renderContext, mpv, &params)
        }
        guard created >= 0, let renderContext else {
            log("mpv 渲染上下文建不起来：\(String(cString: mpv_error_string(created)))")
            return
        }
        log("GL \(glString(GL_RENDERER)) / \(glString(GL_VERSION))")
        self.renderContext = renderContext
        mpv_render_context_set_update_callback(
            renderContext,
            kazumiMPVRenderUpdate,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func setupEvents(_ mpv: OpaquePointer) {
        let pump = MPVEventPump(mpv: mpv) { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        } log: { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        pump.onCommandReply = { [weak self] id, error, rawFrame in
            Task { @MainActor in
                self?.finishCommand(id: id, error: error)
                self?.finishRawShot(id: id, frame: error >= 0 ? rawFrame : nil)
            }
        }
        self.pump = pump
        pump.start()
    }

    private func apply(_ snapshot: MPVSnapshot) {
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    // MARK: - 播放

    /// 换集 / 首次起播。UA 与 Referer 规则站点校验，缺一不可。
    func load(url: URL, referer: String?, userAgent: String?, cookie: String? = nil) {
        guard handle != nil else { return }
        // UA 和 Referer 走 mpv 自己的选项，不拼进 `http-header-fields`（LP 5504/5506）：
        // 那个选项是一串字段，拼字符串再交给 ffmpeg 时容易整条塞成一个带换行的头，
        // 服务器见到畸形请求就回 400——本地 curl 同样的头 200，手机内核 400 的差别
        // 就在这儿。UA / Referer 有专门选项，让库自己去拼。
        setOptionForPlayback("user-agent", userAgent ?? "")
        setOptionForPlayback("referrer", referer ?? "")
        // 只有 Cookie 非空时才用 header 字段（没有专门选项可替）。
        if let cookie, !cookie.isEmpty {
            setOptionForPlayback("http-header-fields", "Cookie: \(cookie)")
        } else {
            setOptionForPlayback("http-header-fields", "")
        }
        // 内核起播前把这次带过去的头记一行（Fuck 5487）：登录态有没有送到，
        // 看一眼运行日志就知道，不用在界面上猜是站点限了还是 Cookie 没带上。
        // 只记名字和个数，值不落盘。
        let cookieCount = (cookie ?? "").split(separator: ";").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        KazumiLogBuffer.shared.append(
            "内核起播 host=\(url.host() ?? "-") cookie=\(cookieCount)个 referer=\(referer == nil ? "无" : "有") ua=\(userAgent == nil ? "无" : "有")",
            category: .player
        )
        // 换集 / 重试都按「接着看」处理：内核里 pause 可能还是上一集留下的 true，
        // 不显式放开，加载完了就停在那儿黑着（LP 2026-10-28 第 4 条「不会自动播放」）。
        reportedFirstFrame = false
        // 换集 / 重新加载 / 换源：从这一刻起就是「在加载」，别等 mpv 的 START_FILE
        // 事件（那要等它自己排到），界面上的圈要立刻转起来。
        pump?.beginLoad()
        setFlag("pause", false)
        command("loadfile", [url.absoluteString, "replace"])
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    /// 前台该用的硬解档位。
    ///
    /// 开关关掉就纯软解；开着用 `auto-safe`——与 main 一致（LP 5549/5551/5577：
    /// main 上一直是这一档，颜色正常）。
    ///
    /// 模拟器没有硬解，开与关都是 `no`。
    static func hwdec(enabled: Bool) -> String {
        #if targetEnvironment(simulator)
        return "no"
        #else
        return enabled ? "auto-safe" : "no"
        #endif
    }

    /// 后台渲染锁：iOS 在后台不许碰 OpenGL ES，切后台后真机日志里一直在报
    /// `libmpv_render: OpenGL error INVALID_ENUM`（LP 4978 第 2 条）。
    ///
    /// 锁上以后一律不叫 mpv 画、也不排重绘；回前台解开时补一次重绘，画面
    /// 当场接上。画中画在跑的时候不上锁——它的帧正是靠这条渲染路径出的。
    private(set) var renderingLocked = false

    func setRenderingLocked(_ locked: Bool) {
        guard locked != renderingLocked else { return }
        renderingLocked = locked
        log(locked ? "画面：后台渲染锁已上" : "画面：后台渲染锁已解")
        if !locked {
            glView?.setNeedsDisplay()
        }
    }

    /// 叫 GL 视图重画一帧；锁着的时候直接丢掉（别在后台碰 GL）。
    fileprivate func requestDisplay() {
        guard !renderingLocked else { return }
        glView?.setNeedsDisplay()
    }

    /// 让 GLKView 立刻重画当前帧（回前台接回内联画面时用）。
    func requestRender() {
        requestDisplay()
    }

    /// 画中画需要自己驱动出帧时调（后台 UIKit 不会自动给 GLKView 发 draw）。
    /// 直接绑 GLKView 的 drawable 走正常渲染 + 首帧钩子；不 present，
    /// 因为这一帧的消费者是 PiP 的 sample buffer，不是屏幕。
    func renderFrameForPictureInPicture() {
        guard let glView, renderContext != nil else { return }
        let width = glView.drawableWidth
        let height = glView.drawableHeight
        guard width > 0, height > 0 else { return }
        EAGLContext.setCurrent(glContext)
        glView.bindDrawable()
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        render(in: glView)
    }

    func setSpeed(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        var value = Double(rate)
        mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        command("seek", [String(format: "%.3f", time), "absolute"])
    }

    /// 已缓冲到的位置（进度条的缓冲段）。读不到就返回 0。
    var playableTime: Double {
        var value = Double(0)
        guard mpv_get_property(handle, "demuxer-cache-time", MPV_FORMAT_DOUBLE, &value) >= 0 else {
            return 0
        }
        return value.isFinite ? value : 0
    }

    // MARK: - 视频信息

    /// 这一集文件的编码规格。
    ///
    /// 一律按字符串读：mpv 会把数值属性转成文本，省得每种类型各写一遍解析。
    /// 取不到的属性留 nil，由页面补「—」。
    func playbackInfo() -> PlaybackInfo {
        guard handle != nil else { return PlaybackInfo() }
        var info = PlaybackInfo()
        info.videoCodec = stringProperty("video-codec")
        if let width = stringProperty("width").flatMap({ Int($0) }),
           let height = stringProperty("height").flatMap({ Int($0) }) {
            info.resolution = "\(width)×\(height)"
        }
        info.frameRate = stringProperty("container-fps").flatMap(Self.formatFrameRate)
        info.videoBitrate = stringProperty("video-bitrate").flatMap(Self.formatBitrate)
        info.audioCodec = stringProperty("audio-codec-name")
        info.audioChannels = stringProperty("audio-params/channel-count")
        info.sampleRate = stringProperty("audio-params/samplerate").flatMap(Self.formatSampleRate)
        info.container = stringProperty("file-format")
        return info
    }

    /// mpv 现在真正挂着的着色器个数（读 `glsl-shaders` 属性本身，不是我们打算挂几个）。
    /// 「播放信息」里那一行用它，才能分清「没挂上」和「挂了但看不出」。
    func appliedShaderCount() -> Int {
        guard let text = stringProperty("glsl-shaders") else { return 0 }
        return text.split(separator: ",").filter { !$0.isEmpty }.count
    }

    /// 读一个字符串属性。mpv 分配的那块内存必须还回去，否则每开一次信息页漏一点。
    private func stringProperty(_ name: String) -> String? {
        var raw: UnsafeMutablePointer<CChar>?
        guard mpv_get_property(handle, name, MPV_FORMAT_STRING, &raw) >= 0, let raw else {
            return nil
        }
        defer { mpv_free(raw) }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 24.000000 → "24 fps"，23.976 → "23.976 fps"：去掉小数末尾的零，最多留三位。
    private static func formatFrameRate(_ text: String) -> String? {
        guard let fps = Double(text), fps > 0 else { return nil }
        var value = String(format: "%.3f", fps)
        if value.contains(".") {
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
        }
        return "\(value) fps"
    }

    /// mpv 给的是 bps，按 kbps 取整显示（不写小数）。
    private static func formatBitrate(_ text: String) -> String? {
        guard let bps = Double(text), bps > 0 else { return nil }
        return String(format: "%.0f kbps", bps / 1000)
    }

    /// 48000 → "48 kHz"，44100 → "44.1 kHz"。
    private static func formatSampleRate(_ text: String) -> String? {
        guard let rate = Double(text), rate > 0 else { return nil }
        let khz = rate / 1000
        let value = rate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(value) kHz"
    }

    // MARK: - 超分着色器

    /// 挂上一整串 Anime4K 着色器，顺序就是数组顺序（照 main 的管线）。
    func setShaders(_ paths: [String]) {
        if paths.isEmpty {
            command("change-list", ["glsl-shaders", "clr", ""])
        } else {
            command("change-list", ["glsl-shaders", "set", paths.joined(separator: ",")])
        }
    }

    // MARK: - 截图

    /// 抓当前这一帧，mpv 直接出 PNG 写临时文件（LP 4695）。
    ///
    /// 返回 `(文件, 给用户看的那句话)`：拿到文件时那句是成功细节（尺寸、多少毫秒），
    /// 没拿到时那句就是失败原因，直接进 toast。
    ///
    /// 跟原来那版的区别：
    ///  1) 走 `mpv_command_async` + `COMMAND_REPLY`，命令真回复了才算成，不再用
    ///     「每 50 毫秒看一眼文件在不在、最多 2 秒」那种固定延时去猜（LP 4695 第 4 条）。
    ///  2) 主线程只发命令、只等回执，mpv 重解码那几秒不在主线程上卡着（Fuck 4696）。
    ///  3) `video` 标志：只要视频画面，不含字幕、不含 OSD，分辨率是片源的原始分辨率。
    ///     失败就报错，不退回不带标志那条（见下面那段注释）。
    /// 截图主路（LP 5012，参考 main）：`screenshot-raw` 取**解码后的原始帧**。
    ///
    /// 这条路不经过窗口/渲染层，所以尺寸永远是片源分辨率，跟横竖屏、跟
    /// 适应/裁切/拉伸都无关。main 用的是 media_kit 那层原生取帧，底层就是这条命令。
    func captureFrameToFile() async -> (url: URL?, note: String) {
        let raw = await captureRawFrame()
        if let url = raw.url { return (url, raw.note) }
        log(raw.note)

        // 原始帧那条不成再退一步：试 VO 出图（真机上以前一直失败，留着当第二选择）。
        let viaVO = await captureFrameViaVO()
        if let url = viaVO.url { return (url, viaVO.note) }
        log(viaVO.note)
        return (nil, "\(raw.note)；\(viaVO.note)")
    }

    /// `screenshot-raw` → CGImage → PNG 临时文件。
    private func captureRawFrame() async -> (url: URL?, note: String) {
        let started = Date()
        guard let frame = await rawScreenshot() else {
            return (nil, "取帧失败：screenshot-raw 没回帧")
        }
        guard let image = frame.makeCGImage() else {
            return (nil, "取帧失败：像素格式认不得（\(frame.format)，\(frame.width)×\(frame.height)）")
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("kazumi-shot-\(UUID().uuidString).png")
        guard let data = UIImage(cgImage: image).pngData() else {
            return (nil, "取帧失败：PNG 编不出来")
        }
        do {
            try data.write(to: path)
        } catch {
            return (nil, "取帧失败：临时文件写不出去")
        }
        let sourceText = lastSnapshot.videoWidth > 0 && lastSnapshot.videoHeight > 0
            ? "，片源 \(Int(lastSnapshot.videoWidth))×\(Int(lastSnapshot.videoHeight))"
            : ""
        let note = "截图成功（原始帧）：\(frame.width)×\(frame.height)\(sourceText)，\(frame.format)，\(Int(Date().timeIntervalSince(started) * 1000)) 毫秒"
        log(note)
        return (path, note)
    }

    /// 下发 `screenshot-raw video`，等回执里的那块帧。
    private func rawScreenshot() async -> MPVRawFrame? {
        guard let handle else { return nil }
        let id = nextCommandID
        nextCommandID += 1

        // 参数是 node 数组：["screenshot-raw", "video"]。mpv 只在调用期间用这些字符串
        // 和 node，所以调用完就能放。
        let commandName = strdup("screenshot-raw")!
        let modeName = strdup("video")!
        let strings: [UnsafeMutablePointer<CChar>] = [commandName, modeName]
        defer { for item in strings { free(item) } }
        var values = strings.map { pointer -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = pointer
            return node
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<MPVRawFrame?, Never>) in
            rawShotWaiters[id] = continuation
            var status: Int32 = -1
            values.withUnsafeMutableBufferPointer { buffer in
                // 参数表：node 数组。`mpv_command_node_async` 会在返回前把参数拷走，
                // 所以这块栈上的东西出了作用域也能放。
                var list = mpv_node_list(
                    num: Int32(buffer.count),
                    values: buffer.baseAddress,
                    keys: nil
                )
                withUnsafeMutablePointer(to: &list) { listStorage in
                    var args = mpv_node()
                    args.format = MPV_FORMAT_NODE_ARRAY
                    args.u.list = listStorage
                    status = mpv_command_node_async(handle, id, &args)
                }
            }
            if status < 0 {
                log("取帧命令下发失败：\(String(cString: mpv_error_string(status)))")
                finishRawShot(id: id, frame: nil)
                return
            }
            // 跟其他异步命令一样的超时：放走等待者，不让截图那条任务挂死。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                finishRawShot(id: id, frame: nil)
            }
        }
    }

    /// 第二选择：让 VO 出图（`screenshot-to-file … video`）。
    private func captureFrameViaVO() async -> (url: URL?, note: String) {
        let started = Date()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("kazumi-shot-\(UUID().uuidString).png")

        // `video` 标志：只要视频画面，不含字幕、不含 OSD，分辨率是片源的原始分辨率。
        //
        // 失败后**不**退回不带标志那条：不带标志时 mpv 默认把字幕烧进图里，而这个引擎
        // 从头到尾没设过 `sid`，流里只要有内嵌字幕轨它就会自动选中——那正是第 1 条
        // 明令不要的（Fuck 4704）。所以失败就报错，让人看见，不偷偷出一张带字幕的图。
        let result = await runAsyncCommand("screenshot-to-file", [path.path, "video"])
        guard result >= 0 else {
            let note = "截图失败：mpv 出图没成（video 标志，错误码 \(result)），共 \(Int(Date().timeIntervalSince(started) * 1000)) 毫秒"
            log(note)
            return (nil, note)
        }

        guard FileManager.default.fileExists(atPath: path.path) else {
            let note = "截图失败：命令成了但文件没落盘（\(path.path)）"
            log(note)
            return (nil, note)
        }
        let size = Self.pixelSize(of: path)
        let sizeText = size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "尺寸读不到"
        // 片源尺寸一起写进这行：两个数一样才是「完整的一帧」，比片源小就说明还是被
        // 渲染层按窗口裁过（LP 5002 就是靠这一行定性的）。
        let sourceText = lastSnapshot.videoWidth > 0 && lastSnapshot.videoHeight > 0
            ? "，片源 \(Int(lastSnapshot.videoWidth))×\(Int(lastSnapshot.videoHeight))"
            : ""
        let note = "截图成功：\(sizeText)\(sourceText)，\(Int(Date().timeIntervalSince(started) * 1000)) 毫秒"
        log(note)
        return (path, note)
    }

    /// 只读 PNG 头部拿像素尺寸，不解码整张图。
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        guard
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 兼容旧调用点：读回内存。截图本身不再走这条（写文件再存相册更省）。
    func captureFrame() async -> (image: UIImage?, note: String) {
        let (url, note) = await captureFrameToFile()
        guard let url, let data = try? Data(contentsOf: url) else {
            return (nil, note)
        }
        let image = UIImage(data: data)
        try? FileManager.default.removeItem(at: url)
        return (image, note)
    }

    // MARK: - 收尾

    func stop() {
        // 先把出帧钩子摘掉，再销毁内核：钩子那头的画中画取帧器会去读 mpv 句柄，
        // 留着它，销毁之后补画的一帧就会读一块已经还回去的内存（真机 SIGSEGV）。
        onFrameRendered = nil
        pump?.stop()
        pump = nil
        // 引擎要没了，还等着的命令不能继续挂着。
        failPendingCommands(-1)
        if let renderContext {
            mpv_render_context_free(renderContext)
        }
        renderContext = nil
        if let handle {
            mpv_terminate_destroy(handle)
        }
        handle = nil
    }

    // MARK: - 小工具

    /// 包括属性、命令和代理提示在内，交给上层前统一脱敏。
    private func log(_ message: String) {
        let safe = MPVDiagnostics.sanitize(message)
        if !safe.isEmpty { onLog?(safe) }
    }

    /// 代理地址（LP 5331：设置里手填的那个）。`nil` 表示不走代理，把选项清掉。
    ///
    /// libmpv 不认 iOS 的系统代理（App 也拿不到代理软件在 HTTP 模式下的端口），
    /// 所以只能由调用方交进来。
    /// 这个选项是运行期可改的，正在放的那一集改了设置也会对后续请求生效。
    func setProxy(_ url: String?) {
        guard let handle else { return }
        let value = url ?? ""
        let status = mpv_set_property_string(handle, "http-proxy", value)
        if status < 0 {
            log("设属性 http-proxy 失败：\(String(cString: mpv_error_string(status)))")
            return
        }
        log(url == nil ? "代理：不走代理" : "代理：走 \(url!)")
    }

    /// 播放中改的选项（画面填充方式这类）：走属性，当场生效。
    func setOptionForPlayback(_ name: String, _ value: String) {
        guard let handle else { return }
        let status = mpv_set_property_string(handle, name, value)
        if status < 0 {
            log("设属性 \(name) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    private func setOption(_ name: String, _ value: String) {
        let status = mpv_set_option_string(handle, name, value)
        if status < 0 {
            log("设选项 \(name) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        var value: Int32 = flag ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value)
    }

    /// 异步命令：把命令丢进 mpv 就走，等事件泵里那条 `COMMAND_REPLY` 回来再继续。
    ///
    /// 为什么不用同步 `mpv_command`：截图要 mpv 回到最近的关键帧重新解码，网络流上
    /// 这一下是秒级的；同步调用会把主线程一起卡住（MPVEngine 整个是 @MainActor，
    /// 命令是从主线程发下去的）。回执带超时：超时了也要把等待者放走，不然 task 挂死。
    /// 返回错误码（>= 0 成功），-1 表示引擎还没起来，-2 表示超时。
    func runAsyncCommand(_ name: String, _ args: [String?] = []) async -> Int32 {
        guard let handle else { return -1 }
        let id = nextCommandID
        nextCommandID += 1
        // C 字符串得活到回执那一刻：mpv 只保证在调用期间有效，所以自己 strdup，
        // 收尾时统一 free。
        var strings: [UnsafeMutablePointer<CChar>] = []
        for item in [name] + args.compactMap({ $0 }) {
            strings.append(strdup(item))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let waiter = CommandWaiter(cont)
            pendingCommands[id] = CommandRequest(waiter: waiter, strings: strings)
            var pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
            pointers.append(nil)
            let status = mpv_command_async(handle, id, &pointers)
            if status < 0 {
                log("命令 \(name) 异步下发失败：\(String(cString: mpv_error_string(status)))")
                finishCommand(id: id, error: status)
                return
            }
            // 超时：放走等待者。回执要是迟到了，`finishCommand` 看到队列里已经没它、
            // 就不会重复 resume。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                finishCommand(id: id, error: -2)
            }
        }
    }

    /// 回执落地：把 C 字符串释放、把等待者放走。只认一次（重复回执直接忽略）。
    private func finishCommand(id: UInt64, error: Int32) {
        guard let request = pendingCommands.removeValue(forKey: id) else { return }
        for pointer in request.strings { free(pointer) }
        request.waiter.resume(error)
    }

    /// 取帧回执落地：把原始帧交给等待者（没拿到就是 nil）。
    private func finishRawShot(id: UInt64, frame: MPVRawFrame?) {
        guard let waiter = rawShotWaiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: frame)
    }

    /// 收尾：把还在等的命令全放走，避免有 task 永远挂着。
    private func failPendingCommands(_ error: Int32) {
        let requests = pendingCommands
        pendingCommands.removeAll()
        for request in requests.values {
            for pointer in request.strings { free(pointer) }
            request.waiter.resume(error)
        }
        let shots = rawShotWaiters
        rawShotWaiters.removeAll()
        for waiter in shots.values {
            waiter.resume(returning: nil)
        }
    }

    private func command(_ name: String, _ args: [String?] = []) {
        guard let handle else { return }
        var strings: [String?] = [name]
        strings.append(contentsOf: args)
        strings.append(nil)
        var cargs = strings.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        let status = mpv_command(handle, &cargs)
        if status < 0 {
            log("命令 \(name) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    /// 渲染时把画面画进当前 FBO。
    func render(in view: GLKView) {
        // 后台一律不碰 GL（LP 4978 第 2 条）。
        guard let renderContext, !renderingLocked else { return }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        // 0×0 的 FBO 交给 mpv，缩放算出来是 NaN，画面就是一坨。
        guard viewport[2] > 0, viewport[3] > 0 else { return }
        logGeometryOnce(view: view, viewport: viewport)
        var data = mpv_opengl_fbo(
            fbo: Int32(fbo),
            w: Int32(viewport[2]),
            h: Int32(viewport[3]),
            // 传真实格式 GL_RGBA8（Fuck 5618）。
            //
            // 这块 FBO 是我们自己定的 8 位 RGBA（`MPVPlayerContainer.swift` 里
            // `glView.drawableColorFormat = .RGBA8888`），把真实格式告诉 mpv，
            // 它就不用猜目标缓冲长什么样。
            //
            // 前两次都没成，但不是同一件事：传 `GL_RGBA` 是没带尺寸的老写法，
            // mpv 会当成「未定尺寸的 RGBA」自己再推；传 `0` 是让它完全按默认值
            // 猜（main 的 media_kit_video 传 0 能对，是因为它画进的是自己按
            // CVPixelBuffer 建的纹理 FBO，不是 GLKView 的 renderbuffer）。
            // `GL_RGBA8` 才是「这块就是 8 位 RGBA」的明确说法。
            internal_format: Int32(GL_RGBA8)
        )
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &flip) { flipPtr in
            withUnsafeMutablePointer(to: &data) { dataPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: dataPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param()
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        // 告诉 mpv 这一帧确实上屏了：不报的话它按「还没显示」算，帧会被丢。
        mpv_render_context_report_swap(renderContext)
        // 画面还在当前 FBO 里，趁没被下一帧覆盖交给画中画拷走。
        // 后两个是这一集的显示尺寸（dwidth/dheight）：画中画要按真实的画面比例裁，
        // 不能整块容器都拷过去——那样两边的黑边也会被拷进去。
        onFrameRendered?(
            fbo,
            Int(viewport[2]),
            Int(viewport[3]),
            lastSnapshot.videoWidth,
            lastSnapshot.videoHeight
        )
        if !reportedFirstFrame {
            reportedFirstFrame = true
            // 这一帧是「真的在渲染流程里画出来的」，不是收到某个回调就假定画好了
            // （LP 4818 第 5 条）。事件泵据此把 awaitingFirstFrame 推进到 playing。
            pump?.markFirstFrameRendered()
            let callback = onFirstFrame
            Task { @MainActor in callback?() }
        }
    }

    /// 花屏、错位、色偏时先对这四个数：报给 mpv 的 FBO 尺寸必须等于真实的
    /// 可绘制尺寸。差一半是缩放错，宽高互换就是整块画面被当竖的贴上去，
    /// 色度跟着错位还会发绿发紫。
    private func logGeometryOnce(view: GLKView, viewport: [GLint]) {
        let geometry = "fbo \(viewport[2])×\(viewport[3]) drawable \(view.drawableWidth)×\(view.drawableHeight) bounds \(Int(view.bounds.width))×\(Int(view.bounds.height))@\(view.contentScaleFactor)"
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        log("画面尺寸 \(geometry)")
    }

    private func glString(_ name: Int32) -> String {
        guard let raw = glGetString(GLenum(name)) else { return "?" }
        return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
    }

    static func procAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        let symbol = CFStringCreateWithCString(
            kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue
        )
        let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString)
        return CFBundleGetFunctionPointerForName(bundle, symbol)
    }
}

/// 一条异步命令的等待者。回执和超时都会来敲门，只能认一次——续两次会直接崩。
/// 只在主线程上动。
private final class CommandWaiter {
    private var continuation: CheckedContinuation<Int32, Never>?

    init(_ continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    func resume(_ error: Int32) {
        continuation?.resume(returning: error)
        continuation = nil
    }
}

private struct CommandRequest {
    let waiter: CommandWaiter
    /// 自己 strdup 出来的命令字符串，回执或超时到了才能释放。
    let strings: [UnsafeMutablePointer<CChar>]
}

/// 在 mpv 自己的线程上收事件，攒成快照再递回主线程。
final class MPVEventPump: @unchecked Sendable {
    private let mpv: OpaquePointer
    private let queue = DispatchQueue(label: "kazumi.mpv.events", qos: .userInteractive)
    private let onSnapshot: @Sendable (MPVSnapshot) -> Void
    private let onLog: @Sendable (String) -> Void
    /// 异步命令的回执：`(reply_userdata, 错误码)`，错误码 >= 0 就是成了。
    /// 走 mpv 自己的线程，进来先跳回主线程再唤醒等待者。
    var onCommandReply: (@Sendable (UInt64, Int32, MPVRawFrame?) -> Void)?
    private var running = false
    private var ticker: DispatchSourceTimer?
    /// 最近一次加载失败的原因；成功起播后清掉。
    private var lastError: String?
    /// 只保存已脱敏的 error / fatal 摘要，报错提示也不能携带凭据。
    private var lastCoreErrorText: String?
    private var diagnostics = MPVDiagnostics()
    private var awaitingStartFile = false
    /// 这一集的格式参数只记一次。
    private var loggedVideoInfo = false
    /// 这次加载走到哪一步（LP 4818）。只在事件泵自己的队列上读写。
    private var loadPhase: MPVLoadPhase = .idle
    /// 这次加载里，第一帧有没有真的在渲染回调里画过。
    private var firstFrameRendered = false

    init(
        mpv: OpaquePointer,
        onSnapshot: @escaping @Sendable (MPVSnapshot) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.mpv = mpv
        self.onSnapshot = onSnapshot
        onLog = log
    }

    func start() {
        // 这些属性一变就唤醒，醒来统一读一遍值，比逐个解析事件结构省事。
        for name in ["time-pos", "duration", "pause", "eof-reached", "core-idle", "video-params"] {
            let status = mpv_observe_property(mpv, 0, name, MPV_FORMAT_NONE)
            if status < 0 {
                log("observe \(name) 失败：\(String(cString: mpv_error_string(status)))")
            }
        }
        mpv_set_wakeup_callback(
            mpv,
            { ctx in
                guard let ctx else { return }
                let pump = Unmanaged<MPVEventPump>.fromOpaque(ctx).takeUnretainedValue()
                pump.signal()
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        running = true
        // 不依赖 mpv 的唤醒回调：实测这条回调在这套静态库里一次都不来，
        // 改用固定节拍读属性。250ms 对进度条和暂停状态足够，也不费电。
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        timer.resume()
        ticker = timer
        Task { @MainActor in
            KazumiLogBuffer.shared.append("事件泵已启动（定时读属性）", category: .player)
        }
    }

    func stop() {
        running = false
        ticker?.cancel()
        ticker = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
    }

    /// 引擎要开始新的一次加载了（换集 / 重试 / 换源）。
    func beginLoad() {
        queue.async { [weak self] in
            guard let self else { return }
            self.loadPhase = .opening
            self.firstFrameRendered = false
            self.loggedVideoInfo = false
            self.lastCoreErrorText = nil
            self.diagnostics.resetPlayback()
            self.awaitingStartFile = true
        }
    }

    /// 第一帧已经在渲染回调里画过（由引擎在主线程调）。
    func markFirstFrameRendered() {
        queue.async { [weak self] in
            guard let self else { return }
            self.firstFrameRendered = true
            if self.loadPhase == .awaitingFirstFrame { self.loadPhase = .playing }
        }
    }

    fileprivate func signal() {
        guard running else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            guard let event = mpv_wait_event(mpv, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            if id == MPV_EVENT_SHUTDOWN { return }
            if id == MPV_EVENT_START_FILE {
                // 开始打开文件：圈从现在开始转（LP 4818 第 2 条）。
                loadPhase = .opening
                firstFrameRendered = false
                loggedVideoInfo = false
                lastCoreErrorText = nil
                // beginLoad 已重置过就不再给一份配额；内核自行换文件仍需重置。
                if !awaitingStartFile { diagnostics.resetPlayback() }
                awaitingStartFile = false
            }
            if id == MPV_EVENT_FILE_LOADED {
                // 文件打开了不等于有画面：不在这儿收圈，往后推到「等首帧」
                // （LP 4818 第 3 条）。
                if loadPhase == .opening { loadPhase = .awaitingFirstFrame }
            }
            if id == MPV_EVENT_PLAYBACK_RESTART {
                // 起播 / seek 完都会来这条。起播时推进到「等首帧」，
                // seek 时相位已经是 playing，不动——别让 seek 误触发首帧逻辑
                // （LP 4818 第 4、7 条）。
                if loadPhase == .opening { loadPhase = .awaitingFirstFrame }
            }
            if id == MPV_EVENT_END_FILE, let raw = event.pointee.data {
                // 播完 / 出错：加载状态清掉，别让圈挂在那儿转（LP 4818 第 8 条）。
                loadPhase = .idle
                let endFile = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(raw))
                if endFile.pointee.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.pointee.error))
                    // 画面上那行内核日志已经拿掉了（LP 4810），所以这里必须给一句人话：
                    // 内核报的是英文（`Failed to open ...`），翻成用户看得懂的原因。
                    // 日志与错误详情都只用脱敏后的文本。
                    lastError = PlayerErrorMessage.friendly(core: message, detail: lastCoreErrorText)
                    log("end-file 错误：\(message)\(lastCoreErrorText.map { " / \($0)" } ?? "")")
                }
            }
            if id == MPV_EVENT_LOG_MESSAGE, let raw = event.pointee.data {
                let message = UnsafeMutablePointer<mpv_event_log_message>(
                    OpaquePointer(raw)
                )
                let text = String(cString: message.pointee.text)
                let prefix = String(cString: message.pointee.prefix)
                let level = String(cString: message.pointee.level)
                let diagnostic = diagnostics.receive(prefix: prefix, level: level, text: text)
                if let receipt = diagnostic.receipt { log(receipt) }
                if let line = diagnostic.line { log(line) }
                if let errorText = diagnostic.errorText {
                    lastCoreErrorText = errorText
                }
            }
            if id == MPV_EVENT_COMMAND_REPLY {
                // 异步命令做完了。`reply_userdata` 就是发命令时给的那个号，
                // 错误码在 event.error 上（>= 0 成功）。
                //
                // 回执里还可能带一个 node（`screenshot-raw` 的原始帧就在里面）。
                // 这个 node 只在处理事件这一刻有效，所以当场拷成 `MPVRawFrame`。
                var rawFrame: MPVRawFrame?
                if event.pointee.error >= 0, let dataPointer = event.pointee.data {
                    let reply = UnsafeMutablePointer<mpv_event_command>(OpaquePointer(dataPointer))
                    rawFrame = MPVRawFrame(node: reply.pointee.result)
                }
                onCommandReply?(event.pointee.reply_userdata, event.pointee.error, rawFrame)
            }
        }
        var snap = snapshot()
        // 「自动播放真的起来了」的两个判据，满足一个就算（LP 4820）：
        // 一是第一帧已经在渲染回调里画过，二是时间轴真的在推进（没暂停、time-pos 走起来了）。
        // 后者兜住「帧画出来了但首帧回调没轮到」这种情况。
        if loadPhase == .awaitingFirstFrame {
            if firstFrameRendered || (!snap.isPaused && snap.time > 0.1) {
                loadPhase = .playing
            }
        }
        if snap.hasVideo { lastError = nil }
        // 第一帧出来的时候把源的真实格式记下来：位深、矩阵、范围这三样
        // 直接决定颜色对不对，pixelformat 里带 10 就是 10bit 片源。
        // 只在**真取到值**之后才打印一次（Fuck 5592 指出来的）。
        // 原来只判 `hasVideo`，而它只代表 `video-params` 这个节点存在——节点刚出现
        // 那一拍里 pixelformat / 颜色三件套 / hwdec-current 还都是空的，于是整行
        // 变成 `px=? 矩阵=? 原色=? 伽马=? 位深=? hwdec=?`，等于没打。
        // 现在取空就等下一拍（250ms 一拍）再取，直到取到为止。
        if snap.hasVideo, !loggedVideoInfo {
            let line = videoInfoLine()
            if !line.hasSuffix("px=? 矩阵=? 原色=? 伽马=? 位深=? hwdec=?") {
                loggedVideoInfo = true
                log("片源 \(line)")
            }
        }
        snap.loadError = lastError
        snap.loadPhase = loadPhase
        onSnapshot(snap)
    }

    private func log(_ message: String) {
        let safe = MPVDiagnostics.sanitize(message)
        if !safe.isEmpty { onLog(safe) }
    }

    private func videoInfoLine() -> String {
        func text(_ name: String) -> String {
            guard let raw = mpv_get_property_string(mpv, name) else { return "?" }
            defer { mpv_free(raw) }
            return String(cString: raw)
        }
        return "fmt=\(text("video-format")) px=\(text("video-params/pixelformat")) 矩阵=\(text("video-params/colormatrix")) 原色=\(text("video-params/primaries")) 伽马=\(text("video-params/gamma")) 位深=\(text("video-params/plane-depth")) hwdec=\(text("hwdec-current"))"
    }

    private func snapshot() -> MPVSnapshot {
        var time = Double(0)
        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &time)
        var duration = Double(0)
        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
        var paused: Int32 = 1
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        var idle: Int32 = 0
        mpv_get_property(mpv, "core-idle", MPV_FORMAT_FLAG, &idle)
        var ended: Int32 = 0
        mpv_get_property(mpv, "eof-reached", MPV_FORMAT_FLAG, &ended)
        var params = mpv_node()
        let hasVideo = mpv_get_property(mpv, "video-params", MPV_FORMAT_NODE, &params) >= 0
        mpv_free_node_contents(&params)
        // 画面尺寸：dwidth/dheight 是「实际显示」的尺寸（anamorphic 也算过），
        // 拿不到就退回 width/height。全 0 表示还没有画面，上层回落到整块容器。
        var videoWidth: Int64 = 0
        var videoHeight: Int64 = 0
        mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &videoWidth)
        mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &videoHeight)
        if videoWidth <= 0 || videoHeight <= 0 {
            mpv_get_property(mpv, "width", MPV_FORMAT_INT64, &videoWidth)
            mpv_get_property(mpv, "height", MPV_FORMAT_INT64, &videoHeight)
        }
        var seeking: Int32 = 0
        mpv_get_property(mpv, "seeking", MPV_FORMAT_FLAG, &seeking)
        return MPVSnapshot(
            time: time.isFinite ? time : 0,
            duration: duration.isFinite ? duration : 0,
            isPaused: paused > 0,
            isIdle: idle > 0,
            hasVideo: hasVideo,
            ended: ended > 0,
            videoWidth: videoWidth > 0 ? Double(videoWidth) : 0,
            videoHeight: videoHeight > 0 ? Double(videoHeight) : 0,
            downloadSpeed: downloadSpeed(),
            isSeeking: seeking > 0
        )
    }

    /// 当前的下载速度（字节/秒）。
    ///
    /// 先问 `cache-speed`：它就是「demuxer 缓存正在被填多快」。个别内核版本这个
    /// 属性是空的，再退回 `demuxer-cache-state` 里的 `raw-input-rate`
    /// （mpv 的 node map 支持按子键取值，直接拿字符串再转数最省事）。
    /// 两个都拿不到就是 0：界面上不显示网速，不留一个「0 KB/s」在那儿。
    private func downloadSpeed() -> Double {
        var speed = Double(0)
        if mpv_get_property(mpv, "cache-speed", MPV_FORMAT_DOUBLE, &speed) >= 0,
           speed.isFinite, speed > 0 {
            return speed
        }
        guard let raw = mpv_get_property_string(mpv, "demuxer-cache-state/raw-input-rate") else {
            return 0
        }
        defer { mpv_free(raw) }
        let value = Double(String(cString: raw)) ?? 0
        return value.isFinite && value > 0 ? value : 0
    }
}

/// mpv 有新帧时的回调。必须是文件级函数：`@convention(c)` 的函数指针不能捕获上下文。
private func kazumiMPVRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let engine = Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        engine.requestDisplay()
    }
}
