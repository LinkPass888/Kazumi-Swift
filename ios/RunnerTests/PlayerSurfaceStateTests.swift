import Foundation
import Testing
@testable import Runner

private func makeSnapshot(
    time: Double,
    duration: Double = 100,
    isPaused: Bool = false,
    isIdle: Bool = false,
    hasVideo: Bool = true,
    ended: Bool = false,
    loadError: String? = nil,
    videoWidth: Double = 0,
    videoHeight: Double = 0,
    downloadSpeed: Double = 0,
    isSeeking: Bool = false,
    loadID: UInt64 = 1,
    freshVideoParams: Bool = true,
    loadPhase: MPVLoadPhase = .playing
) -> MPVSnapshot {
    MPVSnapshot(
        time: time,
        duration: duration,
        isPaused: isPaused,
        isIdle: isIdle,
        hasVideo: hasVideo,
        ended: ended,
        loadError: loadError,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        downloadSpeed: downloadSpeed,
        isSeeking: isSeeking,
        loadID: loadID,
        freshVideoParams: freshVideoParams,
        loadPhase: loadPhase
    )
}

@MainActor
struct PlayerSurfaceStateTests {
    @Test("中途 eof 不清播放意图，idle 仍显示加载状态")
    func transientEOFKeepsStallIntent() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 741,
            duration: 1_425,
            isIdle: true,
            ended: true
        ))

        #expect(model.wantsPlaying)
        #expect(model.isReady)
        #expect(model.isStalled)
    }

    @Test("只有片尾 eof 才收尾并触发自动连播")
    func trueEOFCompletesPlayback() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()
        var finishCount = 0
        model.onFinish = { _ in finishCount += 1 }

        model.handle(snapshot: makeSnapshot(
            time: 1_423,
            duration: 1_425,
            isIdle: true,
            ended: true
        ))

        #expect(!model.wantsPlaying)
        #expect(!model.isReady)
        #expect(!model.isStalled)
        #expect(finishCount == 1)
    }

    @Test("片尾 eof 一直为真也只收尾一次")
    func terminalEOFFinishesOnce() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()
        var finishCount = 0
        model.onFinish = { _ in finishCount += 1 }

        // 状态回调每 250ms 一次，eof-reached 不会自己消失：连喂五次。
        for _ in 0..<5 {
            model.handle(snapshot: makeSnapshot(
                time: 1_424,
                duration: 1_425,
                isIdle: true,
                ended: true
            ))
        }

        #expect(finishCount == 1)
    }

    @Test("拖回中段重看后，再播到结尾还能再收尾一次")
    func replayAfterFinishFinishesAgain() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()
        var finishCount = 0
        model.onFinish = { _ in finishCount += 1 }

        model.handle(snapshot: makeSnapshot(
            time: 1_424,
            duration: 1_425,
            isIdle: true,
            ended: true
        ))
        model.handle(snapshot: makeSnapshot(
            time: 12,
            duration: 1_425,
            isIdle: false,
            ended: false
        ))
        model.handle(snapshot: makeSnapshot(
            time: 1_425,
            duration: 1_425,
            isIdle: true,
            ended: true
        ))

        #expect(finishCount == 2)
    }

    @Test("缓冲中（内核 idle）照样显示网速，网络输入归零才清掉")
    func keepsSpeedWhileBufferingAndClearsOnZeroInput() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()
        model.handle(snapshot: makeSnapshot(
            time: 10,
            isIdle: false,
            downloadSpeed: 512_000
        ))
        #expect(model.downloadSpeed > 0)
        // 等缓存 / 网卡住：内核 idle，但网还在下——这才是用户最想看速度的时刻，
        // 不能因为 idle 就把那行字抹掉（LP 2026-11-08 第 2 条）。
        model.handle(snapshot: makeSnapshot(
            time: 10.1,
            isIdle: true,
            downloadSpeed: 512_000
        ))
        #expect(model.downloadSpeed > 0)
        // 真断流：`raw-input-rate` 报 0，这时才清掉，不挂假速度。
        model.handle(snapshot: makeSnapshot(
            time: 10.2,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(model.downloadSpeed == 0)
    }

    @Test("有播放意图且断流八秒后请求原位恢复")
    func stalledPlaybackRequestsRecovery() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveredAt: [Double] = []
        model.onRecoverFromStall = { recoveredAt.append($0); return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: true,
            downloadSpeed: 0
        ))

        #expect(recoveredAt == [42])
    }

    @Test("主动暂停或仍在下载时不自动重载")
    func pauseAndActiveTransferDoNotRecover() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveryCount = 0
        model.onRecoverFromStall = { _ in recoveryCount += 1; return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 42,
            isPaused: true,
            isIdle: true,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: true,
            downloadSpeed: 32_000
        ))

        #expect(recoveryCount == 0)
    }

    @Test("同一段断流恢复只请求一次，真正重新推进后才会重新武装")
    func stallRecoveryIsOneShotUntilRenewedProgress() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveryCount = 0
        model.onRecoverFromStall = { _ in recoveryCount += 1; return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: false,
            downloadSpeed: 0
        ))
        for _ in 0..<4 {
            now += 21
            model.handle(snapshot: makeSnapshot(
                time: 42,
                isIdle: true,
                downloadSpeed: 0
            ))
        }
        #expect(recoveryCount == 1)

        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 44.1,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 44.1,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveryCount == 2)
    }

    @Test("内核非 idle 的瞬时零速率不累积停摆时长")
    func activeTransferResetsStallClockOnInstantaneousZero() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveryCount = 0
        model.onRecoverFromStall = { _ in recoveryCount += 1; return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 10,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 7
        model.handle(snapshot: makeSnapshot(
            time: 10,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 7
        model.handle(snapshot: makeSnapshot(
            time: 10,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveryCount == 0)

        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 10,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveryCount == 1)
    }

    @Test("向后跳转更新恢复基线，不把旧位置当作恢复落点")
    func backwardSeekUpdatesRecoveryBaseline() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveredAt: [Double] = []
        model.onRecoverFromStall = { recoveredAt.append($0); return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 80,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 80,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveredAt == [80])

        model.seek(to: 20)
        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 20,
            isIdle: false,
            isSeeking: true,
            downloadSpeed: 0
        ))
        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 20,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 20,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveredAt == [80])

        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 22.1,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 21
        model.handle(snapshot: makeSnapshot(
            time: 22.1,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveredAt == [80, 22.1])
    }

    @Test("向前跳转不会被当成真实推进重新武装")
    func forwardSeekDoesNotRearmImmediately() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveredAt: [Double] = []
        model.onRecoverFromStall = { recoveredAt.append($0); return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 42,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveredAt == [42])

        model.seek(to: 80)
        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 80,
            isIdle: false,
            isSeeking: true,
            downloadSpeed: 0
        ))
        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 80,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 80.1,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 9
        model.handle(snapshot: makeSnapshot(
            time: 80.1,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveredAt == [42])

        now += 1
        model.handle(snapshot: makeSnapshot(
            time: 82.2,
            isIdle: false,
            downloadSpeed: 0
        ))
        now += 21
        model.handle(snapshot: makeSnapshot(
            time: 82.2,
            isIdle: true,
            downloadSpeed: 0
        ))
        #expect(recoveredAt == [42, 82.2])
    }

    @Test("恢复遵守冷却且三次后停止自动重试")
    func recoveryRespectsCooldownAndThreeRequestLimit() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveryCount = 0
        model.onRecoverFromStall = { _ in recoveryCount += 1; return true }
        model.prepareForNewEpisode()

        var time = 42.0
        model.handle(snapshot: makeSnapshot(
            time: time,
            isIdle: false,
            downloadSpeed: 0
        ))
        for _ in 0..<4 {
            now += 9
            model.handle(snapshot: makeSnapshot(
                time: time,
                isIdle: true,
                downloadSpeed: 0
            ))
            time += 2.1
            now += 12
            model.handle(snapshot: makeSnapshot(
                time: time,
                isIdle: false,
                downloadSpeed: 0
            ))
        }

        #expect(recoveryCount == 3)
    }

    @Test("旧 loadID 的残留画面不能提前置为就绪")
    func staleLoadSnapshotsDoNotPromoteFirstFrame() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(
            time: 42,
            loadID: 1,
            freshVideoParams: false,
            loadPhase: .opening
        ))
        #expect(!model.isReady)
        #expect(!model.hasFirstFrame)

        model.handle(snapshot: makeSnapshot(
            time: 42,
            loadID: 2,
            freshVideoParams: true,
            loadPhase: .playing
        ))
        #expect(model.isReady)
        #expect(model.hasFirstFrame)
    }

    @Test("原位重连前重新武装首帧补播")
    func recoveryRearmsFirstFrameAutoPlay() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()
        model.handle(snapshot: makeSnapshot(
            time: 42,
            loadID: 1,
            freshVideoParams: true,
            loadPhase: .playing
        ))
        #expect(model.isReady)
        #expect(model.hasFirstFrame)

        model.prepareForPlaybackRestart()
        #expect(!model.isReady)
        #expect(!model.hasFirstFrame)
        #expect(model.loadPhase == .opening)

        model.handle(snapshot: makeSnapshot(
            time: 42,
            loadID: 2,
            freshVideoParams: true,
            loadPhase: .playing
        ))
        #expect(model.isReady)
        #expect(model.hasFirstFrame)
        #expect(model.isPlaying)
    }

    @Test("重连命令后用户暂停会取消首帧补播")
    func pauseAfterRecoveryCancelsAutoPlay() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()
        model.prepareForPlaybackRestart()
        model.pause()

        model.handle(snapshot: makeSnapshot(
            time: 42,
            isPaused: true,
            loadID: 2,
            freshVideoParams: true,
            loadPhase: .playing
        ))

        #expect(!model.isPlaying)
        #expect(!model.wantsPlaying)
        #expect(model.isReady)
    }

    @Test("播放源请求保留完整请求头")
    func playbackRequestKeepsAllHeaders() throws {
        let url = try #require(URL(string: "https://example.com/video.m3u8"))
        let request = MPVPlaybackRequest(
            url: url,
            referer: "https://example.com/",
            userAgent: "Kazumi/3.0.3",
            cookie: "sid=1; token=2"
        )

        #expect(request.url == url)
        #expect(request.referer == "https://example.com/")
        #expect(request.userAgent == "Kazumi/3.0.3")
        #expect(request.cookie == "sid=1; token=2")
    }

    // MARK: - 请求变更分类（第 6 项：同地址只刷新请求头不重开）

    @Test("首次请求按换源处理")
    func firstRequestIsURLChange() throws {
        let url = try #require(URL(string: "https://example.com/a.m3u8"))
        let request = MPVPlaybackRequest(url: url, referer: nil, userAgent: nil, cookie: nil)
        #expect(request.change(from: nil) == .urlChanged)
    }

    @Test("同一地址只换请求头不重开文件")
    func sameURLHeaderRefreshIsHeadersOnly() throws {
        let url = try #require(URL(string: "https://example.com/a.m3u8"))
        let before = MPVPlaybackRequest(
            url: url, referer: nil, userAgent: "Kazumi/3.0.2", cookie: "sid=old"
        )
        let after = MPVPlaybackRequest(
            url: url, referer: "https://example.com/", userAgent: "Kazumi/3.0.3", cookie: "sid=new"
        )
        #expect(after.change(from: before) == .headersOnly)
        #expect(after.change(from: after) == .unchanged)
    }

    @Test("换集时按换源处理")
    func differentURLIsURLChange() throws {
        let first = try #require(URL(string: "https://example.com/a.m3u8"))
        let second = try #require(URL(string: "https://example.com/b.m3u8"))
        #expect(MPVPlaybackRequest(
            url: first, referer: "https://example.com/", userAgent: nil, cookie: nil
        ).change(from: MPVPlaybackRequest(
            url: second, referer: "https://example.com/", userAgent: nil, cookie: nil
        )) == .urlChanged)
    }

    // MARK: - 恢复状态机边界

    @Test("引擎没接受恢复时不消耗额度，后续仍能自愈")
    func engineRejectionDoesNotConsumeQuota() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var attempts: [Double] = []
        var accept = false
        model.onRecoverFromStall = { time in
            attempts.append(time)
            return accept
        }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(time: 42, isIdle: false))
        now += 9
        model.handle(snapshot: makeSnapshot(time: 42, isIdle: true))

        #expect(attempts == [42])
        // 只按冷却退避，额度没动：三次上限仍然可用。
        now += 21
        accept = true
        model.handle(snapshot: makeSnapshot(time: 42, isIdle: true))
        #expect(attempts.count == 2)
        now += 1
        model.handle(snapshot: makeSnapshot(time: 44.1, isIdle: false))
        now += 21
        model.handle(snapshot: makeSnapshot(time: 44.1, isIdle: true))
        #expect(attempts.count == 3)
    }

    @Test("暂停一次后恢复闩锁解除，重新播放再断流能再次自愈")
    func pauseClearsRecoveryLatch() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var attempts: [Double] = []
        model.onRecoverFromStall = { attempts.append($0); return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(time: 42, isIdle: false))
        now += 9
        model.handle(snapshot: makeSnapshot(time: 42, isIdle: true))
        #expect(attempts == [42])
        // 恢复命令下发后没人真的推进时间轴（例如源站已经把这条流关死）：
        // 以前这里闩锁一直闩着，后面再也没机会自愈。
        now += 1
        model.handle(snapshot: makeSnapshot(time: 42, isPaused: true, isIdle: true))
        now += 9
        model.handle(snapshot: makeSnapshot(time: 42, isIdle: true))
        // 冷却还没过，先不算。
        #expect(attempts == [42])
        now += 21
        model.handle(snapshot: makeSnapshot(time: 42, isIdle: true))
        #expect(attempts == [42, 42])
    }

    @Test("网络输入期间的进度推进仍会更新基线")
    func progressBaselineUpdatesWhileNetworkActive() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveredAt: [Double] = []
        model.onRecoverFromStall = { recoveredAt.append($0); return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(time: 42, isIdle: false))
        // 这一段既在下载、又真的往前走了：基线必须挪到 50，不能让旧的 42 卡住。
        now += 5
        model.handle(snapshot: makeSnapshot(time: 50, isIdle: false, downloadSpeed: 512_000))
        now += 1
        model.handle(snapshot: makeSnapshot(time: 50, isIdle: true, downloadSpeed: 0))
        // 断流时间不足 8 秒：不该恢复。
        #expect(recoveredAt.isEmpty)
        now += 9
        model.handle(snapshot: makeSnapshot(time: 50, isIdle: true, downloadSpeed: 0))
        #expect(recoveredAt == [50])
    }

    @Test("拖动与断流重连都会通知画中画重锚时基")
    func seekAndRestartNotifyTimebaseResync() {
        let model = PlayerSurfaceModel()
        var targets: [Double] = []
        model.onPlaybackDiscontinuity = { time, _ in targets.append(time) }
        model.prepareForNewEpisode()
        model.handle(snapshot: makeSnapshot(time: 42, isIdle: false))

        // 主界面拖动、续播、快进都走 seek；PiP 自己按「跳过」也走同一条路。
        model.seek(to: 100)
        // 原位重连的 start=<time> 几乎不让媒体时间跳变，必须显式通知。
        model.prepareForPlaybackRestart()

        #expect(targets == [100, 100])
    }

    @Test("时长未知不影响断流自愈，非法时长不误判")
    func nonFiniteDurationDoesNotBlockRecovery() {
        let unknown = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        unknown.nowProvider = { now }
        var unknownRecoveries = 0
        unknown.onRecoverFromStall = { _ in unknownRecoveries += 1; return true }
        unknown.prepareForNewEpisode()
        unknown.handle(snapshot: makeSnapshot(time: 42, duration: 0, isIdle: false))
        now += 9
        unknown.handle(snapshot: makeSnapshot(time: 42, duration: 0, isIdle: true))
        #expect(unknownRecoveries == 1)

        let invalid = PlayerSurfaceModel()
        var invalidNow: TimeInterval = 1_000
        invalid.nowProvider = { invalidNow }
        var invalidRecoveries = 0
        invalid.onRecoverFromStall = { _ in invalidRecoveries += 1; return true }
        invalid.prepareForNewEpisode()
        invalid.handle(snapshot: makeSnapshot(time: 42, duration: .nan, isIdle: false))
        invalidNow += 9
        invalid.handle(snapshot: makeSnapshot(time: 42, duration: .nan, isIdle: true))
        #expect(invalidRecoveries == 0)
    }

    @Test("片尾附近不触发断流自愈")
    func nearEOFDoesNotRecover() {
        let model = PlayerSurfaceModel()
        var now: TimeInterval = 1_000
        model.nowProvider = { now }
        var recoveryCount = 0
        model.onRecoverFromStall = { _ in recoveryCount += 1; return true }
        model.prepareForNewEpisode()

        model.handle(snapshot: makeSnapshot(time: 1_420, duration: 1_425, isIdle: false))
        now += 9
        model.handle(snapshot: makeSnapshot(time: 1_423, duration: 1_425, isIdle: true))
        #expect(recoveryCount == 0)
    }
}
