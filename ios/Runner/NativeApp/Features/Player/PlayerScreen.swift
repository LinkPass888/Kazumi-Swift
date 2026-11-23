//
//  PlayerScreen.swift
//  Kazumi
//
//  对应 lib/pages/video/video_page.dart 的原生实现：
//  * 顶部 16:9 播放区（KSPlayer 基础画面 + 弹幕层），浮着返回与标题；
//  * 播放条：播放 / 暂停、进度、弹幕开关、超分辨率、倍速；
//  * 下方是线路与分集切换，解析中显示进度与解析日志，失败时给出原因与重试。
//

import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// 视频比例（对应原版 `lib/pages/player/controller/player_aspect_ratio.dart` 的四档）。
/// 与原版一样，播放器里的选择只在本次播放内生效，不写回设置。
enum PlayerAspectRatioMode: String, CaseIterable, Identifiable {
    case automatic
    case crop
    case stretch
    case ratio4x3

    var id: String { rawValue }

    /// 与原版 `PlayerAspectRatio.label` 逐字一致。
    var label: String {
        switch self {
        case .automatic: String(localized: "自动")
        case .crop: String(localized: "裁切填充")
        case .stretch: String(localized: "拉伸填充")
        case .ratio4x3: "4:3"
        }
    }

    /// 播放区本身的宽高比：只有 4:3 会换盒子，其余沿用 16:9。
    var frameAspectRatio: CGFloat {
        self == .ratio4x3 ? 4.0 / 3.0 : 16.0 / 9.0
    }

    /// 交给 mpv 渲染层的填充方式。
    var fillMode: MPVPlayerContainer.MPVFillMode {
        switch self {
        case .automatic, .ratio4x3: .fit
        case .crop: .crop
        case .stretch: .stretch
        }
    }

    var videoAspectOverride: String {
        self == .ratio4x3 ? "4:3" : "no"
    }

    /// 交给 AVPlayerLayer 的填充方式（原版 `BoxFit` 的等价物）。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .automatic: .resizeAspect
        case .crop: .resizeAspectFill
        case .stretch, .ratio4x3: .resize
        }
    }
}

/// 画面下面那一片的两个页：左边选集（线路 + 集数），右边这部番的吐槽。
enum PlayerDetailTab: String, CaseIterable, Identifiable {
    case episodes = "选集"
    case comments = "评论"

    var id: String { rawValue }
}

/// 「更多」面板里的三页：主列表和两个二级页（定时关闭 / 超分辨率 / 画面比例）。
/// 用 popover 自己翻页，不依赖 Menu 的嵌套菜单——那样菜单一开就没法挡自动隐藏。
/// 更多菜单里能打开的那几个页面，一次只有一张。
enum PlayerSheet: String, Identifiable {
    case danmakuSettings
    case danmakuSource
    case airPlay
    case externalPlay
    case syncPlay
    case videoInfo

