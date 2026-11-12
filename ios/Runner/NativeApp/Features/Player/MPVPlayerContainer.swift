//
//  MPVPlayerContainer.swift
//  Kazumi
//
//  把 mpv 的画面接进 SwiftUI，并叠一层弹幕（换掉原来的 KSPlayer 容器）。
//
//  只换画面这一层：上面的控制栏、手势、选集、截图全是自己写的 SwiftUI。
//  画面对外暴露的状态模型（PlayerSurfaceModel）已经拆到 PlayerSurfaceModel.swift，
//  macOS 侧复用同一份；这份文件只剩 UIKit 的宿主视图与弹幕叠层。
//

import Foundation
import SwiftUI
import UIKit

// MARK: - 画面

/// 画面 + 弹幕叠在一起的那块 UIView。
final class MPVHostView: UIView {
    let metalView = MPVMetalView()
    let overlay = DanmakuOverlayView()
    weak var engine: MPVEngine?

    /// 视频尺寸、填充方式与弹幕顶部留白，由容器在 updateUIView 里推进来。
    private var videoSize: CGSize = .zero
    /// 上一次 layout 时的尺寸：用来认出「画面被撑大了」这件事。
    private var lastLayoutSize: CGSize = .zero
    private var fillMode: MPVPlayerContainer.MPVFillMode = .fit
    private var danmakuTopInset: CGFloat = 0

    private var overlayLeading: NSLayoutConstraint!
    private var overlayTop: NSLayoutConstraint!
    private var overlayWidth: NSLayoutConstraint!
    private var overlayHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        addSubview(overlay)
        overlayLeading = overlay.leadingAnchor.constraint(equalTo: leadingAnchor)
        overlayTop = overlay.topAnchor.constraint(equalTo: topAnchor)
        overlayWidth = overlay.widthAnchor.constraint(equalToConstant: 0)
        overlayHeight = overlay.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            // Metal 画面仍然铺满整块：mpv 自己在里面按 fit/crop/stretch 出画面。
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 弹幕只贴在「视频矩形」里，不再铺到黑边上（DEFECT 1）。
            overlayLeading,
            overlayTop,
            overlayWidth,
            overlayHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            engine?.requestRender()
        }
    }

    /// 更新视频矩形所需的三样东西；真正的尺寸在 layoutSubviews 里按当前 bounds 算。
    func updateVideoLayout(
        videoSize: CGSize,
        fillMode: MPVPlayerContainer.MPVFillMode,
        danmakuTopInset: CGFloat
    ) {
        // 画面尺寸 / 填充方式变了也要同步 drawable：暂停时没有新帧，
        // 旧尺寸的 swapchain 会被系统拉伸（同下面的 layoutSubviews）。
        let geometryChanged = videoSize != self.videoSize || fillMode != self.fillMode
        let insetChanged = danmakuTopInset != self.danmakuTopInset
        // SwiftUI 每个状态快照都会走这里；三项都没变时不要再触发布局。
        guard geometryChanged || insetChanged else { return }
        self.videoSize = videoSize
        self.fillMode = fillMode
        self.danmakuTopInset = danmakuTopInset
        setNeedsLayout()
        if geometryChanged {
            metalView.setNeedsLayout()
            metalView.updateDrawableSize()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸一变就同步 CAMetalLayer.drawableSize（LP 2026-10-28 第 5 条）。
        // 暂停时没有新帧，如果不更新 swapchain，进全屏后旧画面会被系统拉伸。
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            metalView.setNeedsLayout()
            metalView.updateDrawableSize()
            // 还没拿到这一集的画面尺寸（起播 / 换集中）时不要重建 VO：
            // 这时 drawable 只是在跟着转屏变，旧画面不该被当成新尺寸去重配。
            if videoSize.width > 0, videoSize.height > 0 {
                engine?.reconfigureVideoOutputForSurfaceResize()
            }
        }
        let rect = fillMode.videoRect(in: bounds, videoSize: videoSize)
        // 顶部让出控制栏（横屏 44pt），底部仍留 20% 给字幕：
        // 弹幕区 = 视频上方 80% 再往上收掉顶部留白。
        let inset = max(0, danmakuTopInset)
        let top = rect.minY + inset
        let height = max(0, rect.height * 0.8 - inset)
        // 只在数值变了才改约束，避免 layoutSubviews 里反复触发布局。
        if overlayLeading.constant != rect.minX { overlayLeading.constant = rect.minX }
        if overlayTop.constant != top { overlayTop.constant = top }
        if overlayWidth.constant != rect.width { overlayWidth.constant = rect.width }
        if overlayHeight.constant != height { overlayHeight.constant = height }
    }
}

// MARK: - SwiftUI 容器

