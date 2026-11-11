//
//  PlayerSurfaceModel.swift
//  Kazumi
//
//  播放画面对外暴露的状态与控制入口。原来住在 MPVPlayerContainer.swift 里——那份文件
//  是 UIView + 弹幕叠层，macOS 用不上；模型这一段一行 UIKit 都没有，拆出来两边共用。
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayerSurfaceModel {
    var currentTime: Double = 0
    var duration: Double = 0
    /// 已缓冲到的时间点（相对视频开头），进度条据此画出缓冲段。
    var bufferedTime: Double = 0
    var isPlaying = false
    /// 用户想让它在播（而不是自己按了暂停）。
    ///
    /// 只看内核状态会把「缓冲中」当成「暂停」：mpv 一卡 `core-idle` 就是 true，
    /// 界面立刻换成暂停图标、还把控制栏弹回来（LP 2026-10-29 第 1、2 条：
    /// 「解决不了就不要显示暂停，加个加载中符号」）。
    /// 所以内核没走的时候要再分一步：是用户按停的（`pause`），还是没跟上（idle 但没暂停）。
    private(set) var wantsPlaying = false
    /// 内核最后一次报的 pause。系统中断、退后台这些外部暂停走它，不是用户按的。
    private(set) var corePaused = false
    /// 内核最后一次报的 idle：没暂停却没在走，就是缓冲被打空（underrun）。
    private(set) var coreIdle = false
    /// 正在缓冲 / 卡住：想播、没在播、内核也没被暂停。界面用它显示加载符号，
    /// 而不是暂停图标和控制栏。
    /// 缓冲/等数据：想播、没暂停、内核却在 idle。
    ///
    /// 原来写成 `wantsPlaying && !isPlaying && !corePaused`，但「没暂停却没走」那档会把
    /// `isPlaying` 设成 true，条件永远不成立——登录源播到一半一顿一顿、加载圈却从不出来
    /// （LP 5536 的日志里「暂停=否 空闲=是」反复出现）。改用 `coreIdle` 判断（Fuck 5538）。
    var isStalled: Bool { wantsPlaying && !corePaused && coreIdle }
    var isReady = false
    /// 这一集的第一帧是不是已经画上屏了。
    var hasFirstFrame = false
    /// 「起播稳定」（首帧之后又过了 0.15 秒）那一刻的回调，每次加载只发一次。
    ///
    /// 播放页拿它做「起播后把嗅探用的 WebView 放掉」（LP 4938 Step 2）。挂在这里而不是
    /// SwiftUI 的 `.onChange` 上，是因为播放页那串 modifier 已经长到编译器的类型检查
    /// 会超时（「unable to type-check in reasonable time」），往里再塞一个闭包就编不过。
    /// 同上：只在内核回调里被调用，界面不靠它刷新，写它不该触发重画。
    @ObservationIgnored var onPlaybackStarted: (() -> Void)?
    /// 这一集是不是已经报过「起播稳定」了；换集 / 重新加载时清掉，下一集再报一次。
    private var didReportPlaybackStarted = false
    /// 时间轴真的走起来了（第一帧之后又过了 0.15 秒）。
    ///
    /// 加载符号收到这里为止，不是收到 `hasFirstFrame`（LP 4810）：第一帧画上屏之后
    /// 还要等音画对齐、时钟起跳，中间那一小段画面是黑的——圈先收了，人就在那儿干等。
    private(set) var hasStartedPlayback = false
    /// 当前下载速度（字节/秒），加载符号下面那行网速。平滑过，不然一秒跳四个数字。
    private(set) var downloadSpeed: Double = 0
    /// 内核正在 seek（拖进度、换集）。
    private(set) var isSeeking = false
    /// 上一帧内核报的 `pause` / `core-idle`：只在真的变了的时候写一行日志。
    private var lastCorePaused = false
    private var lastCoreIdle = false
    /// 缓冲段刷新的节拍：状态快照 4Hz，这里 1Hz 就够。
    private var bufferedRefreshTick = 0
    /// 这次加载走到哪一步（由 mpv 事件推，见 `MPVLoadPhase`）。
    private(set) var loadPhase: MPVLoadPhase = .idle

    /// 首帧还没出来 / 刚换集：加载圈该转。
    ///
    /// 判据只看引擎一路推过来的相位，不看「首帧到了」那个标记：那个通知是一次性的
    /// （首份视频参数快照只发一次），而换集时界面这边会把标记清掉，两件事谁先谁后不定
    /// ——清理落在通知之后就再也回不来，画面在放也照样转圈（Ato 4867，模拟器上切集
    /// 复现过）。相位由 `MPV_EVENT_START_FILE / FILE_LOADED / PLAYBACK_RESTART` 和
    /// 时间轴推进一起推，不依赖一次性回调。
    ///
    /// 「有画面、用户自己暂停着」还是放行：那时画面已经在了，不该拿圈盖住它。
    var isLoadingFirstFrame: Bool {
        switch loadPhase {
        case .opening, .awaitingFirstFrame:
            if hasFirstFrame, corePaused { return false }
            return true
        case .idle, .playing:
            return false
        }
    }
    var errorMessage: String?
    /// 视频的像素尺寸；还没拿到时是 .zero，布局回落到整块画面。
    var videoSize: CGSize = .zero

    /// 内核引用。**不参与 Observation**（LP 2026-11-08 第 1 条）。
    ///
    /// `MPVPlayerContainer.updateUIView` 每次 SwiftUI 更新都会调 `attach(engine:)`
    /// 把它写一遍；而 representable 的更新闭包本身就在观察范围内——崩溃日志里
    /// `PlatformViewChild.updateValue` → `ObservationCenter.invalidate` →
    /// `_installTracking` 那条栈就是它。写一次就让自己失效，SwiftUI 再更新一次、
    /// 再写、再失效：主线程永远出不来（表现是「卡在正在解析播放地址 / 点不动也退不出去」，
    /// 退后台 5 秒收不掉进程被 watchdog 杀掉）。
    /// 界面渲染不靠它（只用它在按钮里取引擎做动作），标掉最安全。
    @ObservationIgnored weak var engine: MPVEngine?

    /// loadID 只在同一个 mpv 内核里单调递增；换内核时从 0 重新认领。
    func attach(engine newEngine: MPVEngine?) {
        // 同一个内核就别写：写空值也算一次变更，见上面 `engine` 的注释。
        guard engine !== newEngine else { return }
        activeLoadID = 0
        engine = newEngine
    }

    /// 弹幕画布：横屏底栏「发弹幕」往这里补一条自己发的。
    /// 同上，`makeUIView` 里会写它，别让它参与 Observation。
    @ObservationIgnored weak var danmakuOverlay: DanmakuOverlayView?

    /// 期望的播放速率。换集 / 起播后会回到 1.0，因此就绪时要按这个值再补一次。
    var desiredRate: Float = 1.0

    /// 进入播放器时待恢复的进度：就绪后只 seek 一次，
    /// 避免抢在加载完成前 seek，结果被内核回落到 0。
    var pendingResumeTime: Double?

    /// 正常播完（非出错）时的回调，交给页面处理自动连播。
    /// 回调只被内核/页面调用，界面不靠它刷新：同样标掉，避免在视图更新期写它就自我失效。
    @ObservationIgnored var onFinish: (@MainActor (PlayerSurfaceModel) -> Void)?
    /// 断流自愈的重试请求；由容器接到 MPVEngine 的当前源重载。
    /// 返回 false 表示引擎压根没提交（本地文件、没有当前源、命令下发失败），
    /// 模型不能因此消耗恢复额度或清掉就绪状态。
    /// 同上：`makeUIView` 里会写它，写进去不需要重画任何视图。
    @ObservationIgnored var onRecoverFromStall: (@MainActor (Double) -> Bool)?
    /// 已起播后，真实进度上次推进的时刻（单调时钟，系统校时 / 休眠都不影响）。
    @ObservationIgnored private var lastRealProgressAt: TimeInterval = 0
    @ObservationIgnored private var lastRealProgressTime = 0.0
    @ObservationIgnored private var lastRecoveryRequestAt: TimeInterval = 0
    @ObservationIgnored private var recoveryRequestCount = 0
    @ObservationIgnored private var recoveryLatchArmed = false
    @ObservationIgnored private var recoveryBaselineTime = 0.0
    @ObservationIgnored private var ignoreProgressAfterSeek = false
    @ObservationIgnored private var activeLoadID: UInt64 = 0
    private static let stallRecoveryDelay: TimeInterval = 8
    private static let stallRecoveryCooldown: TimeInterval = 20
    private static let stallRecoveryLimit = 3
    @ObservationIgnored
    var nowProvider: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// 这一集加载完就该自己开播（LP 2026-10-28 第 3 条）。
    ///
    /// `MPVEngine.load()` 里已经在 `loadfile` 之前放开了 pause，但 mpv 换文件时
    /// 会把 pause 重新按选项值设一次，所以那条时序靠不住：实测加载完就停着，手点一下才走。
    /// 于是在「第一帧到手」那一刻再补一次 `play()`——只补一次，用户随手暂停就作废。
    private var autoPlayPending = false

    /// 这一集已经报过「播完」了。
    ///
    /// `eof-reached` 会一直为真，直到下一条 `loadfile` 才消失；状态回调却每 250ms 来一次。
    /// 没有这把闩，同一次片尾会被重复收尾：自动连播那边会重复派发选集任务，
    /// 关掉连播时观看进度也会每个 tick 重写一次。换集时由 `prepareForNewEpisode()` 复位。
    private var finishReported = false

    /// 需要在播放区浮现的临时提示（首 / 末集提示等）；页面渲染并在 2 秒后清空。
    var toastMessage: String?

    /// 摆在画面 1/4 那条线上的提示（LP 4668）：倍速、收藏状态、定时关闭这些
    /// 「动作结果」都跟长按倍速指示器同一条线，不再挤在屏幕最顶上。
    /// 顶部那条留给说明性的话（弹幕、错误、同步进度）。
    var hudToastMessage: String?

    func play() {
        autoPlayPending = false
        wantsPlaying = true
        engine?.play()
        isPlaying = true
        applyDesiredRate()
    }

    func pause() {
        // 用户自己按的暂停：起播后那次补播不能再把它拉起来。
        autoPlayPending = false
        wantsPlaying = false
        engine?.pause()
        isPlaying = false
    }

    /// 后台渲染锁（原因见 `MPVEngine.setRenderingLocked`）。
    /// 画中画在跑的时候不要上锁：它的帧正是靠这条渲染路径出的。
    func setRenderingLocked(_ locked: Bool) {
        engine?.setRenderingLocked(locked)
    }

    /// 抓当前这一帧（截图）。mpv 的 `screenshot-raw` 直接给解码后的原始帧，
    /// 再退一步才让 VO 出 PNG；`CAMetalLayer` 的 drawable 不能被 CPU 截取。
    ///
    /// 返回 `(文件, 给用户看的那句话)`：文件在就交给相册那条路存。
    func captureFrame() async -> (url: URL?, note: String) {
        guard let engine else { return (nil, "截图失败：播放器还没准备好") }
        return await engine.captureFrameToFile()
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        noteSeekDiscontinuity(to: time)
        onPlaybackDiscontinuity?(time, corePaused)
        engine?.seek(to: time)
        currentTime = time
    }

    /// 主动 seek 让媒体时间轴跳变；先把看门狗基线挪到落点，
    /// 下一拍非 seeking 快照再吃掉这次跳变，避免向前跳被当成真实推进。
    private func noteSeekDiscontinuity(to time: Double) {
        lastRealProgressAt = nowProvider()
        lastRealProgressTime = time
        recoveryBaselineTime = time
        ignoreProgressAfterSeek = true
    }

    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        desiredRate = rate
        engine?.setSpeed(rate)
    }

    /// 只在正在播放时补速率，避免暂停时被拉起来。
    private func applyDesiredRate() {
        guard isPlaying else { return }
        engine?.setSpeed(desiredRate)
    }

    /// 快进指定秒数：已知总时长时夹在时长内，未知时就按当前时间往后加。
    func skipForward(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        let target = duration > 0
            ? min(duration, currentTime + seconds)
            : currentTime + seconds
        seek(to: target)
    }

    /// 从内核读一次已缓冲位置（进度条的缓冲段用）；读不到就保持原值。
    func refreshBufferedTime() {
        guard let engine else { return }
        let value = engine.playableTime
        guard value.isFinite, value > 0 else { return }
        bufferedTime = value
    }

    /// 当前文件的编码规格（「播放信息」半屏页用）。引擎还没建好时返回 nil。
    func playbackInfo() -> PlaybackInfo? {
        engine?.playbackInfo()
    }

    /// mpv 现在真正挂着的着色器个数（0 就是没挂上）。
    func appliedShaderCount() -> Int {
        engine?.appliedShaderCount() ?? 0
    }

    /// 关闭播放器：先停内核再断引用。
    func stop() {
        engine?.stop()
        engine = nil
        isPlaying = false
        wantsPlaying = false
    }

    func markWantsPlaying() {
        wantsPlaying = true
    }

    /// PiP 时基重锚钩子。所有 seek（拖动 / 续播 / 快进 / PiP 跳过）和断流原位重连
    /// 都经过这里，避免只有 PiP 自己按「跳过」时才知道时基要重置。
    @ObservationIgnored var onPlaybackDiscontinuity: (@MainActor (Double, Bool) -> Void)?

    /// 内核推来的一帧状态。
    func handle(snapshot: MPVSnapshot) {
        if snapshot.loadID != activeLoadID {
            activeLoadID = snapshot.loadID
            hasFirstFrame = false
            hasStartedPlayback = false
            didReportPlaybackStarted = false
            isReady = false
            loadPhase = .opening
            autoPlayPending = wantsPlaying
        }
        currentTime = max(0, snapshot.time)
        if snapshot.duration.isFinite, snapshot.duration > 0 {
            duration = snapshot.duration
        }
        // 内核没在走有三种：正在缓冲/卡住（idle 但没暂停）、被暂停（用户或系统）、
        // 还没起播。只有第二种才算暂停，第一种要留给界面转加载圈。
        corePaused = snapshot.isPaused
        isSeeking = snapshot.isSeeking
        // 内核自己停下来（或者自己进 idle）也要留一行：真机上「回前台停着、
        // 又不转圈」这种，圈不转就说明 `isStalled` 是 false，也就是内核的
        // `pause` 或 `idle` 为真——而这两件事都不是我们主动做的。
        // 只在真的变的时候写，不会刷屏。
        if snapshot.isPaused != lastCorePaused || snapshot.isIdle != lastCoreIdle {
            KazumiLogBuffer.player(
                "内核：暂停=\(snapshot.isPaused ? "是" : "否") 空闲=\(snapshot.isIdle ? "是" : "否") t=\(snapshot.time)"
            )
            lastCorePaused = snapshot.isPaused
            lastCoreIdle = snapshot.isIdle
        }
        if snapshot.loadPhase != loadPhase {
            // 这行留着：加载圈不转 / 一直转、起播该做的事没做，先看相位走到哪一步了。
            KazumiLogBuffer.player("相位 \(loadPhase) → \(snapshot.loadPhase) t=\(snapshot.time)")
            // 新的一次加载开始（换集 / 重新加载 / 换源）：首帧那套状态清掉，
            // 圈重新转。seek 不经过这里（相位还是 playing），所以不会误触发
            // 首帧逻辑（LP 4818 第 7 条）。
            if snapshot.loadPhase == .opening {
                hasFirstFrame = false
                hasStartedPlayback = false
                didReportPlaybackStarted = false
            }
            loadPhase = snapshot.loadPhase
        }
        // 首帧判据以内核相位为准，别依赖引擎那条一次性回调：回调没轮到
        // 就永远不算首帧（实测就是这样，画面明明在跑却触发不了）。
        // 相位推进本身就要求「帧画过了」或「time-pos 真的在走」（LP 4820）。
        if !hasFirstFrame, snapshot.loadPhase == .playing, snapshot.freshVideoParams {
            hasFirstFrame = true
        }
        // 网速平滑一下：mpv 报的是瞬时值，直接显示就是每 250ms 乱跳的数字。
        // 掉到 0 时直接归零，别让「已经不下载了」还挂着上一个速度。
        //
        // 这里**只看有没有网络输入**，不按 `core-idle` 归零：缓冲中（等缓存填、
        // 网卡住）内核本来就是 idle，可那正是用户最想看网速的时候，按 idle 归零
        // 会让「正在缓冲…」下面那行速度直接消失（LP 2026-11-08 第 2 条）。
        // 真断流时 `raw-input-rate` 自己会掉到 0，不需要额外兜。
        if snapshot.downloadSpeed > 0 {
            downloadSpeed = downloadSpeed > 0
                ? downloadSpeed * 0.6 + snapshot.downloadSpeed * 0.4
                : snapshot.downloadSpeed
        } else {
            downloadSpeed = 0
        }
        if hasFirstFrame, snapshot.time > 0.15 {
            hasStartedPlayback = true
            // 只报一次：这条回调是「该做一件事了」的信号，不是每帧的状态。
            if !didReportPlaybackStarted {
                didReportPlaybackStarted = true
                // 这行留着：真机上「起播后该做的事没做」时，先看它有没有出来，
                // 再看括号里回调在不在（挂载点写错时这里是「没有」）。
                KazumiLogBuffer.player(
                    "起播稳定 t=\(snapshot.time) 回调=\(onPlaybackStarted == nil ? "没有" : "在")"
                )
                onPlaybackStarted?()
            }
        }
        let coreRunning = !snapshot.isPaused && !snapshot.isIdle
        if coreRunning {
            isPlaying = true
        } else if snapshot.isPaused {
            isPlaying = false
        } else {
            // 没暂停却没走：意图还在就仍然算「在播」（画中画、正在播放都用这个口径）。
            // 缓冲那一下由 `coreIdle` + `isStalled` 单独表达，不改 `isPlaying`（Fuck 5538）。
            isPlaying = wantsPlaying
        }
        // 内核「没暂停但也没在走」= 缓冲/等数据。`isStalled` 靠它算，
        // 不能靠 `isPlaying`：上面那一档会把缓冲态的 isPlaying 也设成 true。
        coreIdle = snapshot.isIdle
        evaluateStallRecovery(snapshot: snapshot)
        if snapshot.videoWidth > 0, snapshot.videoHeight > 0 {
            let size = CGSize(width: snapshot.videoWidth, height: snapshot.videoHeight)
            if videoSize != size { videoSize = size }
        }
        // 缓冲段不需要跟着 4Hz 的状态快照走：每 4 拍读一次 mpv 属性就够，
        // 少一次主线程的同步属性查询，播放中更不容易被 UI 抢时间。
        bufferedRefreshTick &+= 1
        if bufferedRefreshTick % 4 == 0 {
            refreshBufferedTime()
        }
        // 只有当前 loadID 的新文件视频参数才允许把界面置为就绪、补一次 play()。
        // 旧文件残留的 hasVideo 不能消耗 autoPlayPending，也不能把缓存提前拉到 36000 秒。
        if snapshot.freshVideoParams {
            if !isReady, autoPlayPending {
                autoPlayPending = false
                // 用户在命令下发后按了暂停就作废，不再把内核拉起来。
                if wantsPlaying {
                    engine?.play()
                    isPlaying = true
                }
            }
            isReady = true
            errorMessage = nil
        } else if let loadError = snapshot.loadError {
            // 源挂了 / 404 / 403：不留一块黑屏装死，把原因说给用户。
            errorMessage = loadError
        }
        if isReady {
            applyPendingResume()
        }
        if snapshot.ended {
            handleFinish(errorMessage: nil)
        } else if finishReported {
            // 播完之后又被拖回中段重看：这一集的「已报播完」放开，再走到结尾还能再收尾一次。
            // 只在确实离开片尾时复位，避免 eof 抖一下就重复收尾。
            if duration <= 0 || snapshot.time < duration - 3 {
                finishReported = false
            }
        }
    }

    /// 真正的 HLS 断流会停在 core-idle：mpv 的 time-pos 几乎不动。
    /// 自动画中画即使尚未实际开启，其前台预热同步器也可能继续假推进。
    /// 这里只认内核时间轴；连续 8 秒没前进 0.75 秒且网络输入低于 1 KiB/s，
    /// 才请求容器用新连接重载当前地址。用户暂停或仍在正常下载时不触发。
    private func evaluateStallRecovery(snapshot: MPVSnapshot) {
        let now = nowProvider()

        guard wantsPlaying, hasFirstFrame, loadPhase == .playing,
              !snapshot.isPaused, !snapshot.isSeeking, snapshot.time.isFinite,
              snapshot.duration.isFinite,
              snapshot.duration <= 0 || snapshot.time < snapshot.duration - 3
        else {
            // 暂停、seek、片尾、未起播都算断点：基线挪到当前位置重新计时，
            // 同时放开闩锁——否则暂停/拖动回来后这一次自愈永远等不到第二次。
            disarmStallRecovery(at: snapshot.time, now: now)
            return
        }

        // 第一拍、主动 seek 后的第一拍、或媒体时间轴大幅跳变：只重置基线，
        // 不把跳变本身当成「真实推进」。ignoreProgressAfterSeek 在这里才消费掉。
        if lastRealProgressAt == 0 || ignoreProgressAfterSeek
            || abs(snapshot.time - lastRealProgressTime) > 8 {
            lastRealProgressAt = now
            lastRealProgressTime = snapshot.time
            recoveryBaselineTime = snapshot.time
            ignoreProgressAfterSeek = false
            return
        }

        // 先判真实推进，再看网络输入：以前网络输入那条早返回会挡住基线更新，
        // 断流期间只要报过一次 ≥1 KiB/s，进度基线就永远停在旧值。
        if snapshot.time >= lastRealProgressTime + 0.75 {
            lastRealProgressAt = now
            lastRealProgressTime = snapshot.time
            if recoveryLatchArmed, snapshot.time >= recoveryBaselineTime + 2 {
                recoveryLatchArmed = false
            }
            return
        }

        if snapshot.time < lastRealProgressTime - 1 {
            lastRealProgressAt = now
            lastRealProgressTime = snapshot.time
            recoveryBaselineTime = snapshot.time
            return
        }

        // 内核还在跑 / demuxer 还有输入：这一拍不是闲置，停摆时钟不累积。
        if !snapshot.isIdle || snapshot.downloadSpeed >= 1_024 {
            lastRealProgressAt = now
            return
        }

        guard !recoveryLatchArmed,
              snapshot.isIdle,
              now - lastRealProgressAt >= Self.stallRecoveryDelay,
              (recoveryRequestCount == 0
               || now - lastRecoveryRequestAt >= Self.stallRecoveryCooldown),
              recoveryRequestCount < Self.stallRecoveryLimit
        else { return }

        let submitted = onRecoverFromStall?(max(0, snapshot.time)) ?? false
        guard submitted else {
            // 引擎没接这次恢复：不消耗额度、不解闩锁，只按冷却退避，等条件变化再说。
            lastRecoveryRequestAt = now
            recoveryBaselineTime = snapshot.time
            KazumiLogBuffer.player("HLS 进度停住，但引擎未接受重连 t=\(snapshot.time)")
            return
        }
        lastRecoveryRequestAt = now
        recoveryRequestCount += 1
        recoveryLatchArmed = true
        recoveryBaselineTime = snapshot.time
        lastRealProgressAt = now
        KazumiLogBuffer.player("HLS 进度停住，请求原地重连 t=\(snapshot.time)")
    }

    /// 离开「想播、在播、未到片尾」这条路径时统一收口，避免恢复闩锁永久停住。
    private func disarmStallRecovery(at time: Double, now: TimeInterval) {
        lastRealProgressAt = now
        lastRealProgressTime = time
        recoveryBaselineTime = time
        recoveryLatchArmed = false
        ignoreProgressAfterSeek = false
    }

    /// 播放结束（正常播完或出错）的收尾。
    /// 出错只报错；只有确实播到结尾才清播放意图并触发 `onFinish`。
    ///
    /// `eof-reached` 在 HLS 中途断流 / 重连时也可能短暂出现。以前这里先把
    /// `wantsPlaying` 清掉、再判断是不是片尾；于是后续 `core-idle` 虽然为真，
    /// `isStalled` 也永远为假，界面就只剩反复停顿而没有加载圈。
    func handleFinish(errorMessage: String?) {
        if let errorMessage {
            isPlaying = false
            wantsPlaying = false
            isReady = false
            self.errorMessage = errorMessage
            return
        }
        guard duration > 0, currentTime >= duration - 3 else { return }
        guard !finishReported else { return }
        finishReported = true
        isPlaying = false
        wantsPlaying = false
        isReady = false
        onFinish?(self)
    }

    /// 切换分集前清掉上一集的展示状态，避免旧的时长 / 进度闪一下。
    func prepareForNewEpisode() {
        // 新的一集还没播完：把上一集的收尾闩放开。
        finishReported = false
        // 这一集就绪后应该自己开播（见 `autoPlayPending`）。
        autoPlayPending = true
        wantsPlaying = true
        currentTime = 0
        duration = 0
        bufferedTime = 0
        isReady = false
        hasFirstFrame = false
        hasStartedPlayback = false
        isSeeking = false
        downloadSpeed = 0
        pendingResumeTime = nil
        errorMessage = nil
        lastRealProgressAt = 0
        lastRealProgressTime = 0
        lastRecoveryRequestAt = 0
        recoveryRequestCount = 0
        recoveryLatchArmed = false
        recoveryBaselineTime = 0
        ignoreProgressAfterSeek = false
        // 保留上一条实际 loadID；beginLoad 的 .opening 快照仍带它，直到
        // START_FILE 发来新编号。清成 0 反而会把旧编号误判为一次新加载。
        // 换集先清尺寸：新的一集分辨率可能不同，拿到之前回落到整块画面。
        videoSize = .zero
    }

    /// 断流原位重连前重新武装首帧补播；不换集，所以保留重试次数与冷却。
    func prepareForPlaybackRestart() {
        guard wantsPlaying else { return }
        autoPlayPending = true
        hasFirstFrame = false
        hasStartedPlayback = false
        didReportPlaybackStarted = false
        isReady = false
        loadPhase = .opening
        downloadSpeed = 0
        // 原位重连的 start=<time> 几乎不让媒体时间跳变，PiP 不会触发跳变兜底；
        // 这里直接告诉它重锚一次，别让小窗抱着上一轮的 PTS / host time。
        onPlaybackDiscontinuity?(currentTime, corePaused)
        lastRealProgressAt = nowProvider()
        lastRealProgressTime = currentTime
        ignoreProgressAfterSeek = false
    }

    func updateTime(current: Double, total: Double) {
        currentTime = max(0, current)
        if total.isFinite, total > 0 {
            duration = total
        }
    }

    /// 就绪后恢复一次待续播位置；太短或落在结尾 5 秒内（视为已看完）就丢掉。
    private func applyPendingResume() {
        guard let resume = pendingResumeTime else { return }
        pendingResumeTime = nil
        guard resume > 1 else { return }
        if duration > 0, resume >= duration - 5 { return }
        seek(to: resume)
    }
}

extension PlayerSurfaceModel: PlayerClockProvider {
    var currentPlaybackTime: Double { currentTime }
    var isPlayingNow: Bool { isPlaying }
    var isStalledNow: Bool { isStalled }
}
