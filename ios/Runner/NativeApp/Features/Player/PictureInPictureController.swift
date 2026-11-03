//
//  PictureInPictureController.swift
//  Kazumi
//
//  后台自动画中画（设置里的 `backgroundAutoPiP`，默认开启）。
//
//  Metal 的 drawable 归 MoltenVK 所有，无法直接交给 AVSampleBufferDisplayLayer。
//  这里通过 mpv 的 `screenshot-raw` 取解码后的原始帧，转成 CVPixelBuffer 再喂给 PiP。
//
//  设置关掉时这个文件里的对象一个都不会建：没有取帧器、没有 PiP 控制器、
//  没有定时器，行为与加这个功能之前完全一样。
//

import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

/// 负责「什么时候进 / 出画中画」以及和播放页对接的那一层。
///
/// 所有 UI 操作都在主线程；取帧走 mpv 自己的事件线程。
@MainActor
final class PictureInPictureController: NSObject {
    /// 画中画显示的图层。它必须真的挂在窗口里、有非零尺寸，系统才肯让 PiP 起来。
    private let hostView = PiPHostView()
    private var pipController: AVPictureInPictureController?

    /// 把 mpv 的原始帧转成 CVPixelBuffer 并喂给画中画图层。
    private var copier: PiPFrameCopier?

    /// 播放页那只画面模型与引擎（弱引用：播放页拆掉时不拖住它们）。
    private weak var surface: PlayerSurfaceModel?
    private weak var engine: MPVEngine?

    /// 后台时驱动画中画取帧的节拍。
    private var captureTimer: DispatchSourceTimer?

    /// 等 `isPictureInPicturePossible` 变 true 的那次尝试。
    private var startTask: Task<Void, Never>?

    /// 系统已经确认画中画窗口起来了。
    private(set) var isActive = false

    /// 出问题时的日志钩子。
    ///
    /// 以前这里接的是「再写一遍同一条日志」，而 `log()` 自己已经写了一遍，
    /// 于是每条画中画日志都进缓冲两次（真机日志里「取到第一帧」「画中画启动失败」
    /// 「画中画已启动」各两行，看着像绑了两个控制器，其实控制器和图层从头到尾
    /// 只有一份）。现在只留一条出路，这个钩子没人接也照样记。

    /// 「刚要起小窗」那几秒要的续命牌。
    ///
    /// 刚起播就退后台时，音频还没真正跑起来，系统可能当这个 App 没在播放，直接挂起——
    /// 我们那条「等小窗可用」的轮询根本没机会跑，表现就是「刚播放时退出去没有小窗」。
    /// 起小窗期间拿一张后台续命牌，起来之后小窗自己会保活，这张就还回去。
    private var pipBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// 系统能不能在退后台时自己起小窗。跟着播放状态走，见 `ensureController()`。
    var allowsAutoStart = true {
        didSet { pipController?.canStartPictureInPictureAutomaticallyFromInline = allowsAutoStart }
    }

    /// 画中画没起来（设备不支持 / 图层不在窗口 / 系统拒绝）。
    /// 页面据此退回原来的「后台播放」策略，不至于设置开着却没声音也没画面。
    var onFailed: (() -> Void)?

    /// 用户从系统画中画窗口里关掉画面、而 App 还在后台。
    /// 没开「后台继续播放音频」时页面应该把声音停掉，别让黑屏后面继续响。
    var onStoppedInBackground: (() -> Void)?

    private var didReportFailure = false

    // MARK: - 准备

