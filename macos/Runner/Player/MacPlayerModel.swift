//
//  MacPlayerModel.swift
//  Kazumi (macOS)
//
//  macOS 播放器的状态：直接复用 iOS 那份 `MPVEngine`（mpv + gpu-next / MoltenVK）
//  和 `PlayerSurfaceModel`（缓冲、断流自愈、首帧、进度都在里面），
//  macOS 只补自己缺的那几样：内核音量（这边没有 AVAudioSession）、鼠标键盘操作。
//

import Foundation
import Observation

@MainActor
@Observable
final class MacPlayerModel {
    let engine = MPVEngine()
    let surface = PlayerSurfaceModel()

    /// 当前这一段的标题，界面上显示在顶栏。
    private(set) var title: String?
    /// 一句提示（打开失败、播完），显示在控制条上方。
    private(set) var hint: String?

    private var pendingRequest: MPVPlaybackRequest?
    private var engineStarted = false

    /// mpv 自己的音量（0–100）。iOS 调的是系统音量，macOS 没那套会话，直接走内核。
    var volume: Double = 100 {
        didSet {
            guard volume != oldValue else { return }
            pushVolume()
        }
    }

    /// 播放速度。surface 会记下它，换集之后按同一个值再补一次。
    var speed: Double = 1 {
        didSet {
            guard speed != oldValue else { return }
            surface.setPlaybackRate(Float(speed))
        }
    }

    init() {
        engine.onSnapshot = { [weak self] snapshot in
            self?.surface.handle(snapshot: snapshot)
        }
        engine.onFirstFrame = { [weak self] in
            self?.surface.hasFirstFrame = true
        }
        engine.onLog = { message in
            KazumiLogBuffer.player("mac mpv: \(message)")
        }
        // 断流原位重连：和 iOS 同一套——先确认命令真提交了，再重新武装首帧补播。
        surface.onRecoverFromStall = { [weak self] time in
            guard let self, self.surface.wantsPlaying else { return false }
            guard self.engine.recoverFromStall(at: time) else { return false }
            self.surface.prepareForPlaybackRestart()
            return true
        }
        surface.onFinish = { [weak self] _ in
            self?.hint = "这一段播完了"
        }
    }

    // MARK: - 生命周期

    /// 画面一挂上窗口就把内核建起来：mpv 的 `wid` 要的是这一刻的 CAMetalLayer。
    /// 幂等，SwiftUI 每次更新都会再调一次。
    func attachMetalView(_ view: MPVMetalView) {
        if engineStarted {
            surface.attach(engine: engine)
            return
        }
        engineStarted = true
        // macOS 这边先固定用完整缓存（没有低内存档位的开关，也没有计费网络的概念）。
        engine.applyCacheSize(
            PlaybackCachePolicy.bytes(
                mode: .never,
                isMetered: false,
                isLocalPlayback: pendingRequest?.url.isFileURL ?? false
            )
        )
        engine.start(in: view)
        surface.attach(engine: engine)
        pushVolume()
        surface.setPlaybackRate(Float(speed))
        if let request = pendingRequest {
            pendingRequest = nil
            surface.prepareForNewEpisode()
            engine.load(request)
        }
    }

    func stop() {
        engine.stop()
        surface.attach(engine: nil)
        engineStarted = false
        pendingRequest = nil
        title = nil
        hint = nil
    }

    // MARK: - 起播

    /// 打开一段视频。内核还没建起来就记下来，等画面挂上再 load。
    func open(url: URL, title: String? = nil, referer: String? = nil, userAgent: String? = nil, cookie: String? = nil) {
        self.title = title ?? url.lastPathComponent
        hint = nil
        speed = 1
        surface.prepareForNewEpisode()
        let request = MPVPlaybackRequest(url: url, referer: referer, userAgent: userAgent, cookie: cookie)
        if engineStarted {
            engine.load(request)
        } else {
            pendingRequest = request
        }
    }

    private func pushVolume() {
        let value = Int(max(0, min(100, volume)).rounded())
        engine.setOptionForPlayback("volume", String(value))
    }
}