struct MPVPlayerContainer: UIViewRepresentable {
    let url: URL
    let referer: String?
    let userAgent: String?
    /// 登录态的 Cookie 头（规则登录过才有）。
    let cookie: String?
    /// 代理地址（`http://主机:端口`），nil 表示不走（LP 5331：用户在设置里手填）。
    let proxyURL: String?
    /// 超分着色器的绝对路径，空数组表示关闭（顺序就是挂载顺序）。
    let shaderPaths: [String]
    /// 画面填充方式。
    let fillMode: MPVFillMode
    /// mpv 的视频比例覆盖；`no` 使用片源比例。
    let videoAspectOverride: String
    let danmaku: [DanmakuComment]
    let danmakuStyle: DanmakuOverlayView.Style
    let danmakuPlaybackRate: Double
    /// 弹幕顶部留白：横屏时让开顶栏，竖屏为 0。
    let danmakuTopInset: CGFloat
    /// 低内存模式的档位（设置页选的那一档，LP 5547 / main 的 `LowMemoryMode`）。
    let lowMemoryMode: LowMemoryMode
    /// 硬件解码开关（LP 5549）。
    let hardwareDecodeEnabled: Bool
    let hardwareDecodeMode: HardwareDecodeMode
    let surface: PlayerSurfaceModel

    /// 按档位和当前网络算出这一集该给的缓存字节数。
    private func cacheSizeForPolicy() -> Int {
        PlaybackCachePolicy.bytes(
            mode: lowMemoryMode,
            isMetered: MeteredNetworkMonitor.shared.isMetered,
            isLocalPlayback: url.isFileURL
        )
    }

    /// 画面填充方式（对应原版 PlayerAspectRatio 的 BoxFit）。
    enum MPVFillMode {
        /// 等比适配，留黑边。
        case fit
        /// 等比填满，超出裁掉。
        case crop
        /// 不保持比例，拉满。
        case stretch
    }

    private var videoSizeForLayout: CGSize {
        videoAspectOverride == "4:3" ? CGSize(width: 4, height: 3) : surface.videoSize
    }

    func makeUIView(context: Context) -> MPVHostView {
        let host = MPVHostView()
        let engine = MPVEngine()
        // 缓存大小在 `start()` 之前定下来：低内存模式开着就 2 MiB，否则 1500 MiB。
        // 本地文件不按流量算（main 的 `isLocalPlayback`），所以文件播放永远走完整缓存。
        engine.applyCacheSize(cacheSizeForPolicy())
        engine.hardwareDecodeEnabled = hardwareDecodeEnabled
        engine.hardwareDecodeMode = hardwareDecodeMode
        // 播到一半 Wi-Fi 换成移动数据（或反过来）时，缓存档位要跟着换，不用重开这一集。
        // 「跟随网络」这一档在两种网络下取的值不一样，靠这个回调补上。
        MeteredNetworkMonitor.shared.onChange = { [engine, mode = lowMemoryMode, isLocal = url.isFileURL] in
            engine.applyCacheSize(
                PlaybackCachePolicy.bytes(
                    mode: mode,
                    isMetered: MeteredNetworkMonitor.shared.isMetered,
                    isLocalPlayback: isLocal
                )
            )
        }
        engine.onSnapshot = { [weak surface] snapshot in
            surface?.handle(snapshot: snapshot)
        }
        engine.onLog = { message in
            KazumiLogBuffer.player("mpv: \(message)")
        }
        engine.onFirstFrame = { [weak surface] in
            surface?.hasFirstFrame = true
        }
        surface.onRecoverFromStall = { [weak engine, weak surface] time in
            guard let surface, surface.wantsPlaying, let engine else { return false }
            // 先确认命令真提交了，再重新武装首帧补播：引擎是本地文件、没有当前源或
            // 下发失败时会返回 false，这时界面状态一个字都不能动，恢复额度也不能消耗。
            guard engine.recoverFromStall(at: time) else { return false }
            // mpv 换文件会重设 pause；用户随后暂停会清掉它。
            surface.prepareForPlaybackRestart()
            return true
        }
        engine.start(in: host.metalView)
        host.engine = engine

        context.coordinator.engine = engine
        context.coordinator.surface = surface
        context.coordinator.overlay = host.overlay
        surface.attach(engine: engine)
        surface.danmakuOverlay = host.overlay
        host.overlay.clock = surface
        host.updateVideoLayout(
            videoSize: videoSizeForLayout,
            fillMode: fillMode,
            danmakuTopInset: danmakuTopInset
        )
        context.coordinator.apply(
            url: url,
            referer: referer,
            userAgent: userAgent,
            cookie: cookie,
            shaders: shaderPaths,
            fill: fillMode,
            videoAspectOverride: videoAspectOverride,
            proxyURL: proxyURL
        )
        return host
    }