    /// 提前把图层挂进窗口、把取帧钩子装到引擎上。
    ///
    /// 系统的「自动画中画」要求内联内容在切后台**之前**就存在，
    /// 等 `scenePhase == .background` 再临时创建往往来不及（也会让
    /// `isPictureInPicturePossible` 一直是 false）。所以设置开着时在起播后调一次。
    func prepare(engine: MPVEngine?, surface: PlayerSurfaceModel) {
        self.engine = engine
        self.surface = surface
        guard ensureController() else { return }
        attachHostIfNeeded()
        guard let engine else { return }

        // 取帧器认的是「引擎」，不是抄下来的那个 mpv 句柄。
        // 引擎换过（播放页重建 / 内核重启）就整个重建：旧句柄已经随旧内核还回去了，
        // 拿它去 mpv_get_property 就是读一块已经释放的内存——真机切后台那一帧崩在这儿。
        // 取帧器绑定的是旧引擎句柄，一起换掉。
        if let copier, copier.engine !== engine {
            copier.teardown()
            self.copier = nil
        }

        if copier == nil {
            let copier = PiPFrameCopier(
                engine: engine,
                displayLayer: hostView.displayLayer
            )
            copier.onLog = { [weak self] message in
                self?.log(message)
            }
            copier.onVideoAspectChanged = { [weak self] aspect in
                self?.syncHostAspect(aspect)
            }
            self.copier = copier
        }

        // 播放器一打开就开始喂画面（低频），不要等小窗要起了才喂。
        //
        // 原来是「小窗要起的时候才 beginCapture」，于是第一次退后台时图层里一帧都还没有，
        // `isPictureInPicturePossible` 一直是 false，小窗起不来；等那一轮拷过帧之后，
        // 下一次退后台才成功——正好就是「第一次不出、再退出反而出了」。
        beginCapture()
        engine.requestRender()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard pipBackgroundTask == .invalid else { return }
        pipBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "picture-in-picture-start") { [weak self] in
            Task { @MainActor in self?.endBackgroundTaskIfNeeded() }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard pipBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pipBackgroundTask)
        pipBackgroundTask = .invalid
    }

    /// 切后台时调用。返回 false 表示这次没法走画中画，页面应退回原有的后台策略。
    @discardableResult
    func start(engine: MPVEngine?, surface: PlayerSurfaceModel) -> Bool {
        guard surface.isPlaying else {
            log("没有在播放，不起画中画")
            return false
        }
        guard let engine, engine.handle != nil else {
            log("mpv 句柄还没建好，起不了画中画")
            return false
        }
        guard ensureController(), attachHostIfNeeded() else { return false }

        self.engine = engine
        self.surface = surface
        didReportFailure = false
        // 每次都走一遍 prepare：引擎可能已经换过，钩子得装到当前这只上。
        // 取帧器要不要重建由 prepare 自己判断。
        prepare(engine: engine, surface: surface)
        guard copier != nil else {
            log("取帧器没建起来，画中画不可用")
            onFailed?()
            return false
        }

        beginBackgroundTaskIfNeeded()

        // 按节拍主动取帧；取帧本身走 screenshot-raw，不依赖 UIKit 重绘。
        beginCapture()

        // `canStartPictureInPictureAutomaticallyFromInline` 通常会在退后台时自己起；
        // 这里显式再拉一次兜底（自动路径不触发、或系统正处在 app switcher 的过渡里）。
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            // `isPictureInPicturePossible` 要等图层真正上屏、时序稳定后才变 true，
            // 退后台那一刻往往还是 false，所以轮询一小段时间而不是只看一次。
            for attempt in 0..<30 {
                guard !Task.isCancelled, let self, let controller = self.pipController else { return }
                if controller.isPictureInPictureActive { return }
                if controller.isPictureInPicturePossible {
                    controller.startPictureInPicture()
                    return
                }
                if attempt == 29 {
                    self.log("画中画一直不可用（isPictureInPicturePossible = false）")
                    self.finishStopping()
                    self.reportFailure()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return true
    }

    /// 回前台 / 离开播放器时调用：停掉画中画和取帧节拍。
    /// Metal 输出由 mpv 自己维护，回到前台不 seek、不重启。
    func stop() {
        startTask?.cancel()
        startTask = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        finishStopping()
        // 回到前台后继续用低频原始帧维持内联 PiP source。
        beginCapture()
        // 回前台时让 MoltenVK 按当前 drawable 尺寸重新出图，
        // 让画面立刻从 PiP 接回来（位置就是 mpv 当前的同一个时钟）。
        engine?.requestRender()
    }

    /// 彻底拆掉（离开播放器、或设置被关掉）。下次需要时重新建。
    func teardown() {
        startTask?.cancel()
        startTask = nil
        endBackgroundTaskIfNeeded()
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController?.delegate = nil
        pipController = nil
        captureTimer?.cancel()
        captureTimer = nil
        copier?.teardown()
        copier = nil
        hostView.removeFromSuperview()
        isActive = false
        surface = nil
        engine = nil
        onFailed = nil
        onStoppedInBackground = nil
    }

    /// 画中画是否真的在显示（物理按钮 / 系统关闭都算）。
    var isPictureInPictureActive: Bool {
        pipController?.isPictureInPictureActive == true
    }

    // MARK: - 组装

    private func ensureController() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log("这台设备 / 这个系统不支持画中画")
            return false
        }
        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: hostView.displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            // 设置开着才有这个对象；允许系统在退后台时自动起，不用用户手点。
            // 但要跟着「在不在播」走：暂停着退后台不该自己弹出一个小窗
            // （LP 真机上就是暂停状态退出去，小窗自己出来了）。
            controller.canStartPictureInPictureAutomaticallyFromInline = allowsAutoStart
            pipController = controller
        }
        return true
    }

    @discardableResult
    private func attachHostIfNeeded() -> Bool {
        guard hostView.superview == nil else { return true }
        guard let window = Self.keyWindow() else {
            log("找不到窗口，画中画图层没地方挂")
            return false
        }
        // 非零尺寸 + 在窗口里是硬要求；alpha 压到几乎透明并插到最底层，
        // 用户看不到它，但系统仍然认为这是一块可用的内联画面。
        hostView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        hostView.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
        window.insertSubview(hostView, at: 0)
        return true
    }

    /// 内联那块画面的形状改成跟片源同比例。
    ///
    /// 系统起小窗时，先把内联画面那块按它的形状铺开，等第一帧到了再改成片源比例；
    /// 两者不一样就是「顶部黑一截然后恢复」（LP 4711）。内联期间取帧一直跑着，
    /// 所以真退后台时这块早就是对的形状了，系统从第一帧起就不会铺错。
    /// 宽度固定 320（反正是几乎透明的那块），高度按比例算。
    private func syncHostAspect(_ aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0.1, aspect < 10 else { return }
        let width: CGFloat = 320
        let height = max(2, (width / aspect).rounded())
        guard abs(hostView.frame.height - height) > 0.5 else { return }
        hostView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        log("内联画面形状改成 \(Int(width))×\(Int(height))（片源 \(String(format: "%.3f", aspect)):1）")
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    // MARK: - 取帧节拍

    private func beginCapture() {
        copier?.beginCapture()
        guard captureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(33),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.copier?.requestCapture()
            }
        }
        timer.resume()
        captureTimer = timer
    }

    private func finishStopping() {
        startTask?.cancel()
        startTask = nil
        endBackgroundTaskIfNeeded()
        // 只停「自己驱动渲染」的那条节拍；喂帧本身继续留着。
        // 停了它，回前台之后图层就又没有新帧了，下一次退后台照样起不来小窗。
        captureTimer?.cancel()
        captureTimer = nil
        isActive = false
    }

    private func reportFailure() {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailed?()
    }

    private func log(_ message: String) {
        KazumiLogBuffer.player("画中画: \(message)")
    }
}
// MARK: - AVKit 回调