    var id: String { rawValue }
}

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int
    var source: PlaybackSource?
    /// 续播信息（见 `AppRoute.player`）：上次那条线路，以及这次是不是「接着看」。
    var resumeRoad: Int?
    var resumeFromHistory: Bool = false
    /// 历史卡片带过来的规则名：重建播放源时按这一条取，别按番剧号取「最新那份」。
    var resumeRule: String?

    @State private var controller: PlayerController?
    /// Diagnostic identity only; it does not participate in navigation or playback.
    @State private var diagnosticPlayerID = String(UUID().uuidString.prefix(8)).lowercased()
    @State private var surface = PlayerSurfaceModel()
    /// 交给播放内核的代理（LP 5331：设置里手填的那个）。nil = 不走。
    /// 不现取：得在「开关或地址端口改了 / 回前台」时才重读一次。
    @State private var proxyURL: String?
    @State private var danmakuEnabled = true
    /// 画面量出来的宽度与尺寸：底栏宽窄断点与左栏画面比例均按左栏局部几何判断。
    @State private var surfaceWidth: CGFloat = 0
    @State private var surfaceSize: CGSize = .zero
    /// 播放区所在容器的尺寸（全屏时要按它铺满，见 `boxAspectRatio`）。
    @State private var containerSize: CGSize = .zero
    /// 播放页四周的安全区内缩（全屏时画面要绕过刘海，按它算窗口尺寸）。
    @State private var containerInsets = EdgeInsets()
    /// 非全屏（系统栏与安全区可见）时按横竖方向分槽记录的安全区快照，防止全屏隐藏系统栏后安全区归零或跨方向串用。
    @State private var portraitSafeInsetsSnapshot = EdgeInsets()
    @State private var landscapeSafeInsetsSnapshot = EdgeInsets()
    /// 整个窗口的尺寸（含安全区）。
    @State private var windowSize: CGSize = .zero
    /// 上一次转屏请求的结果，显示在「播放信息」里（Colo 2026-10-28）：
    /// 分得清是系统没给（被拒＋原因），还是我们没请求（一直「未请求」）。
    @State private var lastOrientationResult = String(localized: "未请求")
    @State private var danmakuDraft = ""
    @FocusState private var danmakuFieldFocused: Bool
    /// 这一次的暂停是「输入弹幕」引起的：收键盘后只恢复这一种（上游 2.4.0 #2708）。
    @State private var pausedForDanmakuInput = false
    @State private var playbackRate: Float = 1.0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    /// 拖动时手指在进度条上的横坐标（点），目标时间跟它走。
    @State private var scrubFingerX: CGFloat = 0
    @State private var isEditingSkipSeconds = false
    @State private var skipSecondsInput = ""
    @State private var skipSecondsError: String?

    // 本批新增：画面比例、控制栏自动隐藏、锁定、长按临时倍速。
    @State private var aspectRatioMode: PlayerAspectRatioMode = .automatic
    @State private var controlsVisible = true
    /// 播放器画面区在窗口坐标系（`.global`）下的矩形，供非全屏原生侧滑返回避让。
    @State private var playerAreaWindowFrame: CGRect = .zero
    /// 上一次看到的「别的 App 占着音频会话吗」。只在变了的时候写一行日志（LP 4976）。
    @State private var lastOtherAudioPlaying: Bool?
    /// 这一集是「因为切到后台才停下的」吗——只有这种暂停才在回前台时自动接上，
    /// 用户自己按的暂停不算（LP 2026-10-29「回到前台自动播放」）。
    @State private var pausedByBackground = false
    /// 后台自动画中画。设置关着时一直是 nil：不建图层、不建控制器、不碰软件渲染。
    @State private var pictureInPicture: PictureInPictureController?
    /// 「更多」/ 倍速面板：自己握开关，好让控制层知道菜单还开着。
    ///
    /// 系统菜单不把开合告诉代码，所以另挂了一个 `SystemMenuProbe` 看它在不在，
    /// 下面的 `.task` 靠它把「菜单已经收了」这件事认出来。
    /// 每次交互 +1，body 上的 `.task(id:)` 据此取消上一轮自动隐藏并重新计时。
    @State private var hideGeneration = 0
    /// 「更多」菜单开着：开着的时候不自动收控制栏，否则菜单会变成一张点不动的死图。
    @State private var menuOpen = false
    @State private var menuOpenedAt = Date()
    @State private var probeSawMenu = false
    @State private var probeLastSeen = Date()
    /// 画面锁（LP 2026-10-28 第 4 条）：锁上手势全不响应，只留「点一下把
    /// 左边缘那颗锁定钮叫出来」。锁定钮在画面左边缘、截图钮在右边缘，
    /// 跟快退 / 快进那两颗同一行（竖向居中）。
    @State private var isSurfaceLocked = false
    /// 锁着时点一下只把解锁那一颗浮出来几秒——这是唯一的解锁入口。
    @State private var unlockAffordanceShown = false
    @State private var unlockAffordanceTask: Task<Void, Never>?
    /// 截图那一下的取景框动画进度（0 → 1 走一遍）。
    @State private var screenshotFlash: CGFloat = 0
    @State private var screenshotFlashTask: Task<Void, Never>?
    /// 收藏钮点下去的缩放（Colo 2026-10-28：0.15 秒的 spring 弹一下）。
    /// 切超分档位时在 1/4 那条线上提示一下（Colo 2026-10-28）。
    @State private var superResolutionHUD: String?
    @State private var superResolutionHUDTask: Task<Void, Never>?
    @State private var isTemporarySpeed = false
    @State private var rateBeforeTemporarySpeed: Float = 1.0
    /// 按住画面那一下的计时：手指一落下就开始数，到点就倍速。
    @State private var surfacePressTask: Task<Void, Never>?
    /// 转屏只留一条请求链：新请求先把旧的取消，旧的每一步先核对自己的代号
    /// 还是不是最新的（LP 2026-10-28「横屏切回竖屏后再也横不了」的正解）。
    @State private var orientationRequestTask: Task<Void, Never>?
    @State private var orientationGeneration = 0
    /// 系统拒绝转屏时的那句原话（回调在后台队列上到，见 `OrientationFailure`）。
    @State private var orientationFailure = OrientationFailure()
    /// 布局看到竖屏时先等它稳住再退全屏，别打断正在进行的转屏。
    @State private var landscapeExitTask: Task<Void, Never>?
    /// 本次按压是否已经进入长按状态（用来区分「松手时是短按还是长按结束」）。
    /// 全屏：画面占满窗口、横屏、隐藏状态栏，选集与线路区收起。
    /// 对应原版 `fillsWindow = fullscreen || (maxWidth > maxHeight)`。
    @State private var isFullscreen = false
    /// 这一轮全屏里是否真的横过屏；用来区分「刚进来还没转」和「用户转回去了」。
    @State private var sawLandscape = false
    /// 亮度 / 音量的横条浮层：左半边调亮度、右半边调音量，都自己画。
    @State private var gestureHUD: GestureHUDValue?
    /// 音量键的监听：它只当触发，画的是手势那条浮层（LP 2026-11-06）。
    /// 两个来源同时盯：会话音量（`AVAudioSession.outputVolume`）和 MPVolumeView
    /// 滑杆（媒体音量）。加载 / 缓冲 / 暂停时前者常常一整个阶段都不报变化，
    /// 只有滑杆会动，所以不能只挂会话那一个（LP 2026-11-08 第 3 条）。
    @State private var volumeObserver: NSKeyValueObservation?
    @State private var volumeSliderObserver: NSKeyValueObservation?
    /// 这一页还在盯音量吗：`onDisappear` 关掉，晚到的那几拍重试看见它就放弃，
    /// 别给已经离开的页面挂一个永远拆不掉的 KVO。
    @State private var isObservingVolume = false
    /// 上一次画出来的音量值：两个来源会重复报同一个值，按它去重，
    /// 免得一下按键把浮层重排两遍、定时器互相顶掉。
    @State private var lastShownVolume: Double = -1
    /// 横滑调进度时中间那朵「+15s」。
    @State private var seekHUD: Int?
    /// 双击中间那朵播放 / 暂停符号。
    @State private var playPauseHUD: String?
    /// 这一串拖动在调什么：进度、亮度还是音量。起手时按方向定死，中途不再改。
    @State private var dragAxis: DragAxis?
    /// 起手那一刻的亮度或音量。
    @State private var dragValueStart: Double?
    /// 横滑起手时这一集的进度，以及滑到哪儿（松手才真 seek）。
    @State private var seekDragStart: Double?
    @State private var seekDragTarget: Double?
    /// 浮层淡出的定时器，下一次滑动会把它作废重排。
    @State private var hudHideTask: Task<Void, Never>?
    /// 画面 1/4 处那句话的重排序号：同一句文案连着来两次（比如连着标两集）
    /// 要重新计时，不能沿用上一条的 2 秒（LP 2026-11-08）。
    @State private var hudToastSerial = 0
    /// 最近一次长按触发的时间：长按松手后系统仍会补一次短按，用它挡掉。
    @State private var lastLongPressAt: Date?
    /// 画面下面那片选中的页。
    @State private var detailTab: PlayerDetailTab = .episodes
    /// 这部番的吐槽（按需加载，进页面不拉）。
    @State private var comments: [BangumiCommentItem] = []
    @State private var commentTotal = 0
    @State private var isLoadingComments = false
    @State private var commentRequestGeneration = 0
    @State private var commentLoadFailed = false
    /// 评论：最新优先还是最早优先；切换时只在本地重排，不再请求。
    @State private var isCommentsAscending = false
    /// 当前看的是哪一集的评论（nil 就是整部番），切集时用。
    @State private var commentEpisode: Int?
    /// 100 集以上时，快速跳到某一块（每 100 集一块）。
    @State private var episodeGridPage = 0
    /// 下载选择态（LP 5084 / Colo 5090）：true 时面板顶行换成 取消 / 全选 / 下载 N 集，
    /// 格子点一下是勾选而不是切集。不弹窗，面板原地变。
    @State private var isChoosingDownloads = false
    /// 选择态里勾中的集数。
    @State private var downloadSelection: Set<Int> = []
    /// 更多菜单里几个「开个页面」的入口。收到一个枚举里，
    /// 一次只可能有一张：几个布尔各自为真时后弹的那张会被系统吞掉。
    @State private var activeSheet: PlayerSheet?
    /// 从「更多 → 弹幕检索」进来时先暂停；换完或取消，只要离开检索页就续播。
    @State private var resumesAfterDanmakuSearch = false
    /// 从「弹幕设置」进来时若正在播放先暂停；关掉弹幕设置后自动续播。
    @State private var resumesAfterDanmakuSettings = false
    /// 「播放信息」里点了媒体地址后的「已复制」提示，1.2 秒后自动收回。
    @State private var mediaURLCopied = false
    @State private var mediaURLCopiedTask: Task<Void, Never>?
    /// 横屏选集：从右侧滑进来的玻璃窗口（LP 3637 要的，不再是铺满整屏的面板）。
    @State private var showsEpisodesPanel = false
    /// 定时关闭：截止时刻，nil 就是没定。
    @State private var sleepTimerEnd: Date?
    @State private var sleepTimerChosenMinutes: Int?
    @State private var sleepTimerTask: Task<Void, Never>?
    /// 片头片尾弹窗：AniSkip 的时间轴 + 倒数 / 撤销 / 切集三态。
    @State private var skipPill = SkipSegmentPillModel()
    /// 桌面端与外接指针交互状态（§8）。
    @State private var hasDetectedPointer = false
    @State private var lastHoverLocation: CGPoint?
    @State private var pointerIdleHideTask: Task<Void, Never>?
    @State private var pointerCursorHidden = false
    @State private var isHoveringVolumeControl = false
    @State private var volumeHoverDismissTask: Task<Void, Never>?
    /// 播放页内呼出选源面板的控制器与「去规则仓库」延迟跳转标志（§6）。
    @State private var playerSourceController: InfoController?
    @State private var openRuleShopAfterSourceSheet = false
    /// 宽屏非全屏左栏下方信息卡使用的番剧元数据缓存。
    @State private var bangumiInfo: BangumiItem?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    /// 主题色分深浅两档，菜单跟着走（Colo 3344）。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    /// 由现有 UIScene 通知维护的播放策略标志；诊断另外读取实际 activationState。
    @State private var sceneIsActive = true

    /// 常规宽度（iPad、Duo 内屏）：全屏就地铺开，不转屏、不强制横屏
    /// （Colo 7725 §4.2 A）。compact（手机、外屏）保持原来的横屏全屏。
    private var usesInlineFullscreen: Bool { horizontalSizeClass == .regular }

    /// 宽形态非全屏下右侧「选集 / 评论」面板自适应宽度（336–420pt，随总宽弹性缩放）。
    private static func wideSidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        min(max((totalWidth * 0.39).rounded(), 336), 420)
    }

    /// 宽形态非全屏左栏下方信息区保留的最小高度，确保标题与操作胶囊始终完整可见。
    private static let minWideInfoHeight: CGFloat = 148

    /// 非全屏且宽形态（`width > height`）改左右两栏：
    /// 左栏为「顶部 16:9 画面 ＋ 下方番剧信息与换源/追番/下载操作区」，右栏专职「选集 / 评论」。
    private var isWideSplitLayout: Bool {
        !isFullscreen && containerSize.width > containerSize.height && containerSize.width > 0
    }

    /// 画面与控制层的安全区忽略范围：非全屏一律保留系统安全区（返回 `[]`），
    /// 全屏态统一忽略四边容器安全区并交由 `controlLeadingPadding` / `fullscreenBottomPadding` 精确控制边距，
    /// 避免自定义 `PlayerStageLayout` 在手机横屏全屏下被外层 `NavigationStack` 残留顶部安全区整体下推。
    private var videoIgnoredSafeAreaEdges: Edge.Set {
        isFullscreen ? .all : []
    }

    /// 同一棵扁平视图树承载上下单栈、宽形态左右主副工作台与全屏态切换：
    /// `playerArea` 恒为第 0 个子视图，折叠屏开合、旋转与全屏切换全程零重建、不断流。
    private func adaptivePlayerLayout(_ controller: PlayerController) -> some View {
        PlayerStageLayout(
            isFullscreen: isFullscreen,
            isWideSplit: isWideSplitLayout,
            videoAspectRatio: max(aspectRatioMode.frameAspectRatio, 0.1)
        ) {
            playerArea(controller)
                .layoutValue(key: PlayerStageRoleKey.self, value: .player)
            if !isFullscreen, isWideSplitLayout {
                widePlayerInfoCard(controller)
                    .layoutValue(key: PlayerStageRoleKey.self, value: .wideInfo)
            }
            if !isFullscreen {
                episodeArea(controller)
                    .layoutValue(key: PlayerStageRoleKey.self, value: .episodes)
            }
        }
    }

    /// 非全屏（状态栏与侧栏可见）时按宽高方向分槽更新安全区快照，避免旋转、折叠或全屏隐藏系统层后丢失边距。
    private func recordSafeAreaGeometry(size: CGSize, insets: EdgeInsets) {
        containerSize = size
        containerInsets = insets
        guard !isFullscreen, size.width > 0, size.height > 0 else { return }
        if size.width > size.height {
            landscapeSafeInsetsSnapshot = insets
        } else {
            portraitSafeInsetsSnapshot = insets
        }
    }

    /// 画面那一半（body 的前半截）。
    ///
    /// 从 body 里拆出来的：整条修饰符链太长，编译器的类型检查会超时
    /// （`unable to type-check this expression in reasonable time`）。
    private var playbackScaffold: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let controller {
                    adaptivePlayerLayout(controller)
                        .ignoresSafeArea(.container, edges: ignoresWindowEdges ? .all : [])
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 全屏右侧滑入的选集抽屉（§7 G3）：上下及右侧各留 16pt 边距、四角 28pt 连续圆角玻璃悬浮面板。
                if showsEpisodesPanel, let controller {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { closeEpisodesPanel() }

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        episodesPanel(controller)
                    }
                    .ignoresSafeArea(.container, edges: .all)
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsEpisodesPanel)
        .background(Color.black.ignoresSafeArea())
        // 竖屏全屏不做：先真的横过屏，之后用户又转回竖屏，才退出全屏。
        // 只看「现在是不是竖的」会误判——刚点全屏、屏幕还没来得及转的那一帧
        // 本来就是竖的，那样一进就被自己的判据弹出来（LP 2026-10-25 现场）。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            }
            .ignoresSafeArea()
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        logLifecycleSnapshot("onAppear")
                        SourceSheetCoordinator.shared.shouldReopenSourcesOnReturn = false
                        recordSafeAreaGeometry(size: proxy.size, insets: proxy.safeAreaInsets)
                        updateIdleTimer()
                    }
                    .onChange(of: proxy.safeAreaInsets) { _, insets in
                        recordSafeAreaGeometry(size: proxy.size, insets: insets)
                    }
                    .onChange(of: proxy.size) { _, size in
                        recordSafeAreaGeometry(size: size, insets: proxy.safeAreaInsets)
                        // 常规宽度不按宽高猜方向：不转屏，也就没有「横过以后又转回去」
                        // 这回事（Colo 7725 §4.2 A）。
                        if !usesInlineFullscreen, size.width > size.height {
                            sawLandscape = true
                            landscapeExitTask?.cancel()
                            landscapeExitTask = nil
                            surface.requestRender()
                        } else if !usesInlineFullscreen, isFullscreen, sawLandscape {
                            sawLandscape = false
                            // 等竖屏稳住再退：转屏途中会报几帧中间尺寸，见一帧竖的
                            // 就退全屏会把正在进行的转屏打断（@developer3 4308 的第四条）。
                            landscapeExitTask?.cancel()
                            landscapeExitTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled, isFullscreen, sawLandscape == false,
                                      containerSize.width <= containerSize.height
                                else { return }
                                exitFullscreen()
                            }
                        }
                    }
            }
        }
        .statusBarHidden(isFullscreen)
        // 全屏连 home 指示条一起藏：LP 2026-10-29 定这里保持原样（不动这一行）。
        // 「上滑退 app 要两下」改在手势那侧：画面最底下那条起手让给系统。
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .background {
            KazumiSwipeBackEnabler(
                isEnabled: !isFullscreen
                    && !showsEpisodesPanel
                    && activeSheet == nil
                    && !isEditingSkipSeconds
                    && !SourceSheetCoordinator.shared.isPresented,
                excludedWindowRect: playerAreaWindowFrame
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        // 播放器页面范围内把 tint 压回系统黑白：AppRoot 那句全局 .tint(accentColor)
        // 会顺着 tint 环境传到菜单行上，菜单的符号就变主题色
        // （LP 2026-10-28；Colo 4282 / @developer3）。选集、评论那几颗菜单
        // 在行上显式写了自己那份主题色，不受这句影响。
        .tint(.primary)
        .overlay(alignment: .top) { toastView }
        .overlay { skipSecondsDialog }
        .sheet(item: $activeSheet, onDismiss: {
            scheduleControlsHide()
            if resumesAfterDanmakuSearch {
                resumesAfterDanmakuSearch = false
                surface.play()
            }
            if resumesAfterDanmakuSettings {
                resumesAfterDanmakuSettings = false
                surface.play()
            }
        }) { sheet in
            sheetContent(sheet)
        }
    }

    var body: some View {
        desktopInputObservers
    }

    /// 第四段修饰符：硬件键盘快捷键（`.onKeyPress`）与选源面板后续跳转（§6 / §8）。
    private var desktopInputObservers: some View {
        screenLifecycleObservers
            .focusable(!danmakuFieldFocused && !isEditingSkipSeconds && activeSheet == nil)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handlePlayerKeyPress(press)
            }
            .onChange(of: SourceSheetCoordinator.shared.isPresented) { _, presented in
                if !presented, openRuleShopAfterSourceSheet {
                    openRuleShopAfterSourceSheet = false
                    environment.router.push(.pluginShop)
                }
            }
    }

    /// 第一段修饰符：提示气泡、全屏、播放状态、进度条。
    ///
    /// 这一串拆成几段，是因为整条链放在一个表达式里，编译器的类型检查会超时
    /// （「unable to type-check this expression in reasonable time」）。
    private var contentObservers: some View {
        playbackScaffold
        // 竖屏侧滑返回：导航栏藏了之后系统的手势会失效，这里把它接回来（全屏时不认）。

        .animation(.easeOut(duration: 0.2), value: surface.toastMessage)
        .animation(.easeOut(duration: 0.2), value: surface.hudToastMessage)
        // 弹幕拉不到的时候说一句原因（Ato：对不上号 / 接口失败要说，
        // 「这集本来就没弹幕」是正常情况，安静地不显示）。
        // 「看到 90% 自动标为看过」成了也说一句，跟倍速/收藏同一处（1/4 那条线）。
        //
        // 文案永远是同一句「已标记本集看过」：以前服务端只存这句字符串，连标两集
        // 值没变，`onChange` 就不再触发——只有第一集有提示，后面全没有，
        // 而 Bangumi 上其实每集都标上了（LP 2026-11-08）。服务端现在带序号，
        // 这里再抬一次 `hudToastSerial`，让同一句也能把 2 秒重新计时。
        .onChange(of: environment.bangumiProgress.markedNotice) { _, notice in
            guard let notice else { return }
            hudToastSerial &+= 1
            surface.hudToastMessage = notice.message
        }
        .onChange(of: environment.bangumiProgress.failureNotice) { _, notice in
            guard let notice else { return }
            hudToastSerial &+= 1
            surface.hudToastMessage = notice.message
        }
        // 下载失败说一句带原因的（LP 5115）：格子上不再挂红点，改成弹一下。
        .onChange(of: environment.downloads.failureNotice) { _, message in
            guard let message, !message.isEmpty else { return }
            surface.hudToastMessage = message
            environment.downloads.failureNotice = nil
        }
        // 进页面 / 切线路把剧集列表重新拉一遍时，上一轮的失败痕迹一并清掉，
        // 格子回到「没下过」（LP 5115）。
        .onChange(of: controller?.currentEpisode) { _, _ in
            playPauseHUD = nil
            if let controller {
                environment.downloads.clearFailures(recordKey: downloadRecordKey(controller))
            }
        }
        .onChange(of: controller?.danmakuMessage) { _, message in
            if let message, !message.isEmpty {
                // 放画面 1/4 那条线上（LP 4773），跟倍速/收藏/定时关闭同一个位置。
                surface.hudToastMessage = message
            }
        }
        .onChange(of: SyncplayManager.shared.lastToast) { _, toast in
            if let toast, !toast.isEmpty {
                surface.hudToastMessage = toast
            }
        }
        .onChange(of: activeSheet) { _, sheet in
            if sheet == .danmakuSettings {
                if surface.isPlaying {
                    resumesAfterDanmakuSettings = true
                    surface.pause()
                }
            }
        }
        .onChange(of: controller?.danmakuStatus) { _, status in
            switch status {
            case .unavailable, .failed:
                danmakuEnabled = false
            case .idle, .loading, .ready, .empty, nil:
                break
            }
        }
        // 退出全屏时把选集窗口收掉：它只属于横屏，留着会压在竖屏的选集区上。
        .onChange(of: isFullscreen) { _, fullscreen in
            if !fullscreen, showsEpisodesPanel {
                closeEpisodesPanel()
            }
            surface.requestRender()
        }
        .onChange(of: controller?.phase) { _, phase in
            if phase == .ready {
                scheduleControlsHide()
                SourceSheetCoordinator.shared.clearFailedReturnToSources()
            } else if case .failed = phase {
                SourceSheetCoordinator.shared.markFailedReturnToSources(bangumiID: bangumiID)
            }
        }
        .onChange(of: surface.errorMessage) { _, error in
            if error != nil {
                SourceSheetCoordinator.shared.markFailedReturnToSources(bangumiID: bangumiID)
            }
        }
        .onChange(of: surface.isPlaying) { _, playing in
            // 无论播放还是暂停均跟随全局倒计时隐藏控制栏；状态切换时若控制栏可见则重算倒计时。
            updateIdleTimer()
            if controlsVisible {
                scheduleControlsHide()
            }
            pictureInPicture?.setPlaying(playing)
            // 用户亲手按的暂停不归「回前台自动播放」管。
            if playing {
                // 切后台那一拍我们刚 pause()，内核还会有一两个快照报「还在走」，
                // 那不是用户的意思：只有在前台真的播起来，才算「用户亲手按的暂停」
                // 作废。不然这一拍会把 pausedByBackground 洗掉，回前台就不续播了。
                if isForegroundActive { pausedByBackground = false }
                // 起播那一刻立即写一次：不然要等到下一个 2 秒节拍，
                // 万一这期间出事，控制中心一次都没写出去过。
                syncNowPlaying()
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
    }

    /// 第二段修饰符：250ms 节拍、切前后台、画中画设置、快进秒数输入。
    private var playbackObservers: some View {
        contentObservers
        // 片头片尾弹窗：跟播放内核同一个 250ms 节拍（快照泵就是这条节拍），
        // 位置 / 时长喂进去、seek 和切集请求接出来。时间轴只查一次，
        // 用户把 AniSkip 关了就把手上这份清掉。
        .task {
            // 控制中心那几颗键只接一次：接在画面上，它们才真能暂停、切集、拖进度。
            configureNowPlayingCommands()
            // 一进页面就把代理读一次：开关本来就开着的那次播放不靠别的时机。
            refreshProxy()
            // 节拍计数只活在这个循环里：写进 @State 会让整个播放页每 250ms
            // 重新求值一次，白白增加 SwiftUI 的 body 开销。
            var nowPlayingTick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if let controller {
                    controller.maybeLoadSkipSegments(
                        duration: surface.duration,
                        enabled: settings.aniSkipLookup
                    )
                    skipPill.segments = settings.aniSkipLookup ? controller.skipSegments : .empty
                    skipPill.hasNextEpisode = controller.currentEpisode < controller.episodes.count
                }
                skipPill.isPlaybackReady = surface.hasStartedPlayback
                skipPill.position = surface.currentTime
                skipPill.duration = surface.duration
                skipPill.isScrubbing = isScrubbing
                skipPill.update()
                // 「正在播放」每 2 秒同步一次进度：只在状态变化时写的话，
                // 拖动进度、跨集以后控制中心那条进度会停在旧位置。
                nowPlayingTick += 1
                if nowPlayingTick % 8 == 0 {
                    syncNowPlaying()
                }
                if nowPlayingTick % 4 == 0 {
                    updateIdleTimer()
                }
                if let target = skipPill.consumeSeekTarget() {
                    surface.seek(to: target)
                }
                if skipPill.consumeNextEpisodeRequest() {
                    nextEpisode()
                }
            }
        }
        // 后台播放关着就退到后台即暂停；开着则让音频会话保持可播，
        // 熄屏 / 切出去继续出声（LP 清单「后台播放」，默认关）。
        // 具体做什么拆到下面两个方法里：这个闭包自己已经很长，再往里塞
        // 编译器的类型检查会超时（「unable to type-check in reasonable time」）。
        // 保留现有 UIScene 通知订阅和处理顺序。
        // 回调标记仅表示收到通知，不表明其触发来源。
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { notification in
            guard sceneMatchesPlayer(notification.object as? UIScene) else { return }
            sceneIsActive = false
            logLifecycleSnapshot("UIScene.didEnterBackgroundNotification.received", scene: notification.object as? UIScene)
            // 进后台 / 锁屏一律放弃常亮；回前台且还在播再重新判断。
            updateIdleTimer()
            // 记录通知回调时的音频会话和卡片字段，不据此推断卡片点击结果。
            PlayerAudioSession.shared.logSnapshot(String(localized: "切到后台"))
            handleBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
            guard sceneMatchesPlayer(notification.object as? UIScene) else { return }
            sceneIsActive = true
            logLifecycleSnapshot("UIScene.didActivateNotification.received", scene: notification.object as? UIScene)
            updateIdleTimer()
            handleForeground()
            // 回前台重新读一次代理：用户可能刚把代理工具打开/关掉。
            refreshProxy()
        }
        // 手填的代理改了也要重读：开关或地址任何一个变了都算。
        .onChange(of: settings.proxyEnabled) { _, _ in
            refreshProxy()
        }
        .onChange(of: settings.proxyUrl) { _, _ in
            refreshProxy()
        }
        .onChange(of: settings.backgroundAutoPiP) { _, enabled in
            if enabled {
                makePictureInPictureController(settingsStore: settings)
            } else {
                pictureInPicture?.setAutomaticStartAllowed(false)
            }
        }
        .onChange(of: isEditingSkipSeconds) { _, editing in
            if editing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
    }

    /// 第三段修饰符：控制栏自动隐藏、启动、定期落进度、离开页面。
    private var screenLifecycleObservers: some View {
        playbackObservers
        // 自动隐藏：用 `.task(id:)` 而不是自建 Task，离开页面时系统会自己取消。
        .task(id: menuOpen) {
            guard menuOpen else { return }
            // 看菜单还在不在：在就不收控制栏，收了就恢复自动隐藏。
            while !Task.isCancelled && menuOpen {
                try? await Task.sleep(for: .milliseconds(300))
                if SystemMenuProbe.isPresented {
                    probeSawMenu = true
                    probeLastSeen = Date()
                } else if probeSawMenu, Date().timeIntervalSince(probeLastSeen) > 1.2 {
                    // 菜单已经收了：控制栏恢复自动隐藏。
                    menuOpen = false
                    probeSawMenu = false
                    scheduleControlsHide()
                } else if !probeSawMenu, Date().timeIntervalSince(menuOpenedAt) > 45 {
                    // 探测器没认出来（换过实现就不一定认得出），留个上限，别把控制栏钉死。
                    menuOpen = false
                    scheduleControlsHide()
                }
            }
        }
        .task(id: hideGeneration) {
            guard canHideControls else { return }
            let seconds = Double(settings.playerControllerLayerDisappearTime) / 1000
            var remaining = seconds
            var sawMenu = false
            while true {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, canHideControls else { return }
                // 系统菜单（`Menu`）开着就停在原地：它不报开合，只能看它在不在。
                if SystemMenuProbe.isPresented {
                    sawMenu = true
                    remaining = 0.4
                    continue
                }
                if sawMenu {
                    // 菜单刚关掉：重新按设置全额起算，不是接着漏下的时间收。
                    sawMenu = false
                    remaining = seconds
                    continue
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    controlsVisible = false
                }
                return
            }
        }
        .task {
            await bootstrapPlaybackIfNeeded()
        }
        .task(id: bangumiID) {
            if let cached = BangumiSubjectCache.shared.item(for: bangumiID) {
                bangumiInfo = cached
            } else if bangumiID > 0 {
                bangumiInfo = await BangumiAPI.info(id: bangumiID)
            }
        }
        // 音量键监听跟画面有没有起播无关（LP 2026-11-08 第 3 条）：只要人还在播放页，
        // 按音量键就该出那条横条。单独一条 task 装，不挂在起播流程里——
        // 那条流程在解析阶段就返回了，晚装的监听要等下一集才有。
        .task {
            observeSystemVolume()
        }
        // 音量键到 0（再按减）/ 100（再按加）那两下系统不给任何信号：
        // 值没变，`AVAudioSession.outputVolume` 与 MPVolumeView 滑杆都不报，
        // 私有那条 `AVSystemController_...` 通知在本机也不发。公开 API 没有
        // 「按了但没变」的钩子，这条就此作罢（LP 2026-11-08：做不到就不做）。
        .task {
            // 播放期间定期落一次进度；退出与播完时还会各写一次。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                guard let controller else { continue }
                persistProgress(controller)
            }
        }
        .onDisappear {
            if isPlaybackFailed {
                SourceSheetCoordinator.shared.markFailedReturnToSources(bangumiID: bangumiID)
            }
            // A view lifecycle callback is not evidence of a deliberate return action.
            logLifecycleSnapshot("onDisappear.beforeCardClear")
            // 保留现有清理顺序。
            NowPlayingCenter.shared.clear()
            restoreAudioSessionAfterPlayer()
            volumeObserver?.invalidate()
            volumeObserver = nil
            volumeSliderObserver?.invalidate()
            volumeSliderObserver = nil
            isObservingVolume = false
            pointerIdleHideTask?.cancel()
            pointerIdleHideTask = nil
            volumeHoverDismissTask?.cancel()
            volumeHoverDismissTask = nil
            pointerCursorHidden = false
            // 离开播放器：屏幕常亮无论如何都要还回去，不能带出这个页面。
            UIApplication.shared.isIdleTimerDisabled = false
            // 先摘掉结束回调，避免关闭播放器时的 finish 又被当成「播完」触发连播。
            surface.onFinish = nil
            surface.onPlaybackStarted = nil
            surface.onPlayStateBroadcast = nil
            SyncplayManager.shared.onRemotePlay = nil
            SyncplayManager.shared.onRemotePause = nil
            SyncplayManager.shared.onRemoteSeek = nil
            SyncplayManager.shared.disconnect()
            // 长按手势若被系统取消，松手回调不会来，退出时兜一次恢复。
            endTemporarySpeed()
            // 横屏直接离开时先明确请求竖屏；只放开方向集合不会触发旋转，
            // 开着系统竖屏锁时其它页面会继续停在横屏。
            isFullscreen = false
            sawLandscape = false
            if !usesInlineFullscreen, isWindowLandscape {
                requestOrientation(.portrait, releaseAfterSuccess: true)
            } else {
                releaseOrientation()
            }
            if let controller { persistProgress(controller) }
            // 画中画先拆：它的取帧任务绑定当前 mpv 引擎，
            // 必须赶在 `surface.stop()` 之前取消。
            pictureInPicture?.teardown()
            pictureInPicture = nil
            surface.stop()
            controller?.stop()
        }
    }

    /// Read-only view state plus actual scene activation states, separate from sceneIsActive.
    private func logLifecycleSnapshot(_ event: String, scene: UIScene? = nil, details: String = "") {
        let state = "player=\(diagnosticPlayerID) controllerPresent=\(controller != nil)"
            + " sceneIsActive=\(sceneIsActive) isPlaying=\(surface.isPlaying)"
            + " corePaused=\(surface.corePaused) coreIdle=\(surface.coreIdle)"
            + " isReady=\(surface.isReady) position=\(surface.currentTime) duration=\(surface.duration)"
            + " pausedByBackground=\(pausedByBackground) fullscreen=\(isFullscreen)"
        PlaybackLifecycleDiagnostics.log("PlayerScreen.\(event)", scene: scene,
                                         details: details.isEmpty ? state : "\(state) \(details)")
    }

    /// 各种半屏页面的内容。抽成方法是因为原来这段 switch 直接写在 `.sheet` 里，
    /// 修饰符链一长，编译器的类型检查就超时了。
    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .danmakuSettings:
            NavigationStack {
                DanmakuSettingsScreen()
                    .navigationTitle("弹幕设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // 右上角关闭：跟下滑关闭是同一个动作。标题居中，
                        // 左边不放东西，也不再加「取消」（Colo 2026-10-27）。
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismissKeyboard()
                                activeSheet = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .regular))
                                    // 弹窗是浅底，跟系统走；白色只属于播放器的控制层
                                    // （LP 2026-10-28「关闭怎么变白色了」/ Colo 同条）。
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("关闭")
                        }
                    }
            }
            .environment(settings)
            .environment(environment.router)
        case .danmakuSource:
            NavigationStack {
                DanmakuSourceSheet(
                    initialKeyword: danmakuInitialKeyword,
                    currentEpisode: controller?.currentEpisode ?? episode,
                    onSelectEpisode: applyManualDanmaku
                )
            }
            .presentationDetents([.medium, .large])
        case .airPlay:
            airPlaySheet
        case .externalPlay:
            externalPlaySheet
        case .syncPlay:
            SyncPlaySheet(
                settings: settings,
                isPresented: Binding(
                    get: { activeSheet == .syncPlay },
                    set: { if !$0 { activeSheet = nil } }
                ),
                surface: surface
            )
        case .videoInfo:
            videoInfoSheet
        }
    }

    /// 进页面时把播放器建起来（原来直接写在 `.task` 闭包里）。
    ///
    /// 搬出来是因为那个闭包太大了：编译器的类型检查在那里超时（413 行）。
    /// 逻辑一行没改。
    private func bootstrapPlaybackIfNeeded() async {
        guard controller == nil else { return }
        SourceSheetCoordinator.shared.shouldReopenSourcesOnReturn = false
        // 先把两个 store 取成局部常量：闭包会长期挂在 surface 上，
        // 这样试不会把整个 View（含 @Environment 包装器）一起捕获。
        let settingsStore = settings
        let library = environment.library
        danmakuEnabled = settingsStore.danmakuEnabled
        applyAudioSessionPolicy()
        playbackRate = Float(settingsStore.playSpeed)
        // 默认视频比例：设置页选的那一档作为这次播放的起点，
        // 播放器里再改只影响这一次（与原版一样不写回设置）。
        aspectRatioMode = settingsStore.defaultAspectRatio
        let created = PlayerController(
            bangumiID: bangumiID,
            episode: episode,
            source: source,
            plugins: environment.plugins,
            library: library,
            resumeRoad: resumeRoad,
            resumeFromHistory: resumeFromHistory,
            resumeRule: resumeRule,
            // 离线播放（Colo 5174）：这集在本地有文件就直接放它。
            // 按番剧 + 规则名查，不管线路：下的时候是哪条线路、现在进的是哪条，
            // 对用户来说都是「这集我下过」。
            localFile: { number in
                return environment.downloads.localURL(
                    bangumiID: bangumiID,
                    pluginName: source?.pluginName ?? resumeRule ?? "",
                    number: number
                )
            },
            // 在线列表抓不到时退回这份下载记录：只列已下载的集。
            downloadedNumbers: {
                environment.downloads.downloadedNumbers(
                    bangumiID: bangumiID,
                    pluginName: source?.pluginName ?? resumeRule ?? ""
                )
            },
            // 本集加进了下载但还没下完：走在线解析时画面要说一句（Camo 5208）。
            episodeIncomplete: { number in
                environment.downloads.isEpisodeIncomplete(
                    bangumiID: bangumiID,
                    pluginName: source?.pluginName ?? resumeRule ?? "",
                    number: number
                )
            }
        )
        controller = created
        // 上一集 / 下一集必须在拿到 controller **之后**接：早接一步抓到的是 nil（LP 5042）。
        bindEpisodeRemoteCommands(created)
        // 默认倍速：就绪 / 重新起播时由画面模型再补一次（AVPlayer 会回到 1.0）。
        let startSpeed = Float(settingsStore.playSpeed)
        surface.setPlaybackRate(startSpeed)
        // 自动连播：正常播完后根据设置决定是否切到下一集。
        // 起播稳定后把嗅探用的 WebView 放掉（LP 4938 Step 2）：媒体地址已经解析到、
        // mpv 已经在放，那个隐藏页面就没有存在的必要了。WKWebView 只要还活着，它的
        // WebContent 子进程就还在，跟 mpv、画中画控制器一起向系统认领媒体路由——
        // 切后台那一秒三方抢路由，灵动岛 / 锁屏点击就失效。
        // 回调由 `PlayerSurfaceModel` 在「首帧之后又过了 0.15 秒」那一刻发一次
        // （见 `onPlaybackStarted`）；不写在 SwiftUI 的 `.onChange` 里，那串 modifier
        // 已经长到编译器的类型检查会超时。
        //
        // 必须挂在这里、不能挂在上面 `applyAudioSessionPolicy()` 里：那一步跑在
        // `controller = created` **之前**，闭包弱引用抓到的是当时还是 nil 的那个值，
        // 回调等于永远是空的（2026-10-30 模拟器上就是这么一次都没释放）。
        surface.onPlaybackStarted = { [weak created] in
            created?.releaseSourceWebView()
            // mpv 的 `ao_audiounit` 在音频流初始化那一刻会把会话重设一遍
            // （真机日志里 `模式=AVAudioSessionModeMoviePlayback` 就是它盖的，LP 4993）。
            // 所以起播一稳定就立刻掰回 `.default`，不等 2 秒那一次轮询。
            PlayerAudioSession.shared.reapplyIfNeeded()
            updateIdleTimer()
            if let ep = created?.currentEpisode, surface.duration > 0 {
                SyncplayManager.shared.onLocalEpisode(title: "EP\(ep)", duration: surface.duration)
            }
            if settingsStore.backgroundAutoPiP,
               pictureInPicture?.hasOngoingPictureInPicture != true,
               isForegroundActive {
                makePictureInPictureController(settingsStore: settingsStore)
            }
        }
        surface.onFinish = { [weak created] surface in
            guard let created else { return }
            // 播完先落一次进度：结尾 5 秒内会归零，当作「已看完」的边界。
            persistWatchProgress(
                library: library,
                privateMode: settingsStore.privateMode,
                controller: created,
                position: surface.currentTime,
                duration: surface.duration
            )
            guard settingsStore.autoPlayNext else { return }
            guard created.currentEpisode < created.episodes.count else {
                // 已是末集：停下来并给一句提示，不静默什么都不做。
                surface.toastMessage = String(localized: "已经是最新一集")
                return
            }
            let next = created.currentEpisode + 1
            surface.prepareForNewEpisode()
            Task { await created.selectEpisode(next) }
        }
        resumeIfNeeded(library: library, controller: created)
        // 后台自动画中画：设置开着才把控制器建出来，并提前把图层挂进窗口。
        // 系统的「自动画中画」要求内联图层在切后台**之前**就存在；等退后台
        // 那一刻再建，`isPictureInPicturePossible` 往往一直是 false。
        if settingsStore.backgroundAutoPiP {
            makePictureInPictureController(settingsStore: settingsStore)
        }
        setupSyncplayBindings()
        await created.start()
    }

    /// 绑定一起看（Syncplay）本地广播与远端指令。
    private func setupSyncplayBindings() {
        let playerSurface = surface
        surface.onPlayStateBroadcast = { isPaused, pos, isSeek in
            if isSeek {
                SyncplayManager.shared.onLocalSeek(to: pos, paused: isPaused)
            } else if isPaused {
                SyncplayManager.shared.onLocalPause(position: pos)
            } else {
                SyncplayManager.shared.onLocalPlay(position: pos)
            }
        }

        SyncplayManager.shared.onRemotePlay = { [weak playerSurface] user, pos in
            guard let playerSurface else { return }
            if playerSurface.isPaused {
                playerSurface.play()
            }
            if abs(playerSurface.currentTime - pos) > 2.0 && pos > 0 {
                playerSurface.seek(to: pos)
            }
            playerSurface.toastMessage = String(localized: "\(user) 开始了播放")
        }

        SyncplayManager.shared.onRemotePause = { [weak playerSurface] user, pos in
            guard let playerSurface else { return }
            if !playerSurface.isPaused {
                playerSurface.pause()
            }
            if abs(playerSurface.currentTime - pos) > 2.0 && pos > 0 {
                playerSurface.seek(to: pos)
            }
            playerSurface.toastMessage = String(localized: "\(user) 暂停了播放")
        }

        SyncplayManager.shared.onRemoteSeek = { [weak playerSurface] user, pos in
            guard let playerSurface else { return }
            playerSurface.seek(to: pos)
            let s = Int(pos.rounded())
            let mm = s / 60
            let ss = s % 60
            let clockStr = String(format: "%02d:%02d", mm, ss)
            playerSurface.toastMessage = String(localized: "\(user) 跳转到了 \(clockStr)")
        }
    }

    /// 建（或复用）画中画控制器。
    private func makePictureInPictureController(settingsStore: SettingsStore) {
        if let pictureInPicture {
            pictureInPicture.setAutomaticStartAllowed(settingsStore.backgroundAutoPiP)
            pictureInPicture.setPlaying(surface.isPlaying)
            pictureInPicture.prepare(engine: surface.engine, surface: surface)
            return
        }
        let pip = PictureInPictureController()
        let backgroundPaused = $pausedByBackground
        let playerSceneActive = $sceneIsActive
        pip.onSettlement = { [weak surface] settlement in
            guard let surface else { return }
            switch settlement {
            case .active:
                // PiP feed reads decoded frames directly; stop only the inline
                // gpu-next/CAMetalLayer output while the system window is active.
                surface.setRenderingLocked(true)
                if backgroundPaused.wrappedValue {
                    backgroundPaused.wrappedValue = false
                    if !surface.isPlaying { surface.play() }
                }
            case .backgroundFallback(let reason):
                KazumiLogBuffer.player("画中画: 后台策略收口（\(reason)）")
                applyBackgroundPlaybackPolicy(
                    surface: surface,
                    settingsStore: settingsStore,
                    backgroundPaused: backgroundPaused
                )
            case .stoppedInBackground:
                KazumiLogBuffer.player("画中画: 后台关闭小窗，按后台播放设置收口")
                applyBackgroundPlaybackPolicy(
                    surface: surface,
                    settingsStore: settingsStore,
                    backgroundPaused: backgroundPaused
                )
            case .foreground:
                surface.setRenderingLocked(false)
                let shouldResume = settingsStore.resumeOnForeground && backgroundPaused.wrappedValue
                if shouldResume {
                    backgroundPaused.wrappedValue = false
                    if !surface.isPlaying { surface.play() }
                }
                let active = isForegroundActive
                playerSceneActive.wrappedValue = active
                updateIdleTimer()
            }
        }
        pip.onActiveChanged = { [weak surface] active in
            surface?.setRenderingLocked(active)
        }
        pictureInPicture = pip
        pip.setAutomaticStartAllowed(settingsStore.backgroundAutoPiP)
        pip.setPlaying(surface.isPlaying)
        pip.prepare(engine: surface.engine, surface: surface)
    }

    private func applyBackgroundPlaybackPolicy(
        surface: PlayerSurfaceModel,
        settingsStore: SettingsStore,
        backgroundPaused: Binding<Bool>
    ) {
        // No decoder switch: the fallback only locks the window renderer and,
        // when background audio is disabled, pauses with the existing resume marker.
        surface.setRenderingLocked(true)
        if !settingsStore.backgroundPlayback, surface.isPlaying {
            backgroundPaused.wrappedValue = true
            KazumiLogBuffer.player("画中画: 静默暂停来源：后台兜底")
            surface.pause()
        }
    }

    /// 切到后台只转发 transition；PiP 有资格启动时绝不在这里同步锁渲染或暂停。
    /// 控制器会在 bounded start window 最终失败、且仍在后台时发唯一政策事件。
    private func handleBackground() {
        if pictureInPicture?.hasOngoingPictureInPicture == true {
            KazumiLogBuffer.player("画中画: 后台沿用当前小窗周期，不重新准备")
            pictureInPicture?.handleBackground(engine: surface.engine, surface: surface)
        } else if settings.backgroundAutoPiP {
            makePictureInPictureController(settingsStore: settings)
            pictureInPicture?.handleBackground(engine: surface.engine, surface: surface)
        } else if let pictureInPicture {
            pictureInPicture.handleBackground(engine: surface.engine, surface: surface)
        } else {
            // PiP 设置关闭，本来就没有启动窗口；直接沿用后台播放策略。
            applyBackgroundPlaybackPolicy(
                surface: surface,
                settingsStore: settings,
                backgroundPaused: $pausedByBackground
            )
        }
        if let controller { persistProgress(controller) }
    }

    /// 读一次代理交给播放内核（LP 5331）。
    ///
    /// libmpv 不认 iOS 的系统代理，所以只能由我们交给它。iOS 上 App 拿不到
    /// 代理软件（Surge 之类）在 HTTP 模式下监听的那个端口，所以这里只认
    /// 用户在设置里手填的地址和端口。
    private func refreshProxy() {
        let next = settings.playerProxyURL
        guard next != proxyURL else { return }
        proxyURL = next
        KazumiLogBuffer.player(MPVDiagnostics.sanitize(
            next == nil ? String(localized: "代理：不走代理，直连") : String(localized: "代理：走 \(String(describing: next!))")
        ))
    }

    /// 回前台只转发一次；后续 didStop 在控制器里走同一收口且不再回调。
    private func handleForeground() {
        if let pictureInPicture {
            pictureInPicture.handleForeground()
        } else {
            // 设置关闭时没有 PiP owner，保留原有回前台策略。
            surface.setRenderingLocked(false)
            let shouldResume = settings.resumeOnForeground && pausedByBackground
            if shouldResume {
                pausedByBackground = false
                if !surface.isPlaying { surface.play() }
            }
            logLifecycleSnapshot("handleForeground.completed")
        }
    }

    // MARK: - 播放区

    /// 全屏态在外层统一忽略四边容器安全区（防止自定义 `Layout` 无法向上穿透安全区导致顶部被残留内缩下推）；
    /// 非全屏一律保留系统安全区（含 Duo 右侧竖栏与底部 Home 指示区）。
    private var ignoresWindowEdges: Bool {
        isFullscreen
    }

    private var boxAspectRatio: CGFloat {
        if isFullscreen {
            let window = hostWindowSize(fallback: containerSize)
            if window.width > 0, window.height > 0 {
                return window.width / window.height
            }
            if containerSize.width > 0, containerSize.height > 0 {
                return containerSize.width / containerSize.height
            }
            return 16.0 / 9.0
        }
        if isWideSplitLayout {
            let totalWidth = max(1, containerSize.width)
            let totalHeight = max(1, containerSize.height)
            let leftWidth = max(1, totalWidth - Self.wideSidebarWidth(for: totalWidth))
            let idealHeight = (leftWidth / max(aspectRatioMode.frameAspectRatio, 0.1)).rounded()
            let maxPlayerHeight = max(180, totalHeight - Self.minWideInfoHeight)
            let playerHeight = max(1, min(idealHeight, maxPlayerHeight))
            return leftWidth / playerHeight
        }
        return aspectRatioMode.frameAspectRatio
    }

    /// SF Symbols 尺度与热区基准：常驻工具栏统一保持原版 18pt .medium，主播放键宽栏 20pt。
    private var isWideToolbar: Bool {
        isFullscreen || surfaceWidth >= 600
    }

    private var toolbarHitSize: CGFloat {
        isWideToolbar ? 44 : 40
    }

    private var l1SymbolSize: CGFloat {
        isWideToolbar ? 20 : 18
    }

    private var l2SymbolSize: CGFloat { 18 }

    private var l2ComplexSymbolSize: CGFloat { 18 }

    private var sameOrientationSafeSnapshot: EdgeInsets {
        containerSize.width > containerSize.height
            ? landscapeSafeInsetsSnapshot
            : portraitSafeInsetsSnapshot
    }

    /// 顶栏首行顶部内边距：
    /// - 非全屏：保持 `playerTopInset = 6`（安全区由外层自动避让）；
    /// - 全屏：扣除顶栏 `44pt` 热区内 `18pt` 图标/标题上方的 `13pt` 透明内衬与底栏 `33pt` 弹幕框下方的 `5.5pt` 内衬差值（约 `7pt`），
    ///   使顶栏可见元素距屏幕上缘的视觉留白与底栏可见元素距屏幕下缘严格一致。
    private var effectiveTopBarPadding: CGFloat {
        guard isFullscreen else { return Self.playerTopInset }
        return max(8, fullscreenBottomPadding - 7)
    }

    /// 控制层（顶栏、底栏、左右锁屏与截图键）左侧安全内边距：
    /// - 就地全屏（Duo / iPad）：系统状态栏与侧边竖栏均已隐藏，无需避让竖栏，仅留 `28pt` 避开屏幕圆角；
    /// - 手机横屏全屏：完整避开灵动岛安全区且距物理左缘不少于 `28pt`。
    private var controlLeadingPadding: CGFloat {
        guard isFullscreen else { return 16 }
        if usesInlineFullscreen { return 28 }
        let safeLeading = max(containerInsets.leading, sameOrientationSafeSnapshot.leading)
        return max(28, safeLeading + 16)
    }

    /// 控制层右侧安全内边距：
    /// - 就地全屏（Duo / iPad）：全屏态右侧系统竖栏已隐藏，不再沿用非全屏竖栏内缩，统一留 `28pt` 避开屏幕圆角；
    /// - 手机横屏全屏：避开右侧灵动岛安全区且距物理右缘不少于 `28pt`。
    private var controlTrailingPadding: CGFloat {
        guard isFullscreen else { return 16 }
        if usesInlineFullscreen { return 28 }
        let safeTrailing = max(containerInsets.trailing, sameOrientationSafeSnapshot.trailing)
        return max(28, safeTrailing + 16)
    }

    /// 全屏底栏距物理窗口下缘的安全内边距：避开底部 Home 指示条安全区且不少于 `16pt`。
    private var fullscreenBottomPadding: CGFloat {
        max(16, max(containerInsets.bottom, sameOrientationSafeSnapshot.bottom))
    }

    /// 当前控制栏可见时顶栏占用的总高度（供弹幕顶距避让计算）。
    private var activeTopBarOccupiedHeight: CGFloat {
        controlsShown ? (effectiveTopBarPadding + 44) : 0
    }

    /// 画面：16:9（或 4:3）画面本身，控制层压在它上面。
    /// 竖屏里这条就是页面最上面那一块；宽形态两栏时位于左栏顶部；全屏时铺满窗口。
    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        ZStack {
            interactiveSurface(controller)

            // 截图那一下的取景框（Colo 3667 的规格）：压在画面上、控制层之下。
            if screenshotFlash > 0 {
                ScreenshotFlashView(progress: screenshotFlash)
            }

            // 加载符号：一颗系统圈 + 下面一行网速（LP 4810）；播放/暂停气泡居中显示时暂隐免得重叠。
            if showsLoadingHUD,
               playPauseHUD == nil,
               surface.errorMessage == nil,
               controller.playbackURL != nil {
                loadingAtCenterLine {
                    PlayerLoadingHUD(
                        bytesPerSecond: surface.downloadSpeed,
                        info: playbackLoadingInfo,
                        reservesSpeedLine: false
                    )
                }
                .transition(.opacity)
            }

            if let error = surface.errorMessage {
                errorOverlay(error, controller: controller)
            }

            GeometryReader { proxy in
                let maskFades = Self.maskFadeLengths(
                    videoHeight: proxy.size.height,
                    topBarHeight: effectiveTopBarPadding + 44,
                    isFullscreen: isFullscreen,
                    usesWideTransport: proxy.size.width >= 600 || (isFullscreen && !usesInlineFullscreen)
                )
                let maskWidth: CGFloat? = isFullscreen
                    ? proxy.size.width + Self.maskTopOvershoot * 2
                    : nil
                controlLayer(controller, width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(alignment: .top) {
                        topMask(fadeHeight: maskFades.top)
                            .frame(width: maskWidth)
                            .offset(y: -Self.maskTopOvershoot)
                            .opacity(controlsShown ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: controlsShown)
                    }
                    .background(alignment: .bottom) {
                        bottomMask(fadeHeight: maskFades.bottom)
                            .frame(width: maskWidth)
                            .opacity(controlsShown ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: controlsShown)
                    }
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .ignoresSafeArea(.container, edges: videoIgnoredSafeAreaEdges)

            // 仅播放/暂停 HUD 置于画面正中央；其余手势/跳转/超分/倍速/状态提示保持在画面上 1/4 高度。
            if let gestureHUD {
                hudAtQuarter { gestureOverlay(gestureHUD) }
            } else if let seekHUD {
                hudAtQuarter { seekOverlay(seekHUD, target: seekDragTarget) }
            }
            if let superResolutionHUD {
                hudAtQuarter {
                    Text(superResolutionHUD)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .playerGlass(in: Capsule(style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
                }
                .transition(.opacity)
            }
            if let playPauseHUD, gestureHUD == nil, seekHUD == nil {
                hudAtCenter { playPauseBubble(playPauseHUD) }
                    .transition(.opacity)
            }

            // 片头片尾跳过胶囊（§7）：随控制栏显隐平滑避让底栏，收起时沉降回右下安全区。
            if skipPill.isVisible {
                SkipSegmentPillView(model: skipPill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, skipPillTrailingInset)
                    .padding(.bottom, skipPillBottomInset)
                    .animation(.easeOut(duration: 0.2), value: controlsShown)
            }

            if isTemporarySpeed {
                hudAtQuarter { temporarySpeedCapsule }
                    .transition(.opacity)
            }
            if let message = surface.hudToastMessage {
                hudAtQuarter {
                    hudToastBubble(message)
                        .task(id: "\(hudToastSerial)|\(message)") {
                            await hideToast(message, slot: .hud)
                        }
                }
                .transition(.opacity)
            }
        }
        // 锁定控制层与 HUD 动态字号上限（§5），防止超大无障碍字号撑破固定画幅工具栏。
        .dynamicTypeSize(...DynamicTypeSize.large)
        // 画面、控制栏、HUD 这一层强制深色（LP 2026-11-06）：玻璃按深色渲染，不跟系统浅色走。
        .environment(\.colorScheme, .dark)
        .modifier(PlayerBoxModifier(fillsWindow: isFullscreen,
                                    aspectRatio: boxAspectRatio))
        .ignoresSafeArea(.container, edges: videoIgnoredSafeAreaEdges)
        .background(Color.black)
        // MPVolumeView 得在视图树里，才拿得到它内部的音量滑杆。
        .background(
            SystemVolumeHost()
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
        .background {
            KazumiWindowRectReader { rect in
                playerAreaWindowFrame = rect
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            surfaceSize = size
            surfaceWidth = size.width
        }
    }

    private func interactiveSurface(_ controller: PlayerController) -> some View {
        GeometryReader { proxy in
            let videoBoxSize = proxy.size
            let gestureWidth = max(1, proxy.size.width)
            let gestureHeight = max(1, proxy.size.height)

            ZStack {
                Color.black
                videoSurface(controller, videoMinYInPlayerArea: 0)
                    .frame(width: videoBoxSize.width, height: videoBoxSize.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                handleSurfaceHover(phase)
            }
            .modifier(
                SurfaceTouchGesturesModifier(
                    isEnabled: controller.playbackURL != nil,
                    allowsDrag: settings.brightnessVolumeGesture && !isSurfaceLocked,
                    isSurfaceLocked: isSurfaceLocked,
                    width: gestureWidth,
                    onDoubleTap: { x in handleSurfaceDoubleTap(at: x, width: gestureWidth) },
                    onSingleTap: { handleSurfaceTap() },
                    dragGesture: surfaceDragGesture(width: gestureWidth, height: gestureHeight),
                    onLongPressTriggered: { lastLongPressAt = Date() },
                    onPressingChanged: { pressing in
                        surfacePressTask?.cancel()
                        surfacePressTask = nil
                        if pressing, !isSurfaceLocked {
                            surfacePressTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                lastLongPressAt = Date()
                                beginTemporarySpeed()
                            }
                        } else {
                            endTemporarySpeed()
                        }
                    }
                )
            )
        }
    }

    private func surfaceDragGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Self.directionLockThreshold, coordinateSpace: .global)
            .onChanged { value in
                let window = hostWindowSize(fallback: CGSize(width: width, height: height))
                if isTemporarySpeed {
                    dragAxis = .ignored
                    return
                }
                if dragAxis == nil {
                    guard value.startLocation.y > Self.gestureEdgeGuard,
                          value.startLocation.y < window.height - Self.gestureEdgeGuard else {
                        dragAxis = .ignored
                        return
                    }
                    if abs(value.translation.width) > abs(value.translation.height) {
                        // 全屏下贴系统左边缘起手预留给系统边缘手势；非全屏侧滑返回已避开播放器区域，画面内全宽可拖进度。
                        if isFullscreen, value.startLocation.x < 16, value.translation.width > 0 {
                            dragAxis = .ignored
                            return
                        }
                        dragAxis = .seek
                        seekDragStart = surface.currentTime
                        seekDragTarget = surface.currentTime
                    } else if isFullscreen, value.startLocation.y > window.height - Self.bottomSystemStrip {
                        dragAxis = .ignored
                        return
                    } else {
                        // 宽形态两栏时按左栏局部半宽划分亮度/音量，不拿右侧选集栏宽度掺算（§1）。
                        let splitMidX = isWideSplitLayout
                            ? (containerInsets.leading + width / 2)
                            : (window.width / 2)
                        if value.startLocation.x < splitMidX {
                            dragAxis = .brightness
                            dragValueStart = Double(Self.hostScreen?.brightness ?? 0)
                        } else {
                            dragAxis = .volume
                            dragValueStart = currentEffectiveVolume
                        }
                    }
                }
                if dragAxis != nil, dragAxis != .ignored {
                    surfacePressTask?.cancel()
                    surfacePressTask = nil
                    if abs(value.translation.height) > 24 || abs(value.translation.width) > 24 {
                        endTemporarySpeed()
                    }
                }
                switch dragAxis {
                case .seek:
                    guard let start = seekDragStart else { return }
                    let seconds = Double(value.translation.width) / Double(max(1, width)) * 180
                    let limit = max(0, surface.duration - 0.5)
                    let target = min(max(0, start + seconds), limit)
                    seekDragTarget = target
                    seekHUD = Int((target - start).rounded())
                case .brightness, .volume:
                    guard let start = dragValueStart else { return }
                    let windowHeight = Double(max(1, window.height))
                    let level = dragAxis == .brightness ? windowHeight * 2 : windowHeight * 3
                    let delta = Double(-value.translation.height) / level
                    let target = min(1, max(0, start + delta))
                    if dragAxis == .brightness {
                        Self.hostScreen?.brightness = CGFloat(target)
                        gestureHUD = GestureHUDValue(kind: .brightness, value: target)
                    } else {
                        adjustPlayerVolume(to: target)
                    }
                case .ignored, .none:
                    break
                }
            }
            .onEnded { _ in
                let wasSeeking = dragAxis == .seek
                if wasSeeking, let target = seekDragTarget {
                    surface.seek(to: target)
                }
                dragAxis = nil
                dragValueStart = nil
                seekDragStart = nil
                seekDragTarget = nil
                scheduleHUDHide(after: wasSeeking ? 1.2 : 0.6)
            }
    }

    private var controllerPhase: PlayerController.Phase {
        controller?.phase ?? .idle
    }

    private var isPlaybackFailed: Bool {
        if case .failed = controller?.phase { return true }
        if surface.errorMessage != nil { return true }
        return false
    }

    private var controlsShown: Bool {
        guard !isSurfaceLocked else { return false }
        return controlsVisible || pinsControls
    }

    private var pinsControls: Bool {
        switch controllerPhase {
        case .failed:
            return true
        case .idle, .searchingSource, .resolvingChapters, .parsingMedia:
            return true
        case .ready:
            return false
        }
    }

    /// 控制层：顶一行、底一行，都浮在画面上；非全屏由外层安全区逐边避让（含右侧竖栏与底部安全区），
    /// 全屏忽略对应边并由 `effectiveTopBarPadding` 与底栏 `12pt` 统一控制边距（§2–§4）。
    private func controlLayer(_ controller: PlayerController, width: CGFloat) -> some View {
        ZStack {
            if !isSurfaceLocked {
                VStack(spacing: 0) {
                    topBar(controller)
                    Spacer(minLength: 0)
                    transportBar(controller, width: width)
                }
                .allowsHitTesting(controlsShown)
            }

            if controlsShown {
                lockButton
                    .padding(.leading, controlLeadingPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .transition(.opacity)
                screenshotButton
                    .padding(.trailing, controlTrailingPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }

            if !controlsShown {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSurfaceLocked { showUnlockAffordance() } else { showControls() }
                    }
            }

            if isSurfaceLocked, unlockAffordanceShown {
                lockButton
                    .padding(.leading, controlLeadingPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .opacity(controlsShown || (isSurfaceLocked && unlockAffordanceShown) ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: controlsShown)
    }

    /// 非全屏顶栏离安全区上沿的距离（§4 D3：保持 6）。
    private static let playerTopInset: CGFloat = 6
    /// 非全屏紧凑底栏底沿额外留白（§2 B1/B2：由 6 改为 0，严格贴底）。
    private static let portraitTransportBottomInset: CGFloat = 0
    /// 紧凑底栏行高。
    private static let portraitTransportHeight: CGFloat = 52
    /// 宽栏底栏两层内容净高（36 进度时间行 + 44 按钮行 = 80，较旧三层节省 ≥ 28pt，§6 F2）。
    private static let landscapeTransportContentHeight: CGFloat = 80
    /// 竖屏底栏最高内容到底边的距离，底渐变按它收边。
    private static let portraitBottomShadowContent: CGFloat = 36
    /// 宽栏两层底栏最高内容到底边的距离。
    private static let landscapeBottomShadowContent: CGFloat = 76

    /// 顶条只往上多画这么多点：画在屏幕外，专门吃「跟窗口顶之间那几个点」的缝。
    private static let maskTopOvershoot: CGFloat = 16

    /// 屏幕最底下留给系统手势的那一条（home 指示条）。
    private static let bottomSystemStrip: CGFloat = 24

    /// 竖向拖动起手的安全区：窗口最上 / 最下这么宽的一段不认。
    private static let gestureEdgeGuard: CGFloat = 40

    /// 方向锁定的死区：手指先走这么多点，才决定这一路是调进度还是调亮度/音量。
    private static let directionLockThreshold: CGFloat = 10

    private static func maskFadeLengths(
        videoHeight: CGFloat,
        topBarHeight: CGFloat,
        isFullscreen: Bool,
        usesWideTransport: Bool
    ) -> (top: CGFloat, bottom: CGFloat) {
        guard videoHeight > 0 else { return (0, 0) }
        let bottomBar: CGFloat = (usesWideTransport ? Self.landscapeTransportContentHeight : Self.portraitTransportHeight)
            + (isFullscreen ? 12 : 0)
        if !isFullscreen && !usesWideTransport {
            let fade = max(
                0,
                min(72, min(max(64, videoHeight * 0.33), videoHeight * 0.45))
                    - Self.playerTopInset
            )
            return (fade, min(fade, Self.portraitBottomShadowContent + 6))
        }
        var top = max(0, min(96, videoHeight * 0.25) - Self.playerTopInset)
        var bottom = min(
            min(180, videoHeight * 0.42),
            Self.landscapeBottomShadowContent + (isFullscreen ? 18 : 6)
        )
        let available = videoHeight - topBarHeight - bottomBar
        if available > 0, top + bottom > available {
            let scale = available / (top + bottom)
            top *= scale
            bottom *= scale
        }
        return (top, bottom)
    }

    private func topMask(fadeHeight: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.8), location: 0),
                .init(color: .black.opacity(0.4), location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: fadeHeight)
        .allowsHitTesting(false)
    }

    private func bottomMask(fadeHeight: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.4), location: 0.5),
                .init(color: .black.opacity(0.8), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: fadeHeight)
        .allowsHitTesting(false)
    }

    /// 左边缘那颗：锁画面（L2 常驻工具栏层级）。
    private var lockButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            toggleSurfaceLock()
        } content: {
            Image(systemName: isSurfaceLocked ? "lock" : "lock.open")
                .playerIcon(pointSize: l2SymbolSize, weight: .medium)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(isSurfaceLocked ? String(localized: "解锁画面") : String(localized: "锁定画面"))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 右边缘那颗：抓当前这一帧存进相册（L2 常驻工具栏层级）。
    private var screenshotButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            takeScreenshot()
        } content: {
            Image(systemName: "camera")
                .playerIcon(pointSize: l2SymbolSize, weight: .medium)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(String(localized: "截图"))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 锁上 / 解开。锁上顺手把控制层收掉：那一档屏幕上不该再有任何可点的东西。
    private func toggleSurfaceLock() {
        if isSurfaceLocked {
            isSurfaceLocked = false
            unlockAffordanceTask?.cancel()
            unlockAffordanceTask = nil
            unlockAffordanceShown = false
            // 解开就露一下控制层，让人看清刚才锁的是哪里。
            showControlsBriefly()
        } else {
            isSurfaceLocked = true
            unlockAffordanceTask?.cancel()
            unlockAffordanceTask = nil
            unlockAffordanceShown = false
            hideGeneration &+= 1
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// 锁着时点一下：只把解锁那一颗浮出来，3 秒后自己收回。
    private func showUnlockAffordance() {
        if unlockAffordanceShown { return }
        withAnimation(.easeOut(duration: 0.2)) { unlockAffordanceShown = true }
        unlockAffordanceTask?.cancel()
        unlockAffordanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { unlockAffordanceShown = false }
        }
    }

    /// 固定三条：番名、当前集、按下快门时的播放进度。番名本身已有季度时不重复拆季。
    private var screenshotKeywords: [String] {
        let rawTitle = danmakuInitialKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "Bangumi \(bangumiID)" : rawTitle
        let episodeNumber = controller?.currentEpisode ?? episode
        return [title, "第\(episodeNumber)集", timeText(surface.currentTime)]
    }

    /// 截图：抓帧 → 存相册 → 闪一下取景框，存好/没存好都要说一句（LP 4709）。
    ///
    /// 抓帧走 mpv 的 `screenshot-to-file`（原始分辨率、不含字幕和 OSD，LP 4695），
    /// 出的是临时文件；这里再把文件交给相册那条路，存完删掉。
    ///
    /// 取景框**按下去就播**，不等抓帧：mpv 要回最近的关键帧重新解码，网络流上
    /// 这一下是秒级的（回执到了才算成），不先给个反应的话，从按下到有结果之间
    /// 屏幕几十秒没动静，就是 LP 说的「没任何提示」。失败了照样出错误提示。
    private func takeScreenshot() {
        noteInteraction()
        showControlsBriefly()
        flashScreenshot()
        let keywords = settings.screenshotKeywordsEnabled ? screenshotKeywords : []
        environment.router.externalNavigationDeferralCount += 1
        Task { @MainActor in
            defer { environment.router.externalNavigationDeferralCount -= 1 }
            let captured = await surface.captureFrame()
            guard let url = captured.url else {
                // 抓帧自己会给一句能直接给用户看的话（哪种方式、多少毫秒、什么尺寸），
                // 拿不到就拿它当 toast，别再只说「没抓到画面」。
                surface.toastMessage = captured.note.isEmpty ? "截图失败：没抓到画面" : captured.note
                return
            }
            let failure = await PlayerScreenshot.save(pngAt: url, keywords: keywords)
            // 临时文件不再需要；存成功也是它自己那份了。
            try? FileManager.default.removeItem(at: url)
            if let failure {
                surface.toastMessage = failure
            } else {
                // 存成功也要说话（LP 4709）：取景框闪一下只是快门，没人知道到底存没存进去。
                // 跟倍速/收藏/定时关闭同一条线（LP 4668）——这是动作结果，不是说明。
                surface.hudToastMessage = String(localized: "已保存到相册")
            }
        }
    }

    /// 取景框从外往里收、同时淡入淡出，0 → 1 走 0.55 秒（Colo 3667 的数）。
    private func flashScreenshot() {
        screenshotFlashTask?.cancel()
        withAnimation(.linear(duration: 0.55)) { screenshotFlash = 1 }
        screenshotFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            screenshotFlash = 0
        }
    }

    /// 顶栏跳过片头按钮图标：外圈 17pt .medium 圆弧箭头，内部整数秒数统一 8pt .regular。
    private func skipButton(seconds: Int, isForward: Bool) -> some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            ZStack {
                Image(systemName: isForward ? "goforward" : "gobackward")
                    .playerIcon(pointSize: 17, weight: .medium, optical: .detailed)
                    .foregroundStyle(.white)
                Text("\(seconds)")
                    .font(.system(size: 8, weight: .regular).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
                    .offset(y: 1.0)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 顶部快进按钮：单击快进，长按 1 秒修改秒数（对应原版 player_item_panel 的快进按钮）。
    private var skipForwardButton: some View {
        skipButton(seconds: settings.buttonSkipTime, isForward: true)
            .gesture(
                LongPressGesture(minimumDuration: 1.0)
                    .onEnded { _ in presentSkipSecondsDialog() }
                    .exclusively(
                        before: TapGesture().onEnded {
                            surface.skipForward(seconds: Double(settings.buttonSkipTime))
                        }
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "快进"))
            .accessibilityHint(String(localized: "快进\(String(describing: settings.buttonSkipTime))秒，长按修改时间"))
            .accessibilityAddTraits(.isButton)
    }

    /// 画面按压：短按切控制栏 / 播放暂停，长按临时倍速（对应原版
    /// `player_item.dart` 的 onLongPressStart / onLongPressEnd）。
    ///
    /// 用 `onLongPressGesture` 的 pressing 回调而不是两个手势叠加：
    /// 同一次按压只会走一条分支，长按松手不会再触发一次短按。
    /// 全屏开关：进横屏 + 隐藏状态栏；退出回竖屏（原版 `DisplayModeService` 也是
    /// 退出时显式回 portraitUp，而不是「系统默认」）。
    ///
    /// 方向请求走 `requestGeometryUpdate`，只影响本次会话，不改 Info.plist 里
    /// 声明的支持方向（竖屏/横屏本来都支持）。
    /// 全屏只有一种：横屏铺满（LP 2026-10-25，不做竖屏全屏）。
    /// 所以进入时先要横屏，退出时回竖屏；转回竖屏的那一下由布局兜底退出全屏，
    /// 免得留下一个「竖着也算全屏」的状态。
    private func toggleFullscreen() {
        if isFullscreen {
            exitFullscreen()
        } else {
            isFullscreen = true
            // 常规宽度不转屏：只收起选集区、藏状态栏（Colo 7725 §4.2 A）。
            if !usesInlineFullscreen { enterLandscape() }
        }
        showControls()
        noteInteraction()
    }

    /// 要横屏，并且**确认它真的转过去了**。
    ///
    /// 以前是「请求一次，睡 0.8 秒，还没横就退全屏」。第二次进全屏时系统那边
    /// 刚被上一轮锁回竖屏，转场本来就慢一点，0.8 秒常常不够——于是请求发出去了、
    /// 界面也进了全屏，却在转场半路被自己退回来，看起来就是「切回竖屏后再也切不了全屏」
    /// （LP 2026-10-28 第 2 条）。
    /// 现在改成：发请求，然后每 100 毫秒看一眼，最多等 3 秒；中途还没转就再请求一次
    /// （有些机型第二次请求才认）；3 秒还没转，才算系统真的拒绝，退回竖屏。
    private func enterLandscape() {
        // 只发一次请求，重试和收尾都在 requestOrientation 那一条链里
        // （原来这里自己又数 30 次、第 10 次再发一遍，是最早那批并发来源之一）。
        requestOrientation(.landscapeRight)
    }

    /// 窗口现在是不是横的：直接问 UIKit，不依赖 SwiftUI 的尺寸回调有没有送到。
    private var isWindowLandscape: Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { return false }
        // `UIWindowScene.interfaceOrientation` 在 iOS 26 弃用，改看有效几何里的那一个。
        return scene.effectiveGeometry.interfaceOrientation.isLandscape
    }

    /// 本场景的窗口。手势坐标是 `.global`（窗口坐标），安全区和尺寸都按它算：
    /// iOS 26 起 `UIScreen.main` 弃用，而分屏 / 镜像 / 外接屏里窗口比主屏小。
    private var hostWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return nil }
        return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
    }

    /// 窗口尺寸。窗口还没就绪（拖动时不会发生，窗口不在就收不到手势）时退回画面自己的尺寸。
    private func hostWindowSize(fallback: CGSize) -> CGSize {
        guard let bounds = hostWindow?.bounds, bounds.width > 0, bounds.height > 0 else { return fallback }
        return bounds.size
    }

    /// 本场景所在的那块屏。`UIScreen.brightness` 只有主屏支持，而 iOS 26 起不能再写
    /// `UIScreen.main`，只能从场景里取（iPhone 上场景的屏就是主屏）。
    private static var hostScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.screen
    }

    private func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        sawLandscape = false
        if !usesInlineFullscreen { requestOrientation(.portrait, releaseAfterSuccess: true) }
        showControls()
    }

    /// 离开播放页时恢复 App 默认方向，让其它页面继续支持横屏浏览。
    private func releaseOrientation() {
        orientationRequestTask?.cancel()
        orientationGeneration += 1
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        OrientationLock.release(scene: scene)
        if let scene { notifyOrientationChange(in: scene) }
    }

    private func requestOrientation(
        _ mask: UIInterfaceOrientationMask,
        releaseAfterSuccess: Bool = false
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        // 让 `supportedInterfaceOrientations` 跟着变，否则请求会被忽略。
        OrientationLock.mask = mask
        notifyOrientationChange(in: scene)
        // **整条转屏只留一条链**：新请求先把旧链取消，旧链里的每一步都先核对自己的
        // 代号还是不是最新的。以前是「requestOrientation 内部发两次 + 半秒兜底再发一次
        // + enterLandscape 自己数着再发一次 + 布局看到竖屏又退全屏发一次」，
        // 四条一起转、互相打断，表现出来就是「横屏切回竖屏后再也横不了」
        // （LP 2026-10-28；@developer3 4308 定位到的并发来源）。
        orientationRequestTask?.cancel()
        orientationGeneration += 1
        let generation = orientationGeneration
        let wantsLandscape = !mask.intersection(.landscape).isEmpty
        orientationRequestTask = Task { @MainActor in
            for attempt in 0..<12 {          // 12 × 250ms = 3 秒
                await Task.yield()
                guard !Task.isCancelled, generation == orientationGeneration else { return }
                // 只在最初和大约 1 秒时各发一次：每 250 毫秒都重发会让转场发抖
                // （@developer3 4320）。其余时间只轮询系统转没转过去。
                if attempt == 0 || attempt == 4 {
                    notifyOrientationChange(in: scene)
                    // 系统的原话要落到「播放信息」里，不然只有「等满 3 秒」这一句
                    // （Colo 2026-10-28 §14.10 第 5 条 / @developer3 4311）。
                    // 这个回调**必须**是 nonisolated：UIKit 在自己的队列上调它，
                    // 闭包只要继承主线程隔离，一进去就撞断言闪退（LP 4753）。
                    let failure = orientationFailure
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
                        let message = String(localized: "系统拒绝：\(String(describing: error.localizedDescription))")
                        failure.record(generation: generation, message: message)
                    }
                }
                // 回调什么时候到不由我们定，每轮都取一次；取到就记进「播放信息」。
                if let failure = orientationFailure.take(generation: generation) {
                    lastOrientationResult = failure
                }
                // 已经到了就收工，别再多发。
                if scene.effectiveGeometry.interfaceOrientation.isLandscape == wantsLandscape {
                    if attempt > 0 {
                    }
                    lastOrientationResult = String(localized: "已转过去")
                    if releaseAfterSuccess {
                        OrientationLock.release(scene: scene)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, generation == orientationGeneration else { return }
            // 等满了才算系统真的不给转：这时候把界面退回竖屏内联，
            // 别留着「界面按全屏排、窗口还是竖的」这种两边不一致的状态
            // （Colo 2026-10-28 §14.10 / @developer3 4311 第三条）。
            // 退的是**界面状态**；用户再点全屏会重新发一条请求、重设方向锁，
            // 所以不会像以前那样「退过一次就再也转不动」。
            if !lastOrientationResult.hasPrefix(String(localized: "系统拒绝")) {
                lastOrientationResult = String(localized: "请求了但系统没转（等满 3 秒）")
            }
            if isFullscreen {
                isFullscreen = false
                sawLandscape = false
            }
            OrientationLock.mask = OrientationLock.appDefault
        }
    }

    /// 把场景里每个窗口的整条控制器链都标记为需要重算支持方向。
    private func notifyOrientationChange(in scene: UIWindowScene) {
        for window in scene.windows {
            Self.markOrientationDirty(window.rootViewController)
        }
    }

    private static func markOrientationDirty(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children {
            markOrientationDirty(child)
        }
        markOrientationDirty(controller.presentedViewController)
    }

    /// 双击：左 30% 快退、中 40% 播放 / 暂停、右 30% 快进（LP 2026-11-06 改回分区；
    /// 秒数走设置里「快进快退时长」）。即时反馈复用 1/4 线上那条浮层，不另画。
    private func handleSurfaceDoubleTap(at x: CGFloat, width: CGFloat) {
        // 锁着时双击也不生效：这把锁就是防误触的（LP 2026-10-28 第 4 条）。
        guard !isSurfaceLocked else { return }
        let seconds = settings.doubleTapSkipTime
        let ratio = width > 0 ? x / width : 0.5
        if ratio < 0.3 {
            surface.seek(to: max(0, surface.currentTime - Double(seconds)))
            flashSeekHUD(-seconds)
        } else if ratio > 0.7 {
            surface.skipForward(seconds: Double(seconds))
            flashSeekHUD(seconds)
        } else {
            surface.togglePlay()
            flashPlayPauseHUD()
        }
        showControlsBriefly()
    }

    /// 播放中快进/双击唤出时浮现 1.2 秒再淡出；暂停状态直接走全局「控制栏消失时间」倒数后隐藏。
    private func showControlsBriefly() {
        guard surface.isPlaying else {
            showControls()
            return
        }
        showControls()
        // 先作废按设置计时的那一条，免得两套计时同时跑。
        hideGeneration &+= 1
        let generation = hideGeneration
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, surface.isPlaying else { return }
            guard generation == hideGeneration, canHideControls else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// 点画面只切控制层显示（原版：短按显隐，不暂停）；播放/暂停在播放键上。
    private func handleSurfaceTap() {
        // 锁着时点画面只唤出解锁那颗：不显控制层、不切换播放（LP 2026-10-28 第 4 条）。
        if isSurfaceLocked {
            showUnlockAffordance()
            return
        }
        // 长按刚松手时系统会补一次短按，挡掉，别把控制层又切一遍。
        if let longPressAt = lastLongPressAt, Date().timeIntervalSince(longPressAt) < 0.4 {
            lastLongPressAt = nil
            return
        }
        // 弹幕输入框还开着时，点空白先收键盘，不动控制栏（Colo 2026-10-27）。
        if danmakuFieldFocused {
            danmakuFieldFocused = false
            return
        }
        if controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        } else {
            showControls()
        }
    }

    /// 长按临时加速：原版按住期间用 `defaultShortcutForwardPlaySpeed`（默认 2.0），
    /// 松手恢复按下前的速度，不写回设置。
    /// 切超分档位：只改本次应用会话（着色器由容器按新路径重新挂上，当场生效），
    /// 再在 1/4 那条线上提示一句「超分辨率 · 质量」（Colo 2026-10-28）。
    private func applySuperResolution(_ mode: SuperResolutionMode) {
        settings.playbackSuperResolutionMode = mode
        noteInteraction()
        let text = mode == .off ? String(localized: "超分辨率 · 关闭") : String(localized: "超分辨率 · \(String(describing: mode.title))")
        withAnimation(.easeOut(duration: 0.15)) { superResolutionHUD = text }
        superResolutionHUDTask?.cancel()
        superResolutionHUDTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { superResolutionHUD = nil }
        }
    }

    private func beginTemporarySpeed() {
        // 已经在临时倍速里就什么都不做：起点只记一次，
        // 重复调用会把 2x 记成起点，松手就回不到原来的速度。
        guard !isTemporarySpeed else { return }
        isTemporarySpeed = true
        rateBeforeTemporarySpeed = playbackRate
        PlayerHaptics.bump()
        surface.setPlaybackRate(Float(settings.longPressSpeed))
    }

    private func endTemporarySpeed() {
        guard isTemporarySpeed else { return }
        isTemporarySpeed = false
        surface.setPlaybackRate(rateBeforeTemporarySpeed)
    }

    // MARK: - 控制栏自动隐藏

    private var canHideControls: Bool {
        controlsVisible && controllerPhase == .ready && !isScrubbing && !isEditingSkipSeconds
            && !danmakuFieldFocused && activeSheet == nil && !menuOpen
    }

    /// 从菜单里开页面：菜单自己还要收一下，同一拍里改 presentation 会被吞掉，
    /// 所以等一拍再开（「更多里的选项点了没反应」里的一半）。
    /// 收起键盘：弹幕设置里有输入框，右上角那颗关闭要先把键盘收掉再关弹窗，
    /// 不然键盘会留在屏上下次进来还弹着（Colo 2026-10-27）。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func openSheet(_ sheet: PlayerSheet) {
        showControls()
        if sheet == .danmakuSettings {
            if surface.isPlaying {
                resumesAfterDanmakuSettings = true
                surface.pause()
            } else {
                resumesAfterDanmakuSettings = false
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            activeSheet = sheet
        }
    }

    /// 音频会话：播放器一打开就是 .playback。
    ///
    /// 系统只把「播放类别」的 app 当成正在播放的播放器；不是这个类别，
    /// 控制中心、锁屏、灵动岛都不会有那张卡片（LP 4491 就是这里）。
    /// 静音键管的是铃声和提示音，不该管视频音量——Apple Music 也一样。
    /// 「切后台继续出声」是另一件事，由 scenePhase 那边决定要不要暂停。
    /// 来电中断和拔耳机也挂在同一处，见 `PlayerAudioSession`。
    private func applyAudioSessionPolicy() {
        PlayerAudioSession.shared.surface = surface
        PlayerAudioSession.shared.activate()
    }

    /// 离开播放器：退回默认类别，别让整个 App 一直占着播放位。
    private func restoreAudioSessionAfterPlayer() {
        PlayerAudioSession.shared.surface = nil
        PlayerAudioSession.shared.restore()
    }

    private func sceneMatchesPlayer(_ scene: UIScene?) -> Bool {
        guard let scene else { return false }
        if let playerScene = surface.engine?.playerScene {
            return scene === playerScene
        }
        return true
    }

    private var isForegroundActive: Bool {
        if let scene = surface.engine?.playerScene {
            return scene.activationState == .foregroundActive
        }
        return sceneIsActive && UIApplication.shared.applicationState != .background
    }

    /// 屏幕常亮：只在「真的在播」且 App 在前台时开；暂停、缓冲、播完、退后台、离开播放器全部恢复默认，
    /// 免得暂停一晚上屏幕还亮着。锁手势不影响——那时内核照样在播，就照样常亮。
    private func updateIdleTimer() {
        let active = isForegroundActive
        let keepAwake = surface.isPlaying && active
        if UIApplication.shared.isIdleTimerDisabled != keepAwake {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            KazumiLogBuffer.player("屏幕常亮: keepAwake=\(keepAwake) (isPlaying=\(surface.isPlaying), active=\(active))")
        }
    }

    /// 按「控制栏消失时间」设置重新计时；不能隐藏时 `.task(id:)` 会直接返回。
    private func scheduleControlsHide() {
        hideGeneration &+= 1
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = true
            }
        }
        scheduleControlsHide()
    }

    /// 任何一次控件交互都算「有操作」，重新计时。
    private func noteInteraction() {
        showControls()
    }

    /// 弹幕观感打包：设置页那几项 + 播放器自己的弹幕开关与当前倍速。
    /// 改成结构体是因为弹幕层要的项越来越多，一项一个参数会把调用点撑散。
    private var danmakuStyle: DanmakuOverlayView.Style {
        var style = DanmakuOverlayView.Style()
        style.enabled = danmakuEnabled
        style.opacity = settings.danmakuOpacity
        style.fontSize = settings.danmakuFontSize
        style.area = settings.danmakuArea
        style.duration = settings.danmakuDuration
        style.lineHeight = settings.danmakuLineHeight
        style.followSpeed = settings.danmakuFollowSpeed
        style.showTop = settings.danmakuTop
        style.showBottom = settings.danmakuBottom
        style.showScroll = settings.danmakuScroll
        style.massive = settings.danmakuMassive
        style.deduplication = settings.danmakuDeduplication
        style.showBiliBili = settings.danmakuBiliBiliSource
        style.showGamer = settings.danmakuGamerSource
        style.showDanDan = settings.danmakuDanDanSource
        style.border = settings.danmakuBorder
        style.borderSize = settings.danmakuBorderSize
        style.useColor = settings.danmakuColor
        style.fontWeight = settings.danmakuFontWeight
        style.filterRules = settings.danmakuFilterRules
        return style
    }

    /// 计算当前 `MPVHostView` 局部坐标系内的顶栏下缘位置（§7 G1）：
    /// - 控制栏显示时，传入 `max(0, activeTopBarOccupiedHeight - videoMinYInPlayerArea)`，
    ///   若 Duo 宽形态两栏中顶栏位于 `319` 画面上方黑底区（`activeTopBarOccupiedHeight <= videoMinY`），结果自然为 `0`；
    /// - 控制栏隐藏时，非全屏为 `0`，全屏仅让出实时硬件顶部安全区（无 `44pt` 常驻死区）。
    private func effectiveDanmakuTopInset(videoMinYInPlayerArea: CGFloat) -> CGFloat {
        if controlsShown {
            return max(0, activeTopBarOccupiedHeight - videoMinYInPlayerArea)
        }
        return isFullscreen ? max(0, containerInsets.top - videoMinYInPlayerArea) : 0
    }

    /// 黑底 + 视频画面（或解析中的状态）。
    @ViewBuilder
    private func videoSurface(
        _ controller: PlayerController,
        videoMinYInPlayerArea: CGFloat = 0
    ) -> some View {
        ZStack {
            Color.black

            if let text = controller.playbackURL, let url = URL(string: text) {
                MPVPlayerContainer(
                    url: url,
                    referer: controller.referer,
                    userAgent: controller.userAgent,
                    cookie: controller.playbackCookieHeader(for: text),
                    proxyURL: proxyURL,
                    shaderPaths: settings.playbackSuperResolutionMode.shaderPaths,
                    fillMode: aspectRatioMode.fillMode,
                    videoAspectOverride: aspectRatioMode.videoAspectOverride,
                    danmaku: controller.danmakuComments,
                    danmakuStyle: danmakuStyle,
                    danmakuPlaybackRate: isTemporarySpeed ? settings.longPressSpeed : Double(playbackRate),
                    danmakuTopInset: effectiveDanmakuTopInset(videoMinYInPlayerArea: videoMinYInPlayerArea),
                    hidesPointer: pointerCursorHidden && !controlsShown,
                    lowMemoryMode: settings.lowMemoryMode,
                    hardwareDecodeEnabled: settings.hardwareDecodeEnabled,
                    hardwareDecodeMode: settings.hardwareDecodeMode,
                    backgroundAutoPiP: settings.backgroundAutoPiP,
                    surface: surface
                )
            } else {
                statusOverlay(controller)
            }
        }
    }

    /// 顶栏：
    /// - 非全屏：返回、弹幕开关、片头跳过、定时关闭、更多；
    /// - 全屏：返回 ＋ 番剧标题·集数，右侧片头跳过、追番状态、定时关闭、更多。
    private func topBar(_ controller: PlayerController) -> some View {
        HStack(spacing: 6) {
            PlayerIconButton(hitSize: 44) {
                logLifecycleSnapshot("returnButton.tapped")
                if isPlaybackFailed {
                    SourceSheetCoordinator.shared.markFailedReturnToSources(bangumiID: bangumiID)
                }
                dismiss()
            } content: {
                Image(systemName: "chevron.left")
                    .playerIcon(pointSize: l2SymbolSize, weight: .semibold)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(String(localized: "返回"))

            if isFullscreen {
                let meta = nowPlayingMeta(controller)
                let episodeNumber = max(1, controller.currentEpisode)
                Text("\(meta.title) · \(String(format: "%02d", episodeNumber))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            if !isFullscreen {
                danmakuButton
            }

            HStack(spacing: 4) {
                if SyncplayManager.shared.isConnected {
                    Button {
                        openSheet(.syncPlay)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 11, weight: .semibold))
                            if SyncplayManager.shared.rttMs > 0 {
                                Text("\(SyncplayManager.shared.rttMs)ms")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "一起看状态"))
                }
                skipForwardButton
                if isFullscreen {
                    collectButton
                }
                sleepTimerButton
                moreMenu
            }
            .fixedSize()
        }
        .padding(.leading, controlLeadingPadding)
        .padding(.trailing, controlTrailingPadding)
        .padding(.top, effectiveTopBarPadding)
    }

    /// 顶栏的定时关闭（横竖屏都在顶栏直达，正在倒数的档位实时显示 mm:ss）。
    /// `timer` 符号采用 `17.4pt`（`scale: .medium`），取此前偏大与偏小两档的视觉中间值。
    private var sleepTimerButton: some View {
        let isRunning = sleepTimerRemaining != nil
        return PlayerIconButton(hitSize: toolbarHitSize) {
            SystemMenuButton(
                selection: .init(options: [SystemMenuButton.Selection.Option(
                    title: String(localized: "不开启"),
                    isSelected: sleepTimerMinutes == nil
                ) {
                    cancelSleepTimer()
                }] + [15, 30, 60, 90].map { minutes in
                    SystemMenuButton.Selection.Option(
                        title: sleepTimerItemTitle(minutes),
                        isSelected: sleepTimerMinutes == minutes
                    ) {
                        startSleepTimer(minutes: minutes)
                    }
                }),
                title: nil,
                symbol: isRunning ? "moon.zzz.fill" : "timer",
                accessibilityLabel: String(localized: "定时关闭"),
                tint: .white,
                symbolSize: isRunning ? l2SymbolSize : 17.4,
                symbolWeight: .medium,
                symbolOptical: isRunning ? .solid : .standard,
                hitSize: toolbarHitSize,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    /// 收藏钮（L2 常驻工具栏层级）。
    private var collectButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            SystemMenuButton(
                items: collectMenuItems,
                title: nil,
                symbol: collectSymbolName,
                accessibilityLabel: String(localized: "追番状态"),
                tint: .white,
                symbolSize: l2SymbolSize,
                symbolWeight: .medium,
                symbolOptical: collectSymbolOptical,
                hitSize: toolbarHitSize,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    private var collectMenuItems: [SystemMenuButton.Item] {
        var items = CollectType.enabledCases.map { type in
            SystemMenuButton.Item(
                title: type.buttonTitle,
                symbol: type.statusSymbol,
                isChecked: currentCollectType == type
            ) {
                applyCollectType(type)
            }
        }
        if currentCollectType != .none {
            items.append(
                SystemMenuButton.Item(
                    title: String(localized: "取消追番"),
                    symbol: "trash",
                    isDestructive: true
                ) {
                    applyCollectType(.none)
                }
            )
        }
        return items
    }

    /// 顶栏那颗的符号＝当前状态（Colo 3984）。
    private var collectSymbolName: String {
        switch currentCollectType {
        case .none: "plus"
        case .watching: "heart.fill"
        case .wish: "star.fill"
        case .onHold: "hourglass"
        case .watched: "checkmark"
        case .dropped: "heart.slash.fill"
        }
    }

    /// 实心状态符号视觉偏大，按光学补偿缩一档。
    private var collectSymbolOptical: PlayerIconOptical {
        switch currentCollectType {
        case .watching, .wish, .dropped: .solid
        default: .standard
        }
    }

    /// 这部番现在的收藏状态（收藏库里没有就是未收藏）。
    private var currentCollectType: CollectType {
        CollectType(rawValue: environment.library.entry(for: bangumiID)?.type ?? 0) ?? .none
    }

    /// 改收藏状态：先写回 Bangumi，成功了才动本地收藏库；
    /// 没登录时写不进去，就在画面上说一句，不假装改过。
    private func applyCollectType(_ type: CollectType) {
        guard type != currentCollectType else { return }
        noteInteraction()
        // 口径照 collect_controller.dart 的 _syncBangumiCollectIfEnabled：
        // 只有「自动同步追番」开着才推给 Bangumi；没开就是纯本地改动。
        // 推失败时这次修改整体作废 —— 本地显示「已看过」而 Bangumi 上还是「在看」，
        // 比没改更让人糊涂（原版同样是回滚 + 一句失败提示）。
        let syncEnabled = settings.bangumiSyncEnable
        let showToast = settings.bangumiImmediateSyncToastEnable
        Task {
            if syncEnabled {
                if showToast { surface.toastMessage = String(localized: "正在同步到 Bangumi...") }
                let pushed = await environment.bangumiSync.pushCollectible(
                    bangumiID: bangumiID,
                    type: type
                )
                guard pushed else {
                    let reason = environment.bangumiSync.lastError ?? String(localized: "网络或服务异常")
                    surface.toastMessage = String(localized: "同步到 Bangumi 失败（\(reason)），已取消本次状态修改")
                    return
                }
            }
            if var entry = environment.library.entry(for: bangumiID) {
                entry.type = type.rawValue
                entry.updatedAt = Date()
                environment.library.upsert(entry)
            } else if type == .none {
                // 本来就没收藏，取消追番就什么也不用改。
            } else if await addToLibrary(type) {
                // 收藏库里没有这部番：从播放器加进去（见 addToLibrary）。
            } else {
                // 拿不到番剧信息就不假装加过（跟同步失败同一条口径）。
                surface.toastMessage = String(localized: "拿不到番剧信息，没能加入收藏")
                return
            }
            if type == .none {
                BangumiTimelineStore.shared.dropIfNotWatching(bangumiID, collectType: .none)
            }
            if syncEnabled, showToast {
                surface.toastMessage = "已同步到 Bangumi"
            }
            // 收藏状态那句只走 HUD 那条线（LP 4668）；顶部那条只留给同步进度 / 结果。
            // 两处都写就会弹两次（LP 4742）。
            surface.hudToastMessage = type == .none ? String(localized: "已取消追番") : String(localized: "已标为\(String(describing: type.title))")
        }
    }

    /// 收藏库里还没有这部番时，从播放器把它加进去。
    ///
    /// 播放器手上只有番剧 ID（名字、封面都在来源那边），所以缺的字段向 Bangumi 取一次，
    /// 字段跟详情页 `applyCollect(_:_:)` 建条目那一套完全一致——两处加的必须是同一种条目。
    private func addToLibrary(_ type: CollectType) async -> Bool {
        guard let item = await BangumiAPI.info(id: bangumiID) else { return false }
        environment.library.upsert(
            LibraryEntry(
                id: item.id,
                type: type.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: controller?.episodes.count ?? 0,
                currentEpisode: controller?.currentEpisode ?? 0,
                addedAt: Date(),
                updatedAt: Date()
            )
        )
        BangumiTimelineStore.shared.dropIfNotWatching(bangumiID, collectType: type)
        return true
    }

    /// 用户选的那一档（选中的勾看它，不跟着倒数变）。
    private var sleepTimerRemaining: Int? {
        guard let sleepTimerEnd else { return nil }
        let diff = Int(sleepTimerEnd.timeIntervalSinceNow)
        return max(0, diff)
    }

    private var sleepTimerMinutes: Int? {
        sleepTimerChosenMinutes
    }

    /// 档位保持固定；正在倒数的那一项标题实时显示 mm:ss。
    private func sleepTimerItemTitle(_ minutes: Int) -> String {
        if sleepTimerChosenMinutes == minutes,
           let remaining = sleepTimerRemaining {
            return String(format: "%02d:%02d", remaining / 60, remaining % 60)
        }
        return String(localized: "\(String(describing: minutes)) 分钟")
    }

    /// 到点暂停。定时器是一次性的 Task，改定或取消都要把上一个收掉。
    private func startSleepTimer(minutes: Int) {
        noteInteraction()
        sleepTimerTask?.cancel()
        let seconds = Double(minutes * 60)
        sleepTimerEnd = Date().addingTimeInterval(seconds)
        sleepTimerChosenMinutes = minutes
        sleepTimerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            sleepTimerEnd = nil
            sleepTimerChosenMinutes = nil
            surface.pause()
            // 定时关闭那句跟倍速、收藏同一条线（LP 4668）。
            surface.hudToastMessage = String(localized: "定时关闭：已暂停")
            showControls()
        }
        surface.hudToastMessage = String(localized: "定时关闭：\(String(describing: minutes)) 分钟后暂停")
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEnd = nil
        sleepTimerChosenMinutes = nil
    }

    /// 远程投屏：AirPlay / DLNA 二选一，版面见 `CastSheet`（design-cast.md）。
    private var airPlaySheet: some View {
        CastSheet(
            mediaURL: controllerURLString,
            onPlay: { surface.play() },
            onPause: { surface.pause() },
            onSeek: { surface.seek(to: $0) },
            position: surface.currentTime,
            duration: surface.duration
        )
    }

    /// 外部播放：把这一集的地址交给系统分享面板，装了 VLC、Infuse 这类播放器就能在那里打开。
    @ViewBuilder
    private var externalPlaySheet: some View {
        if let urlString = controllerURLString, let url = URL(string: urlString) {
            ShareSheet(items: [url])
                .presentationDetents([.medium, .large])
        } else {
            ContentUnavailableView("还没有解析出地址", systemImage: "play.slash")
                .presentationDetents([.height(200)])
        }
    }

    /// 播放信息：这一集文件的实际编码规格 + 媒体地址，只读。
    /// 值从 mpv 现读，拿不到的项写「—」；深浅色跟着主题走。
    private var videoInfoSheet: some View {
        let info = surface.playbackInfo()
        let mediaURL = controllerURLString
        let rows: [(title: String, value: String)] = [
            (String(localized: "视频编码"), info?.videoCodec ?? "—"),
            (String(localized: "分辨率"), info?.resolution ?? "—"),
            (String(localized: "帧率"), info?.frameRate ?? "—"),
            (String(localized: "码率"), info?.videoBitrate ?? "—"),
            (String(localized: "音频编码"), info?.audioCodec ?? "—"),
            (String(localized: "声道"), info?.audioChannels ?? "—"),
            (String(localized: "采样率"), info?.sampleRate ?? "—"),
            (String(localized: "容器"), info?.container ?? "—"),
            (String(localized: "方向"), orientationSummary),
            // 超分到底有没有喂进 mpv：这里显示真正找到的着色器文件数
            // （Colo 2026-10-28：是 0 就是没挂上，是 6 但画面没变才是着色器本身的问题）。
            ("超分辨率", String(localized: "\(String(describing: settings.playbackSuperResolutionMode.title)) · \(String(describing: surface.appliedShaderCount())) 颗着色器（已挂）")),
        ]
        return NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 16)
                        }
                        infoRow(rows[index])
                    }
                    Divider()
                        .padding(.leading, 16)
                    mediaURLRow(mediaURL)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle("播放信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear {
            // 关掉时把「已复制」与定时器收干净，下次打开不带着上一次的状态。
            mediaURLCopiedTask?.cancel()
            mediaURLCopied = false
        }
        .presentationDetents([.medium, .large])
    }

    /// 「方向」那一行的值：支持哪些、现在是哪个、上次请求什么结果。
    /// 横屏切不回横屏时，一眼就能分出是系统没给还是我们没请求（Colo 2026-10-28）。
    private var orientationSummary: String {
        let supported = OrientationLock.mask
        var names: [String] = []
        if supported.contains(.portrait) { names.append(String(localized: "竖")) }
        if supported.contains(.landscapeLeft) { names.append(String(localized: "横左")) }
        if supported.contains(.landscapeRight) { names.append(String(localized: "横右")) }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let current: String
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: current = "横左"
        case .landscapeRight: current = "横右"
        case .portrait, .portraitUpsideDown: current = "竖"
        default: current = "—"
        }
        let nameList = names.joined(separator: "+")
        return String(localized: "支持 \(nameList) · 当前 \(current) · \(lastOrientationResult)")
    }

    /// 播放信息里的一条：左标题、右值。
    private func infoRow(_ row: (title: String, value: String)) -> some View {
        HStack(spacing: 16) {
            Text(row.title)
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            Spacer(minLength: 12)
            Text(row.value)
                .font(.system(size: 15).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    /// 媒体地址：点一下复制完整地址；复制后右侧闪一下「已复制」并震一下。
    /// 屏上只显示一行、中间截断，长地址不会把排版撑破。
    private func mediaURLRow(_ urlString: String?) -> some View {
        Button {
            guard let urlString else { return }
            UIPasteboard.general.string = urlString
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            mediaURLCopied = true
            mediaURLCopiedTask?.cancel()
            mediaURLCopiedTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                mediaURLCopied = false
            }
        } label: {
            HStack(spacing: 16) {
                Text("媒体地址")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Spacer(minLength: 12)
                Text(mediaURLCopied ? "已复制" : (urlString ?? "—"))
                    .font(.system(size: 15).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(
                        mediaURLCopied
                            ? KazumiPalette.accent(for: colorScheme)
                            : Color.primary
                    )
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(urlString == nil)
        .accessibilityLabel("媒体地址")
        .accessibilityValue(mediaURLCopied ? "已复制" : (urlString ?? String(localized: "不可用")))
        .accessibilityHint("点按复制完整地址")
    }

    /// 片头片尾跳过胶囊的右边距与底边距：
    /// 右缘紧贴右侧垂直居中的截图按钮热区左缘（`controlTrailingPadding + toolbarHitSize`，与相机图标留约 10pt 视觉间距），
    /// 彻底错开截图按钮所在的垂直列，既不重叠也不拉得过远。
    private var skipPillTrailingInset: CGFloat {
        controlTrailingPadding + toolbarHitSize
    }

    private var skipPillBottomInset: CGFloat {
        let usesWide = surfaceWidth >= 600 || (isFullscreen && !usesInlineFullscreen)
        let activeBarHeight = usesWide ? Self.landscapeTransportContentHeight : Self.portraitTransportHeight
        if controlsShown {
            return activeBarHeight + (isFullscreen ? fullscreenBottomPadding : 0) + 12
        }
        return (isFullscreen ? fullscreenBottomPadding : 16)
    }

    /// 当前这一集的媒体地址（解析出来才有）。
    private var controllerURLString: String? {
        guard let text = controller?.playbackURL, !text.isEmpty else { return nil }
        return text
    }

    /// 弹幕开关（L2 常驻工具栏层级）。
    private var danmakuButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            noteInteraction()
            handleDanmakuButton()
        } content: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                .playerIcon(
                    pointSize: l2SymbolSize,
                    weight: .medium,
                    optical: danmakuEnabled ? .solid : .standard
                )
                .foregroundStyle(.white)
        }
        .accessibilityLabel(danmakuEnabled ? String(localized: "关闭弹幕") : String(localized: "打开弹幕"))
    }

    /// 全屏弹幕设置按钮（位于弹幕开关右侧）。
    private var danmakuSettingsButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            noteInteraction()
            openSheet(.danmakuSettings)
        } content: {
            Image(uiImage: danmakuSettingsIcon)
                .renderingMode(.template)
                .playerIcon(pointSize: l2SymbolSize, weight: .medium)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(String(localized: "弹幕设置"))
    }

    private func handleDanmakuButton() {
        if danmakuEnabled {
            danmakuEnabled = false
            return
        }
        if controller?.danmakuStatus == .loading {
            surface.hudToastMessage = String(localized: "弹幕正在加载")
            return
        }
        if let comments = controller?.danmakuComments, !comments.isEmpty {
            danmakuEnabled = true
            return
        }
        openSheet(.danmakuSource)
    }

    private var danmakuInitialKeyword: String {
        let library = environment.library
        if let entry = library.entry(for: bangumiID), !entry.displayName.isEmpty {
            return entry.displayName
        }
        if let record = library.record(for: bangumiID), !record.bangumiName.isEmpty {
            return record.bangumiName
        }
        return source?.itemName ?? ""
    }

    private func applyManualDanmaku(
        _ episode: DanmakuEpisode,
        animeID: Int,
        animeEpisodes: [DanmakuEpisode]
    ) async -> String? {
        guard let controller else {
            return String(localized: "播放器已关闭")
        }
        switch await controller.loadDanmaku(
            episodeID: episode.episodeID,
            animeID: animeID,
            animeEpisodes: animeEpisodes
        ) {
        case .loaded:
            danmakuEnabled = true
            return nil
        case .empty:
            return nil
        case .failed(let message):
            danmakuEnabled = false
            return message
        }
    }

    private nonisolated(unsafe) static var cachedDanmakuSettingsIcons: [String: UIImage] = [:]

    private var danmakuSettingsIcon: UIImage {
        let key = colorScheme == .dark ? "dark" : "light"
        if let cached = Self.cachedDanmakuSettingsIcons[key] { return cached }
        let rendered = Self.renderDanmakuSettingsIcon(scheme: colorScheme)
        Self.cachedDanmakuSettingsIcons[key] = rendered
        return rendered
    }

    private static func renderDanmakuSettingsIcon(scheme: ColorScheme) -> UIImage {
        let dark = scheme == .dark
        let renderer = ImageRenderer(
            content: DanmakuSettingsGlyph(color: dark ? .white : .black)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }

    /// 「更多」菜单（L2 常驻工具栏层级，§5 / §6）：
    /// 统一收纳弹幕设置、弹幕检索、片头快进（及秒数设置）、视频比例、定时关闭、播放信息、投屏、外部播放与一起看。
    private var moreMenu: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            SystemMenuButton(
                items: moreMenuItems,
                title: nil,
                symbol: "ellipsis",
                accessibilityLabel: String(localized: "更多选项"),
                tint: .white,
                symbolSize: l2SymbolSize,
                symbolWeight: .medium,
                symbolOptical: .detailed,
                hitSize: toolbarHitSize,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    private var moreMenuItems: [SystemMenuButton.Item] {
        var items: [SystemMenuButton.Item] = [
            SystemMenuButton.Item(
                title: String(localized: "弹幕设置"),
                symbol: "captions.bubble",
                symbolImage: danmakuSettingsIcon
            ) {
                closeMenu()
                openSheet(.danmakuSettings)
            },
            SystemMenuButton.Item(title: String(localized: "弹幕检索"), symbol: "bubble.left.and.bubble.right") {
                closeMenu()
                resumesAfterDanmakuSearch = true
                surface.pause()
                openSheet(.danmakuSource)
            },
        ]

        // 紧凑底栏不单摆超分键，窄窗口桌面端底栏收起超分时同样可从「更多」直达。
        if !showsInlineSuperResolution {
            items.append(
                SystemMenuButton.Item(
                    title: String(localized: "超分辨率"),
                    symbol: "wand.and.stars",
                    subtitle: settings.playbackSuperResolutionMode.title,
                    selection: .init(options: SuperResolutionMode.allCases.map { mode in
                        .init(
                            title: mode.title,
                            isSelected: settings.playbackSuperResolutionMode == mode
                        ) {
                            applySuperResolution(mode)
                        }
                    })
                ) {}
            )
        }

        items.append(contentsOf: [
            SystemMenuButton.Item(
                title: String(localized: "视频比例"),
                symbol: "aspectratio",
                subtitle: aspectRatioMode.label,
                selection: .init(options: PlayerAspectRatioMode.allCases.map { mode in
                    .init(title: mode.label, isSelected: aspectRatioMode == mode) {
                        aspectRatioMode = mode
                    }
                })
            ) {},
            SystemMenuButton.Item(title: String(localized: "播放信息"), symbol: "info.circle") {
                closeMenu()
                openSheet(.videoInfo)
            },
            SystemMenuButton.Item(title: String(localized: "远程投屏"), symbol: "airplayvideo") {
                closeMenu()
                openSheet(.airPlay)
            },
            SystemMenuButton.Item(title: String(localized: "外部播放"), symbol: "arrow.up.forward.app") {
                closeMenu()
                openSheet(.externalPlay)
            },
            SystemMenuButton.Item(
                title: SyncplayManager.shared.isConnected
                    ? String(localized: "一起看 · 已连接（\(SyncplayManager.shared.rttMs)ms）")
                    : String(localized: "一起看"),
                symbol: "person.2.wave.2"
            ) {
                closeMenu()
                openSheet(.syncPlay)
            },
        ])
        return items
    }

    private func pinControlsWhileMenuOpen() {
        showControls()
        menuOpen = true
        probeSawMenu = false
        menuOpenedAt = Date()
        probeLastSeen = Date()
        hideGeneration &+= 1
    }

    private func closeMenu() {
        menuOpen = false
        probeSawMenu = false
    }

    private func errorOverlay(_ message: String, controller: PlayerController) -> some View {
        // 错误要整块居中（LP 5485：符号、文字、按钮原来都偏上）：
        // 1/4 那条线是给转圈的加载提示留的，出错时用它会显得没居中。
        ZStack {
            Color.black.opacity(0.55)
            errorContent(message, controller: controller)
                .padding(.horizontal, 24)
        }
        .allowsHitTesting(true)
    }

    private func errorContent(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button("重新加载") {
                    surface.errorMessage = nil
                    Task { await controller.retry() }
                }
                .buttonStyle(.borderedProminent)

                Button("返回选源") {
                    SourceSheetCoordinator.shared.markFailedReturnToSources(bangumiID: bangumiID)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func statusOverlay(_ controller: PlayerController) -> some View {
        // 全屏下的失败要能点（重新加载 / 看原因），所以放在 `loadingAtCenterLine`
        // 外面——那一层是 `allowsHitTesting(false)` 的，只给纯提示用。
        if case .failed(let message) = controller.phase, isFullscreen {
            return AnyView(
                errorContent(message, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        // 圈跟加载信息、集数一起从正中那条线往下排（LP 4913）。
        return AnyView(loadingAtCenterLine {
        VStack(spacing: 10) {
            switch controller.phase {
            case .idle, .searchingSource, .resolvingChapters, .parsingMedia:
                // 解析阶段还没有 mpv，拿不到网速，所以只转圈（`bytesPerSecond` 默认 0）。
                PlayerLoadingHUD(info: phaseTitle(controller.phase), reservesSpeedLine: false)
                // 切集时先亮一下目标集数，代替原版的「正在加载${集标题}」
                // （原生这边只有 URL，没有集标题）。
                if showsEpisodeLoadingLine(controller.phase) {
                    Text(String(localized: "正在加载第 \(String(describing: controller.currentEpisode)) 集"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                // Camo 5208：本集还没下完、这轮要走在线解析，说一句。
                // 位置跟上面那行同处；起播成功或失败（phase 变化）就收。
                if controller.isEpisodeIncomplete {
                    Text("本集下载未完成，正在尝试在线播放")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                // 原来这儿挂着内核日志的最后一行。LP 4810：屏蔽掉，
                // 画面上只留圈（+ 网速），日志照旧进 KazumiLogBuffer 给排查用。
            case .failed:
                // 失败提示不压在画面正中间：挪到下面「选集」那一块里
                // （平时列剧集的位置），跟页面一起推进来（LP 3286 / Colo 3287）。
                // 全屏那一份在上面单独处理（那一块不画）。
                EmptyView()
            case .ready:
                EmptyView()
            }
        }
        })
    }

    private func phaseTitle(_ phase: PlayerController.Phase) -> String {
        switch phase {
        case .idle: String(localized: "准备中…")
        case .searchingSource: String(localized: "正在查找播放源…")
        case .resolvingChapters: String(localized: "正在加载剧集列表…")
        case .parsingMedia: String(localized: "正在解析播放地址…")
        case .ready: ""
        case .failed: ""
        }
    }

    /// 「正在加载第 N 话」只在真正要播某一集时出现；查找播放源阶段还没定集数。
    private func showsEpisodeLoadingLine(_ phase: PlayerController.Phase) -> Bool {
        switch phase {
        case .idle, .resolvingChapters, .parsingMedia: true
        case .searchingSource, .ready, .failed: false
        }
    }

    /// 查找播放源阶段顶行已经是「正在查找播放源…」，不再叠一行同义的日志。
    private func showsLogLine(_ phase: PlayerController.Phase) -> Bool {
        phase != .searchingSource
    }

    // MARK: - 播放条

    /// 桌面端（Mac Catalyst 或检测到外接指针设备）展示独立静音与音量滑块（§8）。
    private var showsDesktopVolume: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return hasDetectedPointer
        #endif
    }

    /// 宽栏底栏是否内联展示超分按钮：桌面端全屏且宽度 `< 720pt` 时收进「更多」，严守底栏单行 `≤ 8` 项与 `600pt` 下弹幕框净宽 `≥ 180pt`（§6 F1）。
    private var showsInlineSuperResolution: Bool {
        guard surfaceWidth >= 600 || (isFullscreen && !usesInlineFullscreen) else { return false }
        if showsDesktopVolume && isFullscreen && surfaceWidth > 0 && surfaceWidth < 720 {
            return false
        }
        return true
    }

    /// 底栏（§1 / §2 / §6）：宽度断点严格读取左栏实际可用宽 `width`（而非外层窗口宽 `U`）。
    private func transportBar(_ controller: PlayerController, width: CGFloat) -> some View {
        Group {
            if width >= 600 || (isFullscreen && !usesInlineFullscreen) {
                landscapeTransport(controller)
            } else {
                portraitTransport(controller)
            }
        }
    }

    /// 紧凑底栏（手机竖屏与窄宽左栏）：全屏钮左侧使用统一的倍速符号按钮，非全屏底沿 `0` 额外留白。
    private func portraitTransport(_ controller: PlayerController) -> some View {
        let activeSegments = settings.aniSkipLookup ? controller.skipSegments : .empty
        return HStack(spacing: 4) {
            playPauseButton
            scrubber(height: 40, skipSegments: activeSegments)
            timeLabel
            speedButton
            fullscreenButton
        }
        .padding(.leading, controlLeadingPadding)
        .padding(.trailing, controlTrailingPadding)
        .frame(height: Self.portraitTransportHeight)
        .padding(.bottom, isFullscreen ? fullscreenBottomPadding : Self.portraitTransportBottomInset)
    }

    /// 宽栏底栏（§1 / §2 / §6 / §8）：
    /// - 「时间入轨」由 3 层减为 2 层（当前时间与总时长嵌入 `scrubber` 左右两端，省去 `28pt` 垂直高度）；
    /// - 主栏收敛为 7–8 项，`episodesButton` 严格仅在 `isFullscreen == true` 时渲染；
    /// - 非全屏底沿 `0` 额外留白，全屏避开左右与底部安全区及屏幕圆角。
    private func landscapeTransport(_ controller: PlayerController) -> some View {
        let activeSegments = settings.aniSkipLookup ? controller.skipSegments : .empty
        let hasHours = surface.duration >= 3600
        let timeMinWidth: CGFloat = hasHours ? 54 : 38

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(timeText(isScrubbing ? scrubValue : surface.currentTime))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .frame(minWidth: timeMinWidth, alignment: .leading)

                scrubber(height: 36, skipSegments: activeSegments)

                Text(timeText(surface.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .frame(minWidth: timeMinWidth, alignment: .trailing)
            }
            .padding(.leading, controlLeadingPadding)
            .padding(.trailing, controlTrailingPadding)
            .frame(height: 36)

            HStack(spacing: 4) {
                playPauseButton
                nextEpisodeButton(controller)
                if showsDesktopVolume {
                    desktopVolumeControl
                }
                danmakuButton
                if isFullscreen {
                    danmakuSettingsButton
                }
                danmakuField
                    .frame(maxWidth: .infinity)
                if showsInlineSuperResolution {
                    superResolutionButton
                }
                speedButton
                if isFullscreen {
                    episodesButton
                }
                fullscreenButton
            }
            .padding(.leading, controlLeadingPadding)
            .padding(.trailing, controlTrailingPadding)
            .frame(height: 44)
        }
        .padding(.bottom, isFullscreen ? fullscreenBottomPadding : 0)
    }

    /// `当前 / 总长`，12 号白色、等宽数字（紧凑底栏在进度条右边）。
    private var timeLabel: some View {
        Text("\(timeText(isScrubbing ? scrubValue : surface.currentTime)) / \(timeText(surface.duration))")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    /// 桌面端独立静音切换与悬浮展开音量滑块（§8）。
    private var desktopVolumeControl: some View {
        let level = surface.isMuted ? 0 : currentEffectiveVolume
        let symbol: String = if level <= 0.001 {
            "speaker.slash.fill"
        } else if level <= 0.4 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.2.fill"
        }

        return HStack(spacing: 4) {
            PlayerIconButton(hitSize: toolbarHitSize) {
                togglePlayerMute()
                noteInteraction()
            } content: {
                Image(systemName: symbol)
                    .playerIcon(pointSize: l2SymbolSize, weight: .medium, optical: .solid)
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(level <= 0.001 ? String(localized: "取消静音") : String(localized: "静音"))

            if isHoveringVolumeControl {
                GeometryReader { proxy in
                    let trackWidth = max(1, proxy.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(height: 4)
                        Capsule()
                            .fill(.white)
                            .frame(width: trackWidth * level, height: 4)
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .offset(x: min(max(trackWidth * level - 5, 0), max(trackWidth - 10, 0)))
                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let ratio = min(max(drag.location.x / trackWidth, 0), 1)
                                adjustPlayerVolume(to: Double(ratio))
                                noteInteraction()
                            }
                    )
                }
                .frame(width: 68, height: 36)
                .padding(.trailing, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                .accessibilityLabel(String(localized: "音量"))
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                volumeHoverDismissTask?.cancel()
                volumeHoverDismissTask = nil
                if !isHoveringVolumeControl {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isHoveringVolumeControl = true
                    }
                }
            case .ended:
                volumeHoverDismissTask?.cancel()
                volumeHoverDismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        isHoveringVolumeControl = false
                    }
                }
            }
        }
    }

    /// L1 传输主锚点（§5）：宽栏 `20pt .semibold`、紧凑栏 `18pt .semibold`，`.monochrome` 纯白高对比，
    /// `.symbolEffect(.replace)` 切换，固定 `44 × 44pt` 热区。
    private var playPauseButton: some View {
        PlayerIconButton(hitSize: 44) {
            surface.togglePlay()
            flashPlayPauseHUD()
            noteInteraction()
        } content: {
            Image(systemName: surface.isPlaying ? "pause.fill" : "play.fill")
                .playerIcon(
                    pointSize: l1SymbolSize,
                    weight: .semibold,
                    optical: .standard,
                    renderingMode: .monochrome
                )
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(surface.isPlaying ? String(localized: "暂停") : String(localized: "播放"))
    }

    private var fullscreenButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            toggleFullscreen()
        } content: {
            Image(systemName: isFullscreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .playerIcon(pointSize: l2SymbolSize, weight: .medium, optical: .detailed)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(isFullscreen ? String(localized: "退出全屏") : String(localized: "全屏"))
    }

    /// 下一集（L2 常驻工具栏层级）。
    private func nextEpisodeButton(_ controller: PlayerController) -> some View {
        let hasNext = controller.currentEpisode < controller.episodes.count
        return PlayerIconButton(hitSize: toolbarHitSize) {
            guard hasNext else { return }
            noteInteraction()
            Task { await controller.selectEpisode(controller.currentEpisode + 1) }
        } content: {
            Image(systemName: "forward.end.fill")
                .playerIcon(pointSize: l2SymbolSize, weight: .medium, optical: .solid)
                .foregroundStyle(.white.opacity(hasNext ? 1 : 0.35))
        }
        .disabled(!hasNext)
        .accessibilityLabel(String(localized: "下一集"))
    }

    /// 超分辨率（纯白单色渲染，避免分层模式把星点染灰）。
    private var superResolutionButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            SystemMenuButton(
                selection: .init(options: SuperResolutionMode.allCases.map { mode in
                    .init(title: mode.title, isSelected: settings.playbackSuperResolutionMode == mode) {
                        applySuperResolution(mode)
                    }
                }),
                title: nil,
                symbol: "wand.and.stars",
                accessibilityLabel: String(localized: "超分辨率 \(String(describing: settings.playbackSuperResolutionMode.title))"),
                symbolSize: l2ComplexSymbolSize,
                symbolWeight: .medium,
                symbolOptical: .detailed,
                hitSize: toolbarHitSize,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    /// 倍速（纯白单色渲染，避免分层模式把表盘刻度染灰）。
    private var speedButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            SystemMenuButton(
                selection: .init(options: PlaybackSpeed.all.map { rate in
                    .init(
                        title: speedText(rate),
                        isSelected: abs(playbackRate - Float(rate)) < 0.01
                    ) {
                        applySpeed(Float(rate))
                        noteInteraction()
                    }
                }),
                title: nil,
                symbol: "speedometer",
                accessibilityLabel: String(localized: "倍速 \(String(describing: speedText(Double(playbackRate))))"),
                symbolSize: l2ComplexSymbolSize,
                symbolWeight: .medium,
                symbolOptical: .standard,
                hitSize: toolbarHitSize,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    private var episodesButton: some View {
        PlayerIconButton(hitSize: toolbarHitSize) {
            if showsEpisodesPanel {
                closeEpisodesPanel()
            } else {
                openEpisodesPanel()
            }
        } content: {
            Image(systemName: "list.bullet")
                .playerIcon(pointSize: l2SymbolSize, weight: .medium)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(String(localized: "选集"))
    }

    /// 全屏右侧选集抽屉（§7 G3）：
    /// 避开上下与右侧安全区，四角连续圆角 `RoundedRectangle(cornerRadius: 28, style: .continuous)` 液态玻璃悬浮面板。
    private func episodesPanel(_ controller: PlayerController) -> some View {
        let available = max(surfaceWidth, 360)
        let panelWidth = min(available * 0.9, min(max(available / 3, 320), 420))
        let panelShape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return episodesPane(controller, centersCurrentEpisode: true)
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background {
                GlassBackdrop()
                    .clipShape(panelShape)
            }
            .clipShape(panelShape)
            .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
            .padding(.top, isFullscreen ? fullscreenBottomPadding : 16)
            .padding(.bottom, isFullscreen ? fullscreenBottomPadding : 16)
            .padding(.trailing, isFullscreen ? controlTrailingPadding : 16)
    }

    private func openEpisodesPanel() {
        showControls()
        pinControlsWhileMenuOpen()
        withAnimation(.easeOut(duration: 0.12)) {
            showsEpisodesPanel = true
        }
    }

    private func closeEpisodesPanel() {
        withAnimation(.easeOut(duration: 0.12)) {
            showsEpisodesPanel = false
        }
        closeMenu()
    }

    /// 横屏底栏里的发弹幕：白 38% 底、圆角、13 号、右边一颗「发送」。
    private var danmakuField: some View {
        HStack(spacing: 0) {
            TextField(
                "",
                text: $danmakuDraft,
                prompt: Text("发个友善的弹幕见证当下")
                    .foregroundStyle(.white.opacity(0.7))
            )
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($danmakuFieldFocused)
            .submitLabel(.send)
            .onSubmit { sendDanmaku() }
            .disabled(!danmakuEnabled)
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .onChange(of: danmakuFieldFocused) { _, focused in
                if focused {
                    showControls()
                    if surface.isPlaying {
                        surface.pause()
                        pausedForDanmakuInput = true
                    }
                } else {
                    if pausedForDanmakuInput {
                        pausedForDanmakuInput = false
                        let atEnd = surface.duration > 0
                            && surface.currentTime >= surface.duration - 0.5
                        if controllerPhase == .ready, !atEnd, !surface.isPlaying {
                            surface.play()
                        }
                    }
                    scheduleControlsHide()
                }
            }

            Button {
                if danmakuFieldFocused {
                    endDanmakuInput()
                } else {
                    sendDanmaku()
                }
            } label: {
                Text(danmakuFieldFocused ? String(localized: "取消") : String(localized: "发送"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(
                        danmakuFieldFocused || canSendDanmaku
                            ? .white
                            : .white.opacity(0.55)
                    )
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 10,
                            topTrailingRadius: 10,
                            style: .continuous
                        )
                        .fill(.black.opacity(danmakuEnabled ? 0.18 : 0.10))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerPressStyle())
            .disabled(!danmakuFieldFocused && !canSendDanmaku)
            .accessibilityLabel(danmakuFieldFocused ? String(localized: "取消") : String(localized: "发送弹幕"))
        }
        .frame(height: 33)
        .background(.white.opacity(danmakuEnabled ? 0.38 : 0.18),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canSendDanmaku: Bool {
        danmakuEnabled && !danmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func endDanmakuInput() {
        danmakuFieldFocused = false
        noteInteraction()
        showControlsBriefly()
    }

    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard danmakuEnabled, !text.isEmpty else { return }
        surface.danmakuOverlay?.sendLocal(text: text)
        danmakuDraft = ""
        danmakuFieldFocused = false
        noteInteraction()
        showControlsBriefly()
    }

    /// 进度条（§6）：支持在轨道上绘制已获取的 AniSkip 片头/片尾浅色高亮区间锚点，拖拽时即可预判位置。
    private func scrubber(
        height: CGFloat = 44,
        skipSegments: SkipSegments = .empty
    ) -> some View {
        let total = max(surface.duration, 0.001)
        let current = min(max(isScrubbing ? scrubValue : surface.currentTime, 0), total)
        let progress = total > 0 ? min(max(current / total, 0), 1) : 0
        let markerRanges = [skipSegments.opening, skipSegments.ending].compactMap { $0 }

        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let bubbleWidth: CGFloat = 72
            let bubbleX = min(max(scrubFingerX - bubbleWidth / 2, 0), max(width - bubbleWidth, 0))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: width * progress, height: 4)

                if surface.duration > 0, !markerRanges.isEmpty {
                    ForEach(Array(markerRanges.enumerated()), id: \.offset) { _, range in
                        let startRatio = min(max(range.start / total, 0), 1)
                        let endRatio = min(max(range.end / total, startRatio), 1)
                        let markerX = width * startRatio
                        let markerWidth = max(6, min(width - markerX, width * (endRatio - startRatio)))
                        Capsule()
                            .fill(KazumiPalette.accent(for: .dark, theme: settings.themeColor).opacity(0.92))
                            .frame(width: markerWidth, height: 4)
                            .offset(x: markerX)
                            .allowsHitTesting(false)
                    }
                }

                Color.clear
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing { onScrub(true) }
                        let x = min(max(value.location.x, 0), width)
                        scrubFingerX = x
                        let ratio = x / width
                        scrubValue = Double(ratio) * total
                    }
                    .onEnded { _ in onScrub(false) }
            )
            .overlay(alignment: .topLeading) {
                if isScrubbing {
                    scrubTimeBubble
                        .frame(width: bubbleWidth)
                        .offset(x: bubbleX, y: -20)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "播放进度"))
        .accessibilityValue(timeText(current))
    }

    /// 拖动时浮在轨道上方的那条目标时间：跟其他时间同一个格式，松手就收。
    private var scrubTimeBubble: some View {
        Text(timeText(scrubValue))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.92), in: Capsule())
    }

    private func speedText(_ value: Double) -> String { PlaybackSpeed.label(value) }

    private func applySpeed(_ rate: Float) {
        playbackRate = rate
        surface.setPlaybackRate(rate)
        // 倍速指示跟长按倍速胶囊同一条线（画面 1/4 处），LP 4668。
        surface.hudToastMessage = PlaybackSpeed.label(Double(rate))
    }

    private func onScrub(_ editing: Bool) {
        if editing {
            scrubValue = surface.currentTime
            isScrubbing = true
        } else {
            surface.seek(to: scrubValue)
            isScrubbing = false
        }
        PlayerHaptics.tap()
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - 进度与续播

    private func persistProgress(_ controller: PlayerController) {
        persistWatchProgress(
            library: environment.library,
            privateMode: settings.privateMode,
            controller: controller,
            position: surface.currentTime,
            duration: surface.duration
        )
        // 「自动标记看过」的消费端：看到 90% 就在 Bangumi 上把这集标成看过。
        // 隐身模式不标 —— 用户按下隐身就是不想在服务器留下痕迹。
        guard !settings.privateMode else { return }
        environment.bangumiProgress.onPosition(
            subjectID: controller.bangumiID,
            episodeNumber: controller.currentEpisode,
            position: surface.currentTime,
            duration: surface.duration
        )
    }

    /// 进入播放器时按「自动跳转」设置恢复同一集的播放位置。
    /// 只有存的正是当前这一集才续播，换集不迁跳（保留现有行为）。
    private func resumeIfNeeded(library: LibraryStore, controller: PlayerController) {
        guard settings.playResume else { return }
        // 按「这条规则 + 这部番」取记录，不是跨规则取最新那份（Fuck 4875）：
        // 详情页 / 推荐页是按这条规则算出集数和线路的，位置也得是这条规则记下的；
        // 拿最新那份一比规则名不一样就整个 bail，这条源存的进度就用不上了。
        // 没带源进来时（历史页进）记录本身就是那个源，按番剧号取。
        // 历史卡片进来时源还没重建，用卡片上带的那条规则名。
        let pluginName = controller.effectivePluginName
        let record = pluginName.isEmpty
            ? library.record(for: controller.bangumiID)
            : library.record(for: controller.bangumiID, pluginName: pluginName)
        guard let record else { return }
        guard record.episodeNumber == controller.currentEpisode else { return }
        guard record.progressSeconds > 1 else { return }
        // 存在结尾 5 秒内的一律当已看完，不续播（避免一进去就结束）。
        if record.durationSeconds > 0, record.progressSeconds >= record.durationSeconds - 5 {
            return
        }
        surface.pendingResumeTime = record.progressSeconds
    }

    // MARK: - 正在播放（控制中心 / 锁屏 / 灵动岛）

    /// 当前这一集在控制中心里叫什么、封面用哪张。
    /// 追番列表里有就用它，否则退到观看记录，再退到播放源里的条目名。
    private func nowPlayingMeta(_ controller: PlayerController) -> (title: String, artwork: String) {
        let library = environment.library
        if let entry = library.entry(for: controller.bangumiID), !entry.displayName.isEmpty {
            return (entry.displayName, entry.imageURL)
        }
        if let record = library.record(for: controller.bangumiID), !record.bangumiName.isEmpty {
            return (record.bangumiName, record.imageURL)
        }
        if let name = controller.source?.itemName, !name.isEmpty {
            return (name, "")
        }
        return ("Kazumi", "")
    }

    /// 把这一集的剧名、集数、封面、进度交给系统。
    /// 系统拿它画控制中心和锁屏那张卡；灵动岛上 Apple Music 那个样子也由它决定。
    private func syncNowPlaying() {
        guard let controller else { return }
        // 起播后再校一次音频会话：mpv 的音频输出会自己重设类别，
        // 一旦它盖成混音，系统就不会把我们当「正在播放」。
        // 注意这里**会写**：被盖成混音时要改类别，改不动就退一次会话再上，
        // 只在真的被盖掉时才发生，不是每次都写。
        PlayerAudioSession.shared.reapplyIfNeeded()
        // 还没拿到片源（时长 0）且没在播时不写：控制中心不该挂一张 00:00 的空卡片。
        guard surface.duration > 0 || surface.isPlaying else { return }
        // 「正在播放」这个位置是不是我们的？`isOtherAudioPlaying` 为 true 就说明
        // 会话还攥在别的 App 手里：卡能画出来，但点它不会回到这个 App
        // （LP 4976 第 2 条要查的就是这个）。只在变了的时候写，不每 2 秒刷一行。
        let otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if lastOtherAudioPlaying != otherAudioPlaying {
            lastOtherAudioPlaying = otherAudioPlaying
            KazumiLogBuffer.player("音频会话：别的 App 占着=\(otherAudioPlaying ? "是" : "否")")
        }
        let meta = nowPlayingMeta(controller)
        NowPlayingCenter.shared.update(
            title: meta.title,
            episode: controller.currentEpisode,
            episodeTitle: nil,
            artworkURL: meta.artwork,
            duration: surface.duration,
            elapsed: surface.currentTime,
            isPlaying: surface.isPlaying,
            // 真实倍速（含长按的临时倍速）：系统按这个速率自己往前推进度，
            // 写 1.0 的话 2 倍速下偏差每秒涨 1 秒，纠偏写入会从每 2 秒变成每 1.5 秒。
            //
            // 卡住（缓冲）那几秒要归零：`isPlaying` 这时仍然是 true
            // （`MPVPlayerContainer` 里「没暂停却没走，意图还在就算在播」，界面靠
            // `isStalled` 转圈），不归零的话系统照倍速自己往前推，恢复后要等一次
            // 1.5 秒纠偏才拉回来，卡片上就是「跑快了再跳回去」（LP 4925 第 2 条）。
            // `isPlaying` 不动：它一 false，`playbackState` 跟着变 paused，
            // 卡片上那颗按钮也变了 —— 那不是我们要的。
            rate: surface.isStalled ? 0 : Double(surface.desiredRate),
            // 队列长度（LP 5038）：系统靠「第几项 / 一共几项」把锁屏那两颗箭头
            // 当队列操作处理（main 经 audio_service 一直带着这个值）。
            episodeCount: controller.episodes.count
        )
    }

    /// 控制中心那几颗键接到画面上。只接一次；重复接会叠起来。
    private func configureNowPlayingCommands() {
        let center = NowPlayingCenter.shared
        let surface = self.surface
        center.onPlay = { [surface] in surface.play() }
        center.onPause = { [surface] in surface.pause() }
        center.onSeek = { [surface] position in
            surface.pendingResumeTime = nil
            surface.seek(to: position)
        }
        // 上一集 / 下一集**不在这里接**（LP 5033 / 5042）。
        //
        // 这个方法跑在 `.task` 里，启动那一瞬 `controller` 还是 nil（`bootstrapPlaybackIfNeeded`
        // 之后才创建）。`[weak controller]` 抓到的是「当时这个值」——nil，而且永远是 nil：
        // 真机日志里就是「遥控：收到下一集」紧接着「遥控：下一集拿不到播放控制器/集列表」，
        // 点几次都是这两行。播放/暂停那几颗用的是 `surface`，它从页面一出生就在，所以它们好使。
        // 接在 `controller = created` 之后（`bindEpisodeRemoteCommands`）。
        // 盒子接好就把指令注册上（Fuck 4881）：注册原来只在 `update()` 里发生，
        // 而 `update()` 被 `syncNowPlaying()` 的 `duration > 0 || isPlaying` 挡着——
        // 播放页刚打开、还没起播那一段，那几颗键是没注册的。
        center.configureRemoteCommands()
    }

    /// 上一集 / 下一集：**必须在 `controller` 创建之后接**（LP 5042）。
    /// 那时候 `created` 是个实打实的强引用，弱捕获才拿得到东西。
    private func bindEpisodeRemoteCommands(_ controller: PlayerController) {
        let center = NowPlayingCenter.shared
        let surface = self.surface
        center.onNext = { [weak controller, surface] in
            guard let controller else {
                KazumiLogBuffer.player("遥控：下一集播放控制器已经没了")
                return
            }
            guard !controller.episodes.isEmpty else {
                KazumiLogBuffer.player("遥控：下一集集列表还是空的")
                return
            }
            guard controller.currentEpisode < controller.episodes.count else {
                KazumiLogBuffer.player("遥控：已经是最后一集（\(controller.currentEpisode)/\(controller.episodes.count)）")
                return
            }
            KazumiLogBuffer.player("遥控：切到第 \(controller.currentEpisode + 1) 集")
            surface.prepareForNewEpisode()
            let target = controller.currentEpisode + 1
            Task { await controller.selectEpisode(target) }
        }
        center.onPrevious = { [weak controller, surface] in
            guard let controller else {
                KazumiLogBuffer.player("遥控：上一集播放控制器已经没了")
                return
            }
            guard !controller.episodes.isEmpty else {
                KazumiLogBuffer.player("遥控：上一集集列表还是空的")
                return
            }
            guard controller.currentEpisode > 1 else {
                KazumiLogBuffer.player("遥控：已经是第一集")
                return
            }
            KazumiLogBuffer.player("遥控：切回第 \(controller.currentEpisode - 1) 集")
            surface.prepareForNewEpisode()
            let target = controller.currentEpisode - 1
            Task { await controller.selectEpisode(target) }
        }
    }

    // MARK: - 上一集 / 下一集

    private func previousEpisode() {
        guard let controller else { return }
        // 章节还没抓回来时不报「已经是第一集」，否则正常加载会被误报成边界。
        guard !controller.episodes.isEmpty else { return }
        guard controller.currentEpisode > 1 else {
            surface.toastMessage = String(localized: "已经是第一集")
            return
        }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        let target = controller.currentEpisode - 1
        Task { await controller.selectEpisode(target) }
    }

    private func nextEpisode() {
        guard let controller else { return }
        guard !controller.episodes.isEmpty else { return }
        guard controller.currentEpisode < controller.episodes.count else {
            surface.toastMessage = "已经是最新一集"
            return
        }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        let target = controller.currentEpisode + 1
        Task { await controller.selectEpisode(target) }
    }

    // MARK: - 提示

    /// 加载符号该不该出现。
    ///
    /// 三件事都算「在加载」：起播还没真正开始、中途卡住（网卡缓冲）、正在 seek。
    ///
    /// 判据只看引擎推过来的相位（`isLoadingFirstFrame`）：打开中、等首帧才转，
    /// 到「在播」就收，播完 / 暂停 / 拖进度各按自己的标志走（Fuck 4816 提的那两种）。
    /// 唯一的例外是「有画面但暂停着」：那时画面已经在了，不该用圈盖住它。
    private var showsLoadingHUD: Bool {
        // 缓冲 / 拖进度：短暂提示，跟首帧那套逻辑分开（LP 4818 第 7 条）。
        if surface.isSeeking || surface.isStalled { return true }
        return surface.isLoadingFirstFrame
    }

    /// 加载圈下面那行「到底在等什么」。
    ///
    /// 速度没出来时以前是「— KB/s」，看不出是在连源、等首帧还是卡在缓冲。
    /// 这里按状态说人话；速度出来后 HUD 会多一行实时速率。
    private var playbackLoadingInfo: String? {
        if surface.isSeeking {
            return String(localized: "正在跳转…")
        }
        if surface.isStalled {
            return String(localized: "正在缓冲…")
        }
        if surface.isLoadingFirstFrame {
            return surface.downloadSpeed > 0
                ? String(localized: "正在缓冲…")
                : String(localized: "正在连接播放源…")
        }
        return nil
    }

    /// 加载符号的**圆心**钉在画面正中那条线上——跟两侧快进快退同一水平，
    /// 加载信息与网速顺着往下排（LP 4913）。
    ///
    /// 钉的是圆心不是整块的中心：下面多一行 / 少一行字时，圈本身一动不动
    /// （LP 4870 说的「跳了一下」）。
    private func loadingAtCenterLine<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let resolved = content()
        return GeometryReader { proxy in
            resolved
                .frame(maxWidth: .infinity)
                .padding(.top, proxy.size.height / 2 - PlayerLoadingHUD.circleHeight / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    /// 画面上 1/4 高度 HUD 容器（亮度/音量、快进秒数、超分、长按倍速、动作结果提示）。
    private func hudAtQuarter<Content: View>(
        interactive: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let resolved = content()
        return GeometryReader { proxy in
            resolved
                .position(x: proxy.size.width / 2, y: proxy.size.height / 4)
        }
        .allowsHitTesting(interactive)
    }

    /// 画面正中央 HUD 容器（仅用于播放 / 暂停反馈气泡）。
    private func hudAtCenter<Content: View>(
        interactive: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let resolved = content()
        return GeometryReader { proxy in
            resolved
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(interactive)
    }

    /// 亮度 / 音量的竖滑指示（L3 胶囊层级：`15pt .semibold` 图标 + `13pt .semibold monospacedDigit` 数值，胶囊高 `≥ 32pt`）。
    private func gestureOverlay(_ hud: GestureHUDValue) -> some View {
        let value = max(0, min(1, hud.value))
        return HStack(spacing: 8) {
            Image(systemName: hud.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hud.symbolColor)
                .contentTransition(.symbolEffect(.replace))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: 120 * value)
            }
            .frame(width: 120, height: 8)

            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 32)
        .playerGlass(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 横滑 / 两侧跳转的进度：横滑显示目标时间与偏移，双击只显示偏移。
    private func seekOverlay(_ seconds: Int, target: Double?) -> some View {
        HStack(spacing: 8) {
            if let target {
                Text(timeText(target))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 32)
        .playerGlass(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// 中央播放 / 暂停反馈浮层：恢复原始小符号尺寸（12pt .semibold）与圆角玻璃气泡。
    private func playPauseBubble(_ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(symbol == "play.fill" ? "暂停" : "播放")
                .font(.footnote.weight(.medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .playerGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 双击两侧：闪一下秒数。
    private func flashSeekHUD(_ seconds: Int) {
        withAnimation(.easeOut(duration: 0.2)) {
            gestureHUD = nil
            playPauseHUD = nil
            seekHUD = seconds
        }
        scheduleHUDHide(after: 1.2)
    }

    /// 双击中间：把刚切过去的状态画出来。暂停着就一直留着，播起来才淡出。
    /// 符号跟左下角那颗按钮读同一个状态：在播画 pause.fill、暂停画 play.fill，
    /// 两处不一致就是这里写反了（LP 2174）。
    ///
    /// 符号不动，文字翻过来（LP 2026-10-29 4800/4802）：三角那颗配「暂停」、
    /// 两条竖线那颗配「播放」。
    private func flashPlayPauseHUD() {
        withAnimation(.easeOut(duration: 0.2)) {
            gestureHUD = nil
            seekHUD = nil
            playPauseHUD = surface.isPlaying ? "pause.fill" : "play.fill"
        }
        scheduleHUDHide()
    }

    /// 音量浮层**只有这一条路径**：手势竖滑和音量键都走这里，画的都是 `gestureOverlay`
    /// 同一条横条、同一个位置、同一份玻璃（LP 2026-11-06）。
    private func showVolumeHUD(_ value: Double) {
        let clamped = max(0, min(1, value))
        // 记下来给自己去重：两个观察源会重复报同一个值。
        lastShownVolume = clamped
        gestureHUD = GestureHUDValue(kind: .volume, value: clamped)
    }

    /// 音量键只当触发器：值直接读当前音量（按键已经把它写进去了），
    /// 画出跟手势一模一样的那条。自己写音量引起的回声不算按键。
    ///
    /// **两个来源都要挂**（LP 2026-11-08 第 3 条：加载 / 缓冲 / 暂停时按音量键不出浮层）：
    /// * `AVAudioSession.outputVolume`——出声时最准；
    /// * MPVolumeView 的滑杆——那几个阶段会话音量不一定报变化，系统却把按键记在
    ///   媒体音量上，滑杆会动。
    /// 所以这个监听挂在页面出现时就装，不与「有没有拿到播放地址」「在不在播」绑。
    private func observeSystemVolume() {
        volumeObserver?.invalidate()
        volumeObserver = nil
        volumeSliderObserver?.invalidate()
        volumeSliderObserver = nil
        lastShownVolume = -1
        isObservingVolume = true
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, _ in
            let value = Double(session.outputVolume)
            Task { @MainActor in self.publishVolumeHUD(value) }
        }
        observeVolumeSlider()
    }

    /// 滑杆可能晚一两拍才装进窗口（`SystemVolumeHost` 那边也会重试几次找），
    /// 这里自己补几拍：找到就挂 KVO，找不到就放弃（会话那条仍然在）。
    private func observeVolumeSlider(attempt: Int = 0) {
        guard isObservingVolume else { return }
        if let slider = PlayerVolumeControl.shared.sliderForKeys() {
            volumeSliderObserver?.invalidate()
            volumeSliderObserver = slider.observe(\.value, options: [.new]) { _, change in
                // 读 `change.newValue` 而不是滑杆：`UISlider.value` 是主线程隔离的，
                // 在 KVO 的 Sendable 闭包里直接读会报警告。
                guard let reported = change.newValue else { return }
                Task { @MainActor in self.publishVolumeHUD(Double(reported)) }
            }
            return
        }
        guard attempt < 8 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self.isObservingVolume else { return }
            self.observeVolumeSlider(attempt: attempt + 1)
        }
    }

    /// 一次音量变化画出来。同一个值重复到达（两个来源都报了）只画一次，
    /// 免得浮层被重排两遍、隐藏定时器互相顶掉。
    private func publishVolumeHUD(_ value: Double) {
        guard !PlayerVolumeControl.shared.isWriting else { return }
        // 正在竖滑调音量：系统会把我们写进去的整步值回播一次，画出来会让横条
        // 从连续值跳成 1/16 的台阶。拖动期间一律不接回声（手势那条自己会画）。
        guard dragAxis != .volume else { return }
        let clamped = max(0, min(1, value))
        guard abs(clamped - lastShownVolume) > 0.0001 else { return }
        showVolumeHUD(clamped)
        scheduleHUDHide()
    }

    /// 手指离开后淡出（默认 0.6 秒），0.2 秒 easeOut；三朵浮层共用这一个定时器。
    private func scheduleHUDHide(after seconds: Double = 0.6) {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let keepsPausedIndicator = playPauseHUD != nil && !surface.isPlaying
            withAnimation(.easeOut(duration: 0.2)) {
                gestureHUD = nil
                seekHUD = nil
                if !keepsPausedIndicator { playPauseHUD = nil }
            }
        }
    }

    /// 长按加速的浮层：顶部正中一颗胶囊，写当前倍数（L3：胶囊整体高度 `≥ 32pt`）。
    private var temporarySpeedCapsule: some View {
        Text(PlaybackSpeed.label(Double(surface.desiredRate)))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minWidth: 52, minHeight: 32)
            .playerGlass(in: Capsule(style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 提示挂在哪：顶部那条是说明性的话，画面 1/4 那条是动作结果（LP 4668）。
    private enum ToastSlot {
        case top
        case hud
    }

    /// 提示气泡本身：顶部那条和 HUD 那条线共用，只是位置不同。
    private func toastBubble(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
    }

    /// 画面 1/4 处那句动作结果（倍速 / 收藏 / 定时关闭 / 已标记本集看过）。
    ///
    /// 玻璃跟其它 HUD 走同一个 `playerGlass` 入口：`ultraThinMaterial` 在深色画面上
    /// 偏灰发亮，跟旁边倍速胶囊、播放暂停气泡并排就露馅（LP 2026-11-08）。
    /// 形状和 14pt 圆角照旧，只换材质。
    private func hudToastBubble(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .playerGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 2 秒后自己收；task 以文案为 id，快速连点时上一条定时器自然作废。
    private func hideToast(_ message: String, slot: ToastSlot) async {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        switch slot {
        case .top:
            if surface.toastMessage == message { surface.toastMessage = nil }
        case .hud:
            if surface.hudToastMessage == message { surface.hudToastMessage = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let message = surface.toastMessage {
            toastBubble(message)
                .padding(.top, 8)
                .task(id: message) { await hideToast(message, slot: .top) }
        }
    }

    /// 「跳过秒数」弹框：对应原版 player_item_panel 的 _showForwardChange。
    @ViewBuilder
    private var skipSecondsDialog: some View {
        if isEditingSkipSeconds {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { dismissSkipSecondsDialog() }
                VStack(spacing: 14) {
                    Text("跳过秒数")
                        .font(.headline)
                    HStack(spacing: 8) {
                        TextField("秒", text: $skipSecondsInput)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                    if let error = skipSecondsError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Button("取消") { dismissSkipSecondsDialog() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Button("确定") { commitSkipSeconds() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )
                .padding(40)
            }
            .transition(.opacity)
        }
    }

    private func presentSkipSecondsDialog() {
        skipSecondsInput = "\(settings.buttonSkipTime)"
        skipSecondsError = nil
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingSkipSeconds = true
        }
    }

    private func dismissSkipSecondsDialog() {
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingSkipSeconds = false
        }
    }

    private func commitSkipSeconds() {
        let normalized = skipSecondsInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let rawValue = Double(normalized), rawValue.isFinite else {
            skipSecondsError = String(localized: "请输入数字")
            return
        }
        let value = Int(rawValue.rounded(.toNearestOrAwayFromZero))
        guard value > 0 else {
            skipSecondsError = String(localized: "请输入大于0的数字")
            return
        }
        settings.buttonSkipTime = value
        dismissSkipSecondsDialog()
    }

    // MARK: - 选集与评论

    /// 宽屏非全屏（Duo 展开 / iPad / 手机横屏 / 桌面窗口）左栏视频下方的番剧信息区：
    /// 专注承载完整标题、评分、集数/开播信息、标签与可滚动简介；换源/追番/缓存操作统一置于右栏选集顶部就近操作。
    private func widePlayerInfoCard(_ controller: PlayerController) -> some View {
        let meta = nowPlayingMeta(controller)
        let episodeNumber = max(1, controller.currentEpisode)
        let accent = KazumiPalette.accent(for: colorScheme)
        let entry = environment.library.entry(for: bangumiID)
        let rating = entry?.rating ?? bangumiInfo?.ratingScore ?? 0
        let airDate = !(entry?.airDate.isEmpty ?? true)
            ? (entry?.airDate ?? "")
            : (bangumiInfo?.airDate ?? "")
        let summary = !(entry?.summary.isEmpty ?? true)
            ? (entry?.summary ?? "")
            : (bangumiInfo?.summary ?? "")
        let tags: [String] = if let entry, !entry.tags.isEmpty {
            entry.tags
        } else if let info = bangumiInfo {
            info.tags.map(\.name).filter { !$0.isEmpty }
        } else {
            []
        }
        let totalEpisodes = controller.episodes.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meta.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if settings.showRating, rating > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(String(format: "%.1f", rating))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(accent)
                    .fixedSize()
                }
            }

            HStack(spacing: 6) {
                Text(String(localized: "正在播放 第 \(String(describing: episodeNumber)) 集"))
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(accent)
                if totalEpisodes > 0 {
                    Text("·")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "共 \(String(describing: totalEpisodes)) 集"))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !airDate.isEmpty {
                    Text("·")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(airDate)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !tags.isEmpty || !summary.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Array(tags.prefix(8)), id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(Color(.secondarySystemBackground))
                                            )
                                    }
                                }
                            }
                        }
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 仅向下延伸至底部安全区，禁止向左侧（.leading）安全区外溢浅色背景，
        // 保证手机横屏非全屏时左侧灵动岛安全区从顶到底保持完整纯黑，不会上黑下白漏出半截灵动岛。
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .bottom)
    }

    private func wideCollectMenuButton(accent: Color) -> some View {
        Menu {
            ForEach(CollectType.enabledCases, id: \.rawValue) { type in
                Button {
                    applyCollectType(type)
                } label: {
                    if currentCollectType == type {
                        Label(type.buttonTitle, systemImage: "checkmark")
                    } else {
                        Label(type.buttonTitle, systemImage: type.statusSymbol)
                    }
                }
            }
            if currentCollectType != .none {
                Divider()
                Button(role: .destructive) {
                    applyCollectType(.none)
                } label: {
                    Label(String(localized: "取消追番"), systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collectSymbolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(currentCollectType == .none ? String(localized: "追番") : currentCollectType.buttonTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .tint(accent)
        .accessibilityLabel(String(localized: "追番状态"))
    }

    private func wideDownloadButton(_ controller: PlayerController, accent: Color) -> some View {
        let hasEpisodes = !controller.episodes.isEmpty
        return Group {
            if isChoosingDownloads {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isChoosingDownloads = false
                        downloadSelection.removeAll()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(String(localized: "结束多选"))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule(style: .continuous).fill(Color(.secondarySystemBackground)))
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel(String(localized: "结束多选"))
            } else {
                Menu {
                    Button {
                        guard hasEpisodes else { return }
                        if detailTab != .episodes {
                            detailTab = .episodes
                        }
                        withAnimation(.easeOut(duration: 0.18)) {
                            isChoosingDownloads = true
                            downloadSelection.removeAll()
                        }
                    } label: {
                        Label("选择剧集缓存", systemImage: "checklist")
                    }
                    .disabled(!hasEpisodes)

                    Button {
                        persistProgress(controller)
                        environment.router.push(.download)
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .semibold))
                        Text(String(localized: "缓存剧集"))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule(style: .continuous).fill(Color(.secondarySystemBackground)))
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "下载剧集"))
            }
        }
    }

    /// 选集区（`episodeArea`）：
    /// - 手机竖屏下栏顶部展示 `40pt`「标题＋换源/追番/下载」紧凑条；
    /// - 宽屏非全屏（Duo 展开 / iPad / 手机横屏 / 桌面窗口）顶部预留安全间距并就近放置「换源/换线、追番、缓存剧集」胶囊行，下方紧跟「选集 / 评论」分段栏与内容。
    private func episodeArea(_ controller: PlayerController) -> some View {
        VStack(spacing: 0) {
            if isWideSplitLayout {
                wideEpisodeActionBar(controller)
                    .padding(.top, max(10, 18 - containerInsets.top))
            } else {
                episodeAreaHeader(controller)
                    .padding(.top, 6)
            }

            Picker("", selection: $detailTab) {
                ForEach(PlayerDetailTab.allCases) { tab in
                    Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .onChange(of: detailTab) { _, tab in
                if tab == .comments {
                    ensureDefaultCommentEpisode(controller)
                    loadCommentsIfNeeded()
                }
            }
            .onChange(of: isCommentsAscending) { _, _ in applyCommentsSort() }

            switch detailTab {
            case .episodes:
                episodesPane(controller)
            case .comments:
                commentsPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .leading) {
            if isWideSplitLayout {
                Rectangle()
                    .fill(Color(.separator).opacity(0.45))
                    .frame(width: 0.5)
            }
        }
    }

    /// 宽屏非全屏右栏顶部的就近操作栏：放置在「选集 / 评论」分段栏正上方，使切换线路/换源与缓存剧集紧贴选集网格且不挤占标题宽度。
    private func wideEpisodeActionBar(_ controller: PlayerController) -> some View {
        let meta = nowPlayingMeta(controller)
        let accent = KazumiPalette.accent(for: colorScheme)

        return HStack(spacing: 6) {
            episodeSourceAndRoadMenu(
                controller,
                titleFallback: meta.title,
                accent: accent,
                maxBadgeWidth: 200
            )
            Spacer(minLength: 4)
            wideCollectMenuButton(accent: accent)
                .fixedSize(horizontal: true, vertical: false)
            wideDownloadButton(controller, accent: accent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    /// 选集区顶部 `40pt`「状态＋换源」紧凑条（§6 F3）：
    /// 左侧展示当前番剧标题与集数定位，右侧放置「当前采集源/线路快切菜单胶囊」、「追番」与「下载」按钮。
    private func episodeAreaHeader(_ controller: PlayerController) -> some View {
        let meta = nowPlayingMeta(controller)
        let episodeNumber = max(1, controller.currentEpisode)
        let accent = KazumiPalette.accent(for: colorScheme)

        return HStack(spacing: 6) {
            Text("\(meta.title) · \(String(localized: "第\(String(describing: episodeNumber))集"))")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                episodeSourceAndRoadMenu(controller, titleFallback: meta.title, accent: accent)
                episodeCollectMenuButton(accent: accent)
                episodeDownloadHeaderButton(controller, accent: accent)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    /// 1 次点击展开「线路切换 ＋ 采集规则源快切 ＋ 全部规则选源面板」菜单胶囊（§6 F3）。
    private func episodeSourceAndRoadMenu(
        _ controller: PlayerController,
        titleFallback: String,
        accent: Color,
        maxBadgeWidth: CGFloat = 112
    ) -> some View {
        let currentPlugin = controller.effectivePluginName
        let currentRoadName: String? = controller.roads.indices.contains(controller.selectedRoad)
            ? Self.roadName(controller.roads[controller.selectedRoad])
            : nil
        let badgeTitle: String = {
            let ruleLabel = currentPlugin.isEmpty ? String(localized: "换源") : currentPlugin
            if controller.roads.count > 1, let currentRoadName {
                return "\(ruleLabel) · \(currentRoadName)"
            }
            return ruleLabel
        }()

        return Menu {
            if !controller.roads.isEmpty {
                Section(String(localized: "切换线路")) {
                    ForEach(Array(controller.roads.enumerated()), id: \.offset) { index, road in
                        Button {
                            guard index != controller.selectedRoad else { return }
                            persistProgress(controller)
                            downloadSelection.removeAll()
                            surface.prepareForNewEpisode()
                            Task { await controller.selectRoad(index) }
                        } label: {
                            if index == controller.selectedRoad {
                                Label(Self.roadItemTitle(road), systemImage: "checkmark")
                            } else {
                                Text(Self.roadItemTitle(road))
                            }
                        }
                    }
                }
            }

            if !environment.plugins.pluginList.isEmpty {
                Section(String(localized: "切换采集源")) {
                    ForEach(environment.plugins.pluginList, id: \.name) { plugin in
                        Button {
                            guard plugin.name != currentPlugin else { return }
                            persistProgress(controller)
                            downloadSelection.removeAll()
                            surface.prepareForNewEpisode()
                            Task {
                                await controller.switchPlugin(
                                    named: plugin.name,
                                    preferredTitle: titleFallback
                                )
                            }
                        } label: {
                            if plugin.name == currentPlugin {
                                Label(plugin.name, systemImage: "checkmark")
                            } else {
                                Text(plugin.name)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    presentSourceSwitcherSheet(controller, fallbackTitle: titleFallback)
                } label: {
                    Label(String(localized: "全部规则源对比…"), systemImage: "square.stack.3d.up")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(badgeTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .frame(maxWidth: maxBadgeWidth, minHeight: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .tint(accent)
        .accessibilityLabel(String(localized: "切换采集源或线路，当前 \(badgeTitle)"))
    }

    /// 选集区顶部追番菜单按钮（胶囊高 `32pt`，触控高 `40pt ≥ 36pt`）。
    private func episodeCollectMenuButton(accent: Color) -> some View {
        Menu {
            ForEach(CollectType.enabledCases, id: \.rawValue) { type in
                Button {
                    applyCollectType(type)
                } label: {
                    if currentCollectType == type {
                        Label(type.buttonTitle, systemImage: "checkmark")
                    } else {
                        Label(type.buttonTitle, systemImage: type.statusSymbol)
                    }
                }
            }
            if currentCollectType != .none {
                Divider()
                Button(role: .destructive) {
                    applyCollectType(.none)
                } label: {
                    Label(String(localized: "取消追番"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: collectSymbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .tint(accent)
        .accessibilityLabel(String(localized: "追番状态"))
    }

    /// 选集区顶部下载切换按钮（胶囊高 `32pt`，触控高 `40pt ≥ 36pt`）。
    private func episodeDownloadHeaderButton(_ controller: PlayerController, accent: Color) -> some View {
        let hasEpisodes = !controller.episodes.isEmpty
        return Group {
            if isChoosingDownloads {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isChoosingDownloads = false
                        downloadSelection.removeAll()
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 36, height: 32)
                        .background(Capsule(style: .continuous).fill(Color(.secondarySystemBackground)))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel(String(localized: "结束多选"))
            } else {
                Menu {
                    Button {
                        guard hasEpisodes else { return }
                        if detailTab != .episodes {
                            detailTab = .episodes
                        }
                        withAnimation(.easeOut(duration: 0.18)) {
                            isChoosingDownloads = true
                            downloadSelection.removeAll()
                        }
                    } label: {
                        Label("选择剧集缓存", systemImage: "checklist")
                    }
                    .disabled(!hasEpisodes)

                    Button {
                        persistProgress(controller)
                        environment.router.push(.download)
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 36, height: 32)
                        .background(Capsule(style: .continuous).fill(Color(.secondarySystemBackground)))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "下载剧集"))
            }
        }
    }

    /// 剧集没能加载时，这句话和「重试」就放在平时列剧集的位置（LP 3286 / Colo 3287）。
    /// 「返回选源」先留着：用户还能退回去挑别的来源。
    private func episodeFailure(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("重试") {
                    Task { await controller.retry() }
                }
                .buttonStyle(.borderedProminent)

                Button("返回选源") {
                    SourceSheetCoordinator.shared.markFailedReturnToSources(bangumiID: bangumiID)
                    dismiss()
                }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(KazumiPalette.accent(for: colorScheme))
    }

    @ViewBuilder
    private func episodesPane(
        _ controller: PlayerController,
        centersCurrentEpisode: Bool = false
    ) -> some View {
        let total = controller.episodes.count
        let pageSize = 100
        let pages = max(1, (total + pageSize - 1) / pageSize)
        let currentPage = min(episodeGridPage, max(0, pages - 1))
        let lo = currentPage * pageSize
        let hi = min(total, lo + pageSize)
        let pageSelection = SystemMenuButton.Selection(options: (0 ..< pages).map { page in
            let a = page * pageSize + 1
            let b = min(total, (page + 1) * pageSize)
            return SystemMenuButton.Selection.Option(
                title: String(localized: "\(String(describing: a))–\(String(describing: b)) 集"),
                isSelected: episodeGridPage == page
            ) {
                episodeGridPage = page
            }
        })
        let pageTitle = String(localized: "\(String(describing: lo + 1))–\(String(describing: hi)) 集")
        let pageAccessibilityLabel = String(
            localized: "快速跳转，现在显示第 \(String(describing: lo + 1)) 到 \(String(describing: hi)) 集"
        )
        // 非全屏态下 `episodeAreaHeader` 已承载线路/规则快切与下载入口；此处仅在全屏抽屉、多页分块或下载多选态展示操作条。
        let showsSecondaryToolbar = isFullscreen
            ? (total > 0 || controller.roads.count > 1 || pages > 1)
            : (pages > 1 || isChoosingDownloads)

        VStack(spacing: 0) {
            if showsSecondaryToolbar {
                HStack(spacing: 8) {
                    if isFullscreen && (controller.roads.count > 1 || Self.selectedRoadHasNoName(controller)) {
                        roadMenu(controller)
                    }
                    if pages > 1 && !isChoosingDownloads {
                        Group {
                            if isFullscreen {
                                SystemMenuButton(
                                    selection: pageSelection,
                                    title: pageTitle,
                                    symbol: "",
                                    accessibilityLabel: pageAccessibilityLabel,
                                    tint: .accentColor,
                                    showsChevron: true,
                                    menuTint: .accentColor,
                                    capsule: true
                                )
                            } else {
                                SwiftSelectionMenuButton(
                                    selection: pageSelection,
                                    title: pageTitle,
                                    accessibilityLabel: pageAccessibilityLabel
                                )
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .frame(height: 44)
                    }
                    Spacer(minLength: 0)
                    if isChoosingDownloads {
                        downloadSelectionActions(controller)
                    } else if isFullscreen && total > 0 {
                        downloadEntryButton(controller)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
            }

            // 在线列表没抓到、只剩本地这份时，顶部说一句（Colo v3 第 9 条）。
            if controller.isOfflineEpisodeList {
                Text("在线列表没加载出来，只显示已下载的")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if case .failed(let message) = controller.phase {
                episodeFailure(message, controller: controller)
            } else if total == 0 {
                Text("暂无选集")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(lo ..< hi, id: \.self) { index in
                                Button {
                                    let number = index + 1
                                    if isChoosingDownloads {
                                        let lite = environment.downloads.liteStatus(
                                            recordKey: downloadRecordKey(controller),
                                            number: number
                                        )
                                        guard lite != .downloaded, lite != .queued, !lite.isDownloading else { return }
                                        if downloadSelection.contains(number) {
                                            downloadSelection.remove(number)
                                        } else {
                                            downloadSelection.insert(number)
                                        }
                                    } else {
                                        if controller.isOfflineEpisodeList,
                                           !(controller.episodes.indices.contains(index) && !controller.episodes[index].isEmpty) {
                                            return
                                        }
                                        switchEpisode(to: number, controller: controller)
                                    }
                                } label: {
                                    episodeGridCell(controller, index: index)
                                }
                                .buttonStyle(PlayerPressStyle())
                                .contextMenu {
                                    if !isChoosingDownloads, (settings.bangumiSyncEnable || settings.bangumiAutoMarkWatched) {
                                        Button {
                                            Task {
                                                await environment.bangumiProgress.markManually(
                                                    subjectID: controller.bangumiID,
                                                    episodeNumber: index + 1
                                                )
                                            }
                                        } label: {
                                            Label(String(localized: "标为已看 (Bangumi)"), systemImage: "checkmark.circle")
                                        }
                                    }
                                }
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        guard centersCurrentEpisode, total > 0 else { return }
                        let target = max(0, min(total - 1, controller.currentEpisode - 1))
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
        .onChange(of: controller.selectedRoad) {
            downloadSelection.removeAll()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 进来就把当前集那一块翻出来，不用用户再去找
            if total > 0 {
                let page = max(0, (controller.currentEpisode - 1) / pageSize)
                episodeGridPage = page
            }
        }
    }

    /// 网格里一格：当前集用主题色底与白字，其余白底。
    private func episodeGridCell(_ controller: PlayerController, index: Int) -> some View {
        let number = index + 1
        let isCurrent = number == controller.currentEpisode
        // 选择态里正在播改成描边，不然跟「已选」分不清（Colo 5090）。
        let isSelected = isChoosingDownloads && downloadSelection.contains(number)
        let lite = environment.downloads.liteStatus(recordKey: downloadRecordKey(controller), number: number)
        // 在线列表没抓到、退回下载记录时，没下好的集是空格子（Colo v3 第 9 条）。
        let missing = controller.isOfflineEpisodeList
            && !(controller.episodes.indices.contains(index) && !controller.episodes[index].isEmpty)
        let solid = isCurrent && !isChoosingDownloads ? true : isSelected

        return Text("\(number)")
            .font(.subheadline.monospacedDigit().weight(solid || (isCurrent && isChoosingDownloads) ? .semibold : .regular))
            .foregroundStyle(cellForeground(solid: solid, isCurrent: isCurrent, lite: lite))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(solid ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .overlay(alignment: .topTrailing) {
                // 已下载一颗下箭头、下载中一颗虚线下箭头、排队中一颗钟（Colo 5090 / LP 5187）。
                // 失败不再在格子上常驻：LP 5115 说那不该一直挂着，改成渲一句提示（见 failureNotice）。
                // LP 5187：符号颜色跟集数字一致，字号再大一级。
                let markColor = cellForeground(solid: solid, isCurrent: isCurrent, lite: lite)
                switch lite {
                case .downloaded:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(markColor)
                        .padding(4)
                case .downloading:
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(markColor)
                        .padding(4)
                case .queued:
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(markColor)
                        .padding(4)
                case .failed:
                    // LP 5194：下载失败给一颗感叹号。
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(markColor)
                        .padding(4)
                default:
                    EmptyView()
                }
            }
            .overlay {
                // 真的在下才给进度，排队中只有钟（Colo 5090 特意分开的两条）。
                // 进度贴着格子自己的圆角绕一圈（LP 5481）：原来那条直条压在圆角底边上，
                // 两头戳出弧线以外，跟胶囊的 R 对不上。
                if case .downloading(let progress) = lite {
                    let fraction = max(0.02, min(1, progress))
                    // 从左边正中起画、顺着边框顺时针走（LP 5499）；颜色跟格子里的数字同一个，
                    // 不用主题色——主题色在这块底上会跟集数打架。
                    let ringColor = cellForeground(solid: solid, isCurrent: isCurrent, lite: lite)
                    EdgeProgressRing(fraction: fraction, cornerRadius: 10)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .padding(1)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(cellStroke(solid: solid, isCurrent: isCurrent), lineWidth: isCurrent && isChoosingDownloads ? 1.5 : 0.5)
            )
            // 已下载 / 排队中的格子不让点，但颜色不变浅（LP 5187）。
            .opacity(missing ? 0.45 : 1)
            .contentShape(Rectangle())
    }

    /// 格子里的数字颜色：实心时白字，其余跟着系统。
    /// LP 5187：已下载不再变浅，数字跟普通集一个色。
    private func cellForeground(
        solid: Bool,
        isCurrent: Bool,
        lite: DownloadLiteStatus
    ) -> Color {
        if solid { return .white }
        if isCurrent { return Color.accentColor }
        return .primary
    }

    /// 描边：实心时不描；选择态里正在播描主题色，其余跟系统分隔线。
    private func cellStroke(solid: Bool, isCurrent: Bool) -> Color {
        if solid { return .clear }
        if isCurrent && isChoosingDownloads { return Color.accentColor }
        return Color(.separator)
    }

    // MARK: - 下载（LP 5084 / Colo 5090）

    /// 面板顶行最右端的下载入口：32 高的胶囊，点击区域给到 44。
    private func downloadEntryButton(_ controller: PlayerController) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                isChoosingDownloads = true
                downloadSelection.removeAll()
            }
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                // 胶囊只有 32 高，但手指该点得中 44（Colo 5090）。
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(String(localized: "下载剧集"))
    }

    /// 选择态的三颗按钮：取消 / 全选（取消全选）/ 下载 N 集。
    /// 线路菜单还在左边，这里不占它的位置（LP 5100）。
    private func downloadSelectionActions(_ controller: PlayerController) -> some View {
        let recordKey = downloadRecordKey(controller)
        let downloaded = environment.downloads.downloadedNumbers(recordKey: recordKey)
        let selectable = max(0, controller.episodes.count - downloaded.count)
        let allSelected = selectable > 0 && downloadSelection.count >= selectable

        return HStack(spacing: 4) {
            Button("取消") {
                withAnimation(.easeOut(duration: 0.18)) {
                    isChoosingDownloads = false
                    downloadSelection.removeAll()
                }
            }
            .buttonStyle(PlayerPressStyle())
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .frame(height: 44)

            Button(allSelected ? "取消全选" : "全选") {
                // 两个词都占位，按钮不跳（Colo 5090）。
                if allSelected {
                    downloadSelection.removeAll()
                } else {
                    downloadSelection = Set(1 ... max(1, controller.episodes.count))
                        .subtracting(downloaded)
                }
            }
            .buttonStyle(PlayerPressStyle())
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 56, minHeight: 44)
            .disabled(selectable == 0)

            Button {
                startSelectedDownloads(controller)
            } label: {
                Text(downloadSelection.isEmpty ? "下载" : String(localized: "下载 \(String(describing: downloadSelection.count)) 集"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerPressStyle())
            .disabled(downloadSelection.isEmpty)
            .opacity(downloadSelection.isEmpty ? 0.4 : 1)
            .accessibilityLabel(String(localized: "下载选中的 \(String(describing: downloadSelection.count)) 集"))
        }
    }

    /// 这份记录的身份：同一部番 + 同一条规则 + 同一条线路一份。
    private func downloadRecordKey(_ controller: PlayerController) -> String {
        DownloadRecord.key(
            bangumiID: controller.bangumiID,
            pluginName: controller.effectivePluginName,
            road: controller.selectedRoad
        )
    }

    /// 把勾中的集数交给下载中心。
    private func startSelectedDownloads(_ controller: PlayerController) {
        let roadIndex = controller.selectedRoad
        guard controller.roads.indices.contains(roadIndex) else { return }
        let pages = controller.roads[roadIndex].data
        let items: [(number: Int, title: String, pageURL: String)] = downloadSelection.sorted().compactMap { number in
            let index = number - 1
            guard pages.indices.contains(index) else { return nil }
            let title = controller.episodes.indices.contains(index) ? controller.episodes[index] : ""
            return (number, title, pages[index])
        }
        guard !items.isEmpty else { return }

        let cachedSubject = BangumiSubjectCache.shared.item(for: controller.bangumiID)
        let libraryEntry = environment.library.entry(for: controller.bangumiID)
        let historyRecord = environment.library.record(for: controller.bangumiID)
        let resolvedTitle = [
            cachedSubject?.displayName,
            libraryEntry?.displayName,
            historyRecord?.bangumiName,
            controller.source?.itemName,
        ].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        environment.downloads.enqueue(
            bangumiID: controller.bangumiID,
            title: resolvedTitle,
            coverURL: "",
            pluginName: controller.effectivePluginName,
            road: roadIndex,
            // 条目身份一起存：回放时它才是接口模式要的 vod_id（LP 5508/5512）。
            itemSource: controller.source?.detailURL ?? "",
            episodes: items
        )
        surface.hudToastMessage = String(localized: "已加入下载队列（\(items.count) 集）")
        withAnimation(.easeOut(duration: 0.18)) {
            isChoosingDownloads = false
            downloadSelection.removeAll()
        }
    }

    /// 评论页：默认当集（无整部番），选集与排序菜单锁住自然宽度不截字，条数紧凑单行显示。
    @ViewBuilder
    private var commentsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SwiftSelectionMenuButton(
                    selection: commentEpisodeSelection(),
                    title: commentEpisode.map { String(localized: "第 \(String(describing: $0)) 集") } ?? String(localized: "第 — 集"),
                    accessibilityLabel: commentEpisode.map { String(localized: "当前查看第 \(String(describing: $0)) 集评论") } ?? String(localized: "当前查看集数评论")
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 44)

                Text(commentTotal == 0 ? String(localized: "暂无评论") : String(localized: "\(String(describing: commentTotal)) 条"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())

                Spacer(minLength: 4)

                SwiftSelectionMenuButton(
                    selection: .init(options: [
                        SystemMenuButton.Selection.Option(
                            title: String(localized: "最新优先"),
                            isSelected: !isCommentsAscending
                        ) {
                            if isCommentsAscending { isCommentsAscending = false }
                            applyCommentsSort()
                        },
                        SystemMenuButton.Selection.Option(
                            title: String(localized: "最早优先"),
                            isSelected: isCommentsAscending
                        ) {
                            if !isCommentsAscending { isCommentsAscending = true }
                            applyCommentsSort()
                        },
                    ]),
                    title: isCommentsAscending ? "最早优先" : "最新优先",
                    accessibilityLabel: String(localized: "评论排序")
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 44)

                Button {
                    Task { await reloadComments() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 32)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isLoadingComments)
                .accessibilityLabel(String(localized: "刷新评论"))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if isLoadingComments && comments.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载评论…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comments.isEmpty {
                if commentLoadFailed {
                    VStack(spacing: 10) {
                        Text("评论暂时未能加载")
                            .font(.subheadline.weight(.medium))
                        Text("请检查网络后重试，或换一集看看。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新加载") { Task { await reloadComments() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有人评论")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 用 ScrollView 不用 List：展开回复时要喊列表滚一滚（Colo 3366），
                // List 不给滚。分隔线照原来 List 的留法，从左缩 16。
                ScrollViewReader { proxy in
                    ScrollView {
                        // 必须写 alignment: .leading：LazyVStack 默认居中，整条评论（连头像）
                        // 会被摆到屏幕中间（LP 3389 / Colo 3390）。
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(comments) { comment in
                                CommentRowView(
                                    comment: comment,
                                    score: comment.rate > 0 ? comment.rate : nil,
                                    onExpand: { proxy.scrollTo(comment.id, anchor: .center) }
                                )
                                // 行自己也要铺满：不然行宽只到内容那么宽，还是会被居中。
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .id(comment.id)

                                Divider().padding(.leading, 16)
                            }
                            if commentTotal > comments.count {
                                Text(String(localized: "已显示 \(String(describing: comments.count)) / \(String(describing: commentTotal)) 条评论"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        // 跟选集那块一样：铺满并靠左，头部那行才不会整体被摆到中间。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 评论页左上那颗菜单的选项：每一集一条，当前这集由系统打勾。
    private func commentEpisodeSelection() -> SystemMenuButton.Selection {
        let total = controller?.episodes.count ?? 0
        guard total > 0 else { return .init(options: []) }
        return .init(options: (1 ... total).map { ep in
            .init(title: String(localized: "第 \(String(describing: ep)) 集"), isSelected: commentEpisode == ep) {
                switchCommentEpisode(ep)
            }
        })
    }

    /// 进评论页才拉，拉过就不重复拉；切集或刷新时也走 load。
    private func defaultCommentEpisode(_ controller: PlayerController) -> Int? {
        let ep = controller.currentEpisode
        guard controller.episodes.indices.contains(ep - 1) else { return nil }
        return ep
    }

    private func ensureDefaultCommentEpisode(_ controller: PlayerController) {
        // 只在「还没定过集」时默认到当集；用户切过就不再覆盖
        if commentEpisode == nil, let ep = defaultCommentEpisode(controller) {
            commentEpisode = ep
        }
    }

    private func loadCommentsIfNeeded() {
        guard comments.isEmpty, !isLoadingComments else { return }
        Task { await reloadComments() }
    }

    private func reloadComments() async {
        commentRequestGeneration &+= 1
        let generation = commentRequestGeneration
        isLoadingComments = true
        defer {
            if generation == commentRequestGeneration { isLoadingComments = false }
        }
        // 评论区默认只看当集：没定过就按当前集补上，失败才退回上一口径
        if commentEpisode == nil, let c = controller, let ep = defaultCommentEpisode(c) {
            commentEpisode = ep
        }
        let episode = commentEpisode
        let page: BangumiCommentPage
        if let ep = episode, let eid = await BangumiAPI.episodeID(subjectID: bangumiID, episode: ep) {
            guard generation == commentRequestGeneration, episode == commentEpisode else { return }
            page = await BangumiAPI.episodeComments(episodeID: eid)
        } else {
            // 兜底：当集还没解析出来或取不到 episodeID 时，退回整部番（避免空屏）
            guard generation == commentRequestGeneration, episode == commentEpisode else { return }
            page = await BangumiAPI.comments(subjectID: bangumiID)
        }
        guard generation == commentRequestGeneration, episode == commentEpisode else { return }
        var items = page.items
        // 排序：主分支在拿到就排好，这里沿用同一规则（按 updatedAt）
        items.sort { isCommentsAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
        comments = items
        commentTotal = page.total
    }

    private func switchCommentEpisode(_ episode: Int?) {
        commentRequestGeneration &+= 1
        commentEpisode = episode
        comments = []
        commentTotal = 0
        Task { await reloadComments() }
    }

    private func applyCommentsSort() {
        guard !comments.isEmpty else { return }
        comments.sort { isCommentsAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
    }

    /// 一行一集：集号在左，当前集打勾 + 主题色（不做「上次看到」推算）。
    private func episodeRow(_ controller: PlayerController, index: Int) -> some View {
        let number = index + 1
        let isCurrent = number == controller.currentEpisode
        return HStack(spacing: 8) {
            Text(String(localized: "第 \(String(describing: number)) 集"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 线路：多于一条时才出现，按钮上写当前实际在用的那条线路名。
    @ViewBuilder
    private func roadMenu(_ controller: PlayerController) -> some View {
        let selection = SystemMenuButton.Selection(
            options: controller.roads.enumerated().map { index, road in
                .init(
                    title: Self.roadItemTitle(road),
                    isSelected: index == controller.selectedRoad
                ) {
                    guard index != controller.selectedRoad else { return }
                    // 换线路 = 重新解析这一集，进度按原版先落一次。
                    persistProgress(controller)
                    surface.prepareForNewEpisode()
                    Task { await controller.selectRoad(index) }
                }
            }
        )
        // 不预设「线路 1」：来源给什么名字就显示什么名字（cht／chs 这种照抄），
        // 也不自己编号（LP 3370 / Colo 3371）。
        let title = controller.roads.indices.contains(controller.selectedRoad)
            ? Self.roadName(controller.roads[controller.selectedRoad])
            : String(localized: "线路")
        Group {
            if isFullscreen {
                // 字和箭头取设置里的主题色（LP 7379）：横屏这颗是 UIKit 按钮，
                // 传 .accentColor 经 UIColor 桥接脱离 SwiftUI 环境，解析不出
                // AppRoot 设的主题色；显式取调色板，底色仍是浅灰胶囊不动（Colo 7382）。
                let accent = KazumiPalette.accent(for: colorScheme)
                SystemMenuButton(
                    selection: selection,
                    title: title,
                    symbol: "",
                    accessibilityLabel: String(localized: "选择线路"),
                    tint: accent,
                    showsChevron: true,
                    menuTint: accent,
                    capsule: true
                )
            } else {
                SwiftSelectionMenuButton(
                    selection: selection,
                    title: title,
                    accessibilityLabel: String(localized: "选择线路")
                )
            }
        }
        .frame(height: 44)
    }

    /// 当前这条线路有没有名字：没名字时左边要写「线路」占位（LP 5127）。
    private static func selectedRoadHasNoName(_ controller: PlayerController) -> Bool {
        guard controller.roads.indices.contains(controller.selectedRoad) else { return true }
        return controller.roads[controller.selectedRoad].name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// 线路名照抄来源给的；来源没给名字就只写「线路」，不编号。
    private static func roadName(_ road: Road) -> String {
        let name = road.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "线路" : name
    }

    /// 菜单里那一条：线路名 · N 集（集数拿不到就不标，别写 0）。
    private static func roadItemTitle(_ road: Road) -> String {
        let name = roadName(road)
        return road.data.isEmpty ? name : String(localized: "\(String(describing: name)) · \(String(describing: road.data.count)) 集")
    }

    private func switchEpisode(to number: Int, controller: PlayerController) {
        // 点当前集是空操作（原版同样早退）；但上一次加载失败时允许重点重试。
        guard number != controller.currentEpisode || surface.errorMessage != nil else { return }
        persistProgress(controller)
        if commentEpisode != nil { commentEpisode = number }
        surface.prepareForNewEpisode()
        Task { await controller.selectEpisode(number) }
    }

    // MARK: - 选源面板与桌面端键鼠交互（§6 / §8）

    /// 从播放页内打开完整多规则选源面板，点选新源后就地切换不断栈（§6 F3）。
    private func presentSourceSwitcherSheet(_ controller: PlayerController, fallbackTitle: String) {
        guard environment.router.pendingExternalLink == nil else { return }
        let infoController: InfoController
        if let existing = playerSourceController, existing.item.id == bangumiID {
            infoController = existing
        } else if let shared = SourceSheetCoordinator.shared.cachedController(for: bangumiID) {
            playerSourceController = shared
            infoController = shared
        } else {
            let entry = environment.library.entry(for: bangumiID)
            let item = BangumiSubjectCache.shared.item(for: bangumiID)
                ?? BangumiItem(
                    id: bangumiID,
                    name: entry?.name ?? fallbackTitle,
                    nameCn: entry?.nameCn ?? fallbackTitle
                )
            let created = InfoController(item: item, plugins: environment.plugins)
            if let cachedEpisodes = BangumiSubjectCache.shared.memoryEpisodes(for: bangumiID),
               created.episodes.isEmpty {
                created.replaceEpisodes(cachedEpisodes)
            }
            SourceSheetCoordinator.shared.cacheController(created)
            playerSourceController = created
            infoController = created
        }

        SourceSheetCoordinator.shared.present(
            controller: infoController,
            onPlay: { pluginName, result in
                SourceSheetCoordinator.shared.dismiss()
                persistProgress(controller)
                downloadSelection.removeAll()
                surface.prepareForNewEpisode()
                let point = environment.library.resumePoint(for: bangumiID, pluginName: pluginName)
                let newSource = PlaybackSource(
                    pluginName: pluginName,
                    itemName: result.name,
                    detailURL: result.src,
                    directMediaURL: MediaUtility.isMediaURL(result.src) ? result.src : nil
                )
                Task {
                    await controller.switchSource(newSource, preferredRoad: point?.road)
                }
            },
            onOpenRuleShop: {
                openRuleShopAfterSourceSheet = true
                SourceSheetCoordinator.shared.dismiss()
            }
        )
    }

    /// 指针在播放画面内悬浮移动唤醒控制栏；播放中指针静止满 `2.5s` 自动隐藏控制栏并隐藏光标（§8）。
    private func handleSurfaceHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            if !hasDetectedPointer {
                hasDetectedPointer = true
            }
            if let last = lastHoverLocation,
               hypot(location.x - last.x, location.y - last.y) < 1.0 {
                return
            }
            lastHoverLocation = location
            pointerCursorHidden = false
            if !isSurfaceLocked {
                showControls()
            }
            pointerIdleHideTask?.cancel()
            pointerIdleHideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled, canHideControls else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    controlsVisible = false
                }
                #if targetEnvironment(macCatalyst)
                pointerCursorHidden = true
                #endif
            }
        case .ended:
            lastHoverLocation = nil
            pointerCursorHidden = false
            pointerIdleHideTask?.cancel()
            pointerIdleHideTask = nil
        }
    }

    /// 当前有效音量（0…1）：Mac Catalyst 走 mpv 内核音量，iOS 优先读系统滑杆并回退内核音量。
    private var currentEffectiveVolume: Double {
        #if targetEnvironment(macCatalyst)
        return surface.isMuted ? 0 : surface.volume
        #else
        if PlayerVolumeControl.shared.sliderForKeys() != nil {
            return surface.isMuted ? 0 : PlayerVolumeControl.shared.current
        }
        return surface.isMuted ? 0 : surface.volume
        #endif
    }

    private func adjustPlayerVolume(to rawValue: Double) {
        let clamped = min(max(rawValue, 0), 1)
        #if targetEnvironment(macCatalyst)
        surface.setVolume(clamped)
        #else
        if PlayerVolumeControl.shared.sliderForKeys() != nil {
            if surface.isMuted, clamped > 0.001 {
                surface.setMuted(false)
            }
            PlayerVolumeControl.shared.set(clamped)
        } else {
            surface.setVolume(clamped)
        }
        #endif
        showVolumeHUD(clamped)
    }

    private func stepPlayerVolume(by delta: Double) {
        let base = surface.isMuted ? 0 : currentEffectiveVolume
        let target = min(max(base + delta, 0), 1)
        adjustPlayerVolume(to: target)
        scheduleHUDHide()
        noteInteraction()
    }

    private func togglePlayerMute() {
        surface.toggleMute()
        let display = surface.isMuted ? 0 : currentEffectiveVolume
        showVolumeHUD(display)
        scheduleHUDHide()
    }

    /// 硬件键盘快捷键（§8 H2）：弹幕输入框未聚焦且无模态弹窗时生效。
    private func handlePlayerKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !danmakuFieldFocused,
              !isEditingSkipSeconds,
              activeSheet == nil,
              !SourceSheetCoordinator.shared.isPresented
        else {
            return .ignored
        }

        if press.key == .escape {
            if showsEpisodesPanel {
                closeEpisodesPanel()
                return .handled
            }
            if isFullscreen {
                exitFullscreen()
                return .handled
            }
            return .ignored
        }

        guard !isSurfaceLocked else { return .ignored }

        switch press.key {
        case .space:
            surface.togglePlay()
            flashPlayPauseHUD()
            showControlsBriefly()
            return .handled
        case .leftArrow:
            guard controller?.playbackURL != nil else { return .ignored }
            surface.seek(to: max(0, surface.currentTime - 5))
            flashSeekHUD(-5)
            showControlsBriefly()
            return .handled
        case .rightArrow:
            guard controller?.playbackURL != nil else { return .ignored }
            surface.skipForward(seconds: 5)
            flashSeekHUD(5)
            showControlsBriefly()
            return .handled
        case .upArrow:
            stepPlayerVolume(by: 0.05)
            return .handled
        case .downArrow:
            stepPlayerVolume(by: -0.05)
            return .handled
        default:
            return .ignored
        }
    }
}

/// 把一次播放位置写进观看历史（对应原版 history 记录）。
///
/// 抽成文件内自由函数是为了让 `surface.onFinish` 那个长期存活的开包
/// 也能直接写进度，而不必把整个 View 捕进去。
/// 距离结尾 5 秒以内视为已看完，进度归零保存，下次从头播（对应原版
/// `nearEndWatchedThreshold`）。
@MainActor
private func persistWatchProgress(
    library: LibraryStore,
    privateMode: Bool,
    controller: PlayerController,
    position: Double,
    duration: Double
) {
    // 隐身模式：不写观看记录（LP 清单「隐身模式」，Ato：进历史前判一下）。
    guard !privateMode else { return }
    // 没真播过就不进历史（LP 2026-10-25）：「剧集查询失败」那种一次都没起播的，
    // 位置停在 0、时长也拿不到，写进去就是一条 0 进度的空记录。
    guard position.isFinite, duration.isFinite, duration > 0, position >= 1 else { return }
    var progress = position
    if duration > 0, progress >= duration - 5 {
        progress = 0
    }
    // 离线从历史进来时播放源可能一直没重建出来：规则名按卡片上那条算，
    // 剧名退回已经存过的记录。用空串去写会新建一条空白历史，本次离线进度
    // 就回不到原来那张卡片上（#27）。
    let pluginName = controller.effectivePluginName
    let entry = library.entry(for: controller.bangumiID)
    let storedName = [
        controller.source?.itemName,
        library.record(for: controller.bangumiID, pluginName: pluginName)?.bangumiName,
        entry?.displayName,
    ].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    let storedImage = entry?.imageURL ?? ""
    // 走 store 那一个入口写进度：同一「规则 + 番剧」只留一份记录，
    // 每一集各带自己的线路号（main 的 History.progresses）。
    library.recordWatch(
        bangumiID: controller.bangumiID,
        bangumiName: storedName,
        imageURL: storedImage,
        pluginName: pluginName,
        episodeNumber: controller.currentEpisode,
        // 原生这边只有 URL，没有集标题，留空由历史页回退成「第 N 话」。
        episodeTitle: "",
        // 下次从详情页「开始观看」时按这条线路接上（main 记线路的原因）。
        road: controller.selectedRoad,
        position: progress,
        duration: duration.isFinite && duration > 0 ? duration : 0
    )

    // 没追过番的条目，名字和封面在上面都是空串，记录就成了空壳。
    // Colo 3554：缺的那几样用番剧 ID 向 Bangumi 取一次、写回同一条记录；
    // 这里补、不在列表里就地补，别处读同一条记录也就都有名字了。
    guard storedName.isEmpty || storedImage.isEmpty else { return }
    let bangumiID = controller.bangumiID
    Task { @MainActor in
        guard let item = await BangumiAPI.info(id: bangumiID) else { return }
        library.backfillHistoryMeta(
            bangumiID: bangumiID,
            name: item.displayName,
            imageURL: item.largeImage
        )
    }
}