    func updateUIView(_ uiView: MPVHostView, context: Context) {
        context.coordinator.surface = surface
        surface.attach(engine: context.coordinator.engine)
        // 设置页改了档位、或者网络在 Wi-Fi 和移动数据之间换了，这一集当场换缓存大小，
        // 不用重开（main 的 `_onChanged` 也是立刻 apply）。
        context.coordinator.engine?.applyCacheSize(cacheSizeForPolicy())
        // 视频尺寸 / 填充方式 / 顶部留白变了，弹幕矩形跟着重算。
        uiView.updateVideoLayout(
            videoSize: videoSizeForLayout,
            fillMode: fillMode,
            danmakuTopInset: danmakuTopInset
        )
        context.coordinator.apply(
            url: url,
            referer: referer,
            userAgent: userAgent,
            cookie: cookie,
            shaders: shaderPaths,
            fill: fillMode,
            videoAspectOverride: videoAspectOverride,
            proxyURL: proxyURL
        )
        context.coordinator.overlay?.apply(
            comments: danmaku,
            style: danmakuStyle,
            playbackRate: danmakuPlaybackRate
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: MPVHostView, coordinator: Coordinator) {
        coordinator.overlay?.clock = nil
        coordinator.overlay = nil
        uiView.overlay.clock = nil
        coordinator.surface?.attach(engine: nil)
        coordinator.engine?.stop()
        coordinator.engine = nil
        // 播放器没了就别再把回调挂在单例上。
        MeteredNetworkMonitor.shared.onChange = nil
    }

    @MainActor
    final class Coordinator {
        weak var surface: PlayerSurfaceModel?
        weak var overlay: DanmakuOverlayView?
        var engine: MPVEngine?

        private var lastRequest: MPVPlaybackRequest?
        private var lastLoadedURL: URL?
        private var lastShaders: [String] = []
        private var lastFill: MPVFillMode?
        private var lastVideoAspectOverride = ""
        private var lastProxy: String?

        func apply(
            url: URL,
            referer: String?,
            userAgent: String?,
            cookie: String?,
            shaders: [String],
            fill: MPVFillMode,
            videoAspectOverride: String,
            proxyURL: String?
        ) {
            guard let engine else { return }
            // 换档位时画面要重新出，但不用重新起播：mpv 换着色器当场生效。
            if shaders != lastShaders {
                lastShaders = shaders
                // 换着色器要现编 GLSL，质量档那几颗 VL 模型在手机上能卡几百毫秒。
                // 这一步原来跟着 SwiftUI 的更新走、在主线程上做，点完菜单整段卡住，
                // 点击就被吃掉、要点很多下（LP 2026-10-28）。
                // 2026-10-29 排查闪退得出的结论：与线程无关，瓶颈在编译本身；
                // 主线程上这 6 颗挂上去实测 82ms，LP 验收不闪退。
                engine.setShaders(shaders)
            }
            if fill != lastFill {
                lastFill = fill
                switch fill {
                case .fit:
                    engine.setOptionForPlayback("panscan", "0")
                    engine.setOptionForPlayback("keepaspect", "yes")
                case .crop:
                    engine.setOptionForPlayback("panscan", "1.0")
                    engine.setOptionForPlayback("keepaspect", "yes")
                case .stretch:
                    engine.setOptionForPlayback("panscan", "0")
                    engine.setOptionForPlayback("keepaspect", "no")
                }
            }
            if videoAspectOverride != lastVideoAspectOverride {
                lastVideoAspectOverride = videoAspectOverride
                engine.setOptionForPlayback("video-aspect-override", videoAspectOverride)
            }
            // 代理变了也要重新交给内核：设置里拨一下，正在放的那一集立刻生效。
            if proxyURL != lastProxy {
                lastProxy = proxyURL
                engine.setProxy(proxyURL)
            }
            let request = MPVPlaybackRequest(
                url: url,
                referer: referer,
                userAgent: userAgent,
                cookie: cookie
            )
            switch request.change(from: lastRequest) {
            case .unchanged:
                return
            case .headersOnly:
                // 同一地址只换了请求头（登录态的 Cookie 刷新这类）：更新断流恢复用的
                // 完整请求与内核头选项就够了，不重开文件，也不碰用户当前的暂停意图。
                // lastLoadedURL 对不上说明中间漏过一次换源，退回换源分支更安全。
                guard lastLoadedURL == url, engine.hasLoadedSource else {
                    lastRequest = request
                    lastLoadedURL = url
                    surface?.markWantsPlaying()
                    engine.load(request)
                    return
                }
                lastRequest = request
                engine.updatePlaybackRequest(request)
                KazumiLogBuffer.player("播放请求头已刷新（同一地址，不重开）")
            case .urlChanged:
                lastRequest = request
                lastLoadedURL = url
                surface?.markWantsPlaying()
                engine.load(request)
            }
        }
    }
}

extension MPVPlayerContainer.MPVFillMode {
    /// 画面在容器里的可见矩形（和 mpv 的 fit / crop / stretch 一致）。
    ///
    /// 弹幕层和控制层都从这里取同一份几何：横屏时屏幕比 16:9 宽，
    /// 两边是黑边，弹幕和控件都不该画进去（DEFECT 1 / 4）。
    func videoRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return bounds }

        let scaleX = bounds.width / videoSize.width
        let scaleY = bounds.height / videoSize.height
        let scale: CGFloat
        switch self {
        case .stretch:
            return bounds
        case .fit:
            scale = min(scaleX, scaleY)
        case .crop:
            scale = max(scaleX, scaleY)
        }
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        // crop 时矩形比容器大：只取可见部分，别把控件画到屏外。
        let visible = rect.intersection(bounds)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }
}