// AVKit 这两个 delegate 在 SDK 里没有标 `@MainActor`，但回调都从主线程来。
// 用 `@preconcurrency` 声明这条一致性：不把整套实现改成 `nonisolated`，
// 也就不会在回调里丢掉主线程隔离（Swift 6 会按 @MainActor 检查）。
extension PictureInPictureController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // 系统自动起 PiP 时不会先走我们的 start()，这里补上取帧节拍。
        beginCapture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
        // 小窗起来了：它自己会保活，续命牌还回去。
        endBackgroundTaskIfNeeded()
        // 小窗真的在显示了才用满帧率；平时低频喂着就够。
        copier?.captureInterval = 1.0 / 30.0
        log("画中画已启动")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        log("画中画启动失败：\(error.localizedDescription)")
        finishStopping()
        reportFailure()
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // 等 didStop 再收：关闭动画期间 sample buffer 还应该能继续进来。
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = false
        // 收回低频：内联播放时不需要 30Hz 的额外拷贝。
        copier?.captureInterval = 1.0 / 2.0
        if UIApplication.shared.applicationState == .background {
            // 用户自己点了画中画窗口的关闭键、App 还在后台：画面没了。
            // 没开后台音频就停声；开着则继续当音频播放器用。
            onStoppedInBackground?()
        }
        finishStopping()
        if UIApplication.shared.applicationState != .background {
            beginCapture()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        // 播放页一直都在（画中画是从它起来的），不需要额外恢复界面。
        completionHandler(true)
    }
}

