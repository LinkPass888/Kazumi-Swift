import Testing
@testable import Runner

@MainActor
struct PlayerSurfaceStateTests {
    @Test("中途 eof 不清播放意图，idle 仍显示加载状态")
    func transientEOFKeepsStallIntent() {
        let model = PlayerSurfaceModel()
        model.prepareForNewEpisode()

        model.handle(snapshot: MPVSnapshot(
            time: 741,
            duration: 1_425,
            isPaused: false,
            isIdle: true,
            hasVideo: true,
            ended: true,
            loadPhase: .playing
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

        model.handle(snapshot: MPVSnapshot(
            time: 1_423,
            duration: 1_425,
            isPaused: false,
            isIdle: true,
            hasVideo: true,
            ended: true,
            loadPhase: .playing
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
            model.handle(snapshot: MPVSnapshot(
                time: 1_424,
                duration: 1_425,
                isPaused: false,
                isIdle: true,
                hasVideo: true,
                ended: true,
                loadPhase: .playing
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

        model.handle(snapshot: MPVSnapshot(
            time: 1_424, duration: 1_425, isPaused: false, isIdle: true,
            hasVideo: true, ended: true, loadPhase: .playing
        ))
        model.handle(snapshot: MPVSnapshot(
            time: 12, duration: 1_425, isPaused: false, isIdle: false,
            hasVideo: true, ended: false, loadPhase: .playing
        ))
        model.handle(snapshot: MPVSnapshot(
            time: 1_425, duration: 1_425, isPaused: false, isIdle: true,
            hasVideo: true, ended: true, loadPhase: .playing
        ))

        #expect(finishCount == 2)
    }
}