extension PictureInPictureController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    /// 画中画那条进度条能拖的范围。时长还没拿到时给一个无限范围，
    /// 系统会按直播 / 未知时长处理，而不是画一条 0 秒的假进度。
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let surface, surface.duration.isFinite, surface.duration > 0 else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: surface.duration, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        surface?.isPlaying != true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // 系统窗口里的播放 / 暂停直接落到现有 surface，音频、控制中心、
        // 内联控件看到的都是同一份状态。
        guard let surface else { return }
        if playing {
            surface.play()
        } else {
            surface.pause()
        }
        // 播放 / 暂停状态变了，让系统重新向 delegate 取一次状态。
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 画中画窗口换了大小（用户缩放 / 转屏）。帧固定按源比例送，
        // 由图层缩放，这里不需要重建缓冲。
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let surface else {
            completionHandler()
            return
        }
        let seconds = CMTimeGetSeconds(skipInterval)
        guard seconds.isFinite, seconds != 0 else {
            completionHandler()
            return
        }
        // 不在这里等画面：seek 之后 mpv 出帧，下一拍自己会送过去。
        let target = max(0, surface.currentTime + seconds)
        surface.seek(to: target)
        // 完成回调返回前，时基必须已经反映目标时间；旧帧也要先扔掉，
        // 否则系统会拿旧时间点去画进度条 / 处理下一次快进。
        copier?.prepareForSeek(to: target, paused: !surface.isPlaying)
        pictureInPictureController.invalidatePlaybackState()
        completionHandler()
    }
}

// MARK: - 图层的宿主

/// 里面就是一块 `AVSampleBufferDisplayLayer`。
/// 用 `layerClass` 而不是把 layer 塞进 sublayer：PiP 要的正是这个 view 的根 layer。
private final class PiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass 已经定死，这里的强制转换不会失败。
        layer as! AVSampleBufferDisplayLayer
    }

    init() {
        super.init(frame: .zero)
        // 320×180 是给系统的「内联画面」，不是给用户看的：几乎全透明、放在最底层。
        // 不能 hidden，也不能做成 0×0，否则 PiP 的 content source 不成立。
        // 高度会被 `syncHostAspect` 改成跟片源同比例，别把这里的 180 当准数。
        backgroundColor = .clear
        alpha = 0.01
        isUserInteractionEnabled = false
        let display = displayLayer
        display.videoGravity = .resizeAspect
        display.backgroundColor = UIColor.clear.cgColor
        display.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 原始帧取帧

/// 从 mpv 取解码后的原始帧，转成 `CMSampleBuffer` 喂给画中画图层。
///
/// Metal 的 drawable 归 MoltenVK 所有，不能直接读回；`screenshot-raw` 与窗口、
/// 渲染后端都无关，前台后台拿到的是同一份解码结果。
@MainActor
private final class PiPFrameCopier {
    fileprivate weak var engine: MPVEngine?
    private let displayLayer: AVSampleBufferDisplayLayer

    var onLog: ((String) -> Void)?
    private(set) var isCapturing = false

    /// 两次取帧之间至少隔多久。平时低频喂着，小窗真起来后再提高帧率。
    var captureInterval: Double = 1.0 / 2.0

    /// 片源真实宽高比，用于提前校正 PiP 内联图层的形状。
    var onVideoAspectChanged: ((CGFloat) -> Void)?
    private var lastReportedAspect: CGFloat = 0

    private var controlTimebase: CMTimebase?
    private var formatDescription: CMVideoFormatDescription?
    private var lastPTS = Double.nan
    private var lastCaptureHostTime = 0.0
    private var captureTask: Task<Void, Never>?
    private var didLogFirstFrame = false
    private var didLogFailure = false

    init(engine: MPVEngine, displayLayer: AVSampleBufferDisplayLayer) {
        self.engine = engine
        self.displayLayer = displayLayer
    }

    // MARK: 生命周期

    func beginCapture() {
        isCapturing = true
        displayLayer.flush()
        ensureTimebase()
        if let controlTimebase {
            CMTimebaseSetRate(controlTimebase, rate: 0)
        }
        lastPTS = .nan
        lastCaptureHostTime = 0
    }

    func endCapture() {
        isCapturing = false
        captureTask?.cancel()
        captureTask = nil
        if let controlTimebase {
            CMTimebaseSetRate(controlTimebase, rate: 0)
        }
    }

    func prepareForSeek(to seconds: Double, paused: Bool) {
        displayLayer.flush()
        lastPTS = .nan
        syncTimebase(to: seconds, paused: paused)
    }

    func syncTimebase(to seconds: Double, paused: Bool) {
        guard seconds.isFinite else { return }
        ensureTimebase()
        guard let controlTimebase else { return }
        CMTimebaseSetTime(
            controlTimebase,
            time: CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        )
        CMTimebaseSetRate(controlTimebase, rate: paused ? 0 : 1)
    }

    private func ensureTimebase() {
        guard controlTimebase == nil else { return }
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault,
            masterClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        guard status == noErr, let timebase else {
            logOnce("画中画时基创建失败：\(status)")
            return
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        displayLayer.controlTimebase = timebase
        controlTimebase = timebase
    }

    func teardown() {
        isCapturing = false
        captureTask?.cancel()
        captureTask = nil
        displayLayer.controlTimebase = nil
        controlTimebase = nil
        formatDescription = nil
    }

    // MARK: 取帧

    /// 由播放页的 30Hz 节拍调用；内部按 `captureInterval` 限频并防止重入。
    func requestCapture() {
        guard isCapturing, captureTask == nil, let engine else { return }
        let hostNow = CACurrentMediaTime()
        guard lastCaptureHostTime == 0 || hostNow - lastCaptureHostTime >= captureInterval else {
            return
        }
        lastCaptureHostTime = hostNow
        captureTask = Task { [weak self] in
            guard let self else { return }
            let frame = await engine.captureRawFrameForPictureInPicture()
            self.captureTask = nil
            guard self.isCapturing, let frame else { return }
            self.enqueue(frame)
        }
    }

    private func enqueue(_ frame: MPVRawFrame) {
        guard let engine else { return }
        let (time, paused) = engine.pictureInPictureTiming()
        if paused {
            freezeTimebaseAtLastFrame()
        }
        if paused, lastPTS.isFinite, abs(time - lastPTS) < 0.05 {
            return
        }

        if time.isFinite, lastPTS.isFinite, time + 0.5 < lastPTS {
            displayLayer.flush()
            lastPTS = .nan
        }
        let pts = time.isFinite
            ? max(0, time)
            : (lastPTS.isFinite ? lastPTS + 1.0 / 30.0 : 0)
        if lastPTS.isFinite, pts <= lastPTS {
            return
        }

        let aspect = CGFloat(frame.width) / CGFloat(max(1, frame.height))
        if aspect.isFinite, aspect > 0.1, aspect < 10,
           abs(aspect - lastReportedAspect) > 0.001 {
            lastReportedAspect = aspect
            onVideoAspectChanged?(aspect)
        }

        guard let pixelBuffer = frame.makePixelBuffer() else {
            logOnce("原始帧转 CVPixelBuffer 失败")
            return
        }
        guard let sampleBuffer = makeSampleBuffer(
            pixelBuffer: pixelBuffer,
            presentationTime: pts
        ) else {
            logOnce("CMSampleBuffer 创建失败")
            return
        }

        syncTimebase(to: pts, paused: paused)
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
        lastPTS = pts
        if !didLogFirstFrame {
            didLogFirstFrame = true
            onLog?("取到第一帧 \(frame.width)x\(frame.height)")
        }
    }

    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTime: Double
    ) -> CMSampleBuffer? {
        if formatDescription == nil {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else { return nil }
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(
                seconds: presentationTime,
                preferredTimescale: 600
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        if controlTimebase == nil, let sampleBuffer {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return sampleBuffer
    }

    private func freezeTimebaseAtLastFrame() {
        guard lastPTS.isFinite, let controlTimebase else { return }
        CMTimebaseSetTime(
            controlTimebase,
            time: CMTime(seconds: max(0, lastPTS), preferredTimescale: 600)
        )
        CMTimebaseSetRate(controlTimebase, rate: 0)
    }

    private func logOnce(_ message: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        onLog?(message)
    }
}
