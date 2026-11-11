//
//  SkipSegmentSeekTargetTests.swift
//  RunnerTests
//
//  AniSkip 的跳点：跳到哪儿必须**正好**是接口给的 endTime，不许带任何偏移
//  （差一点就会「没到时间就提前到了」）。这里锁住弹窗状态机算出来的 seek 目标。
//

import Testing
@testable import Runner

@MainActor
struct SkipSegmentSeekTargetTests {
    /// 片头 12.5–102.75 秒（AniSkip 给的就是这种带小数的值）。
    private func makeModel() -> SkipSegmentPillModel {
        let model = SkipSegmentPillModel()
        model.isPlaybackReady = true
        model.duration = 1440
        model.segments = SkipSegments(
            opening: SkipRange(start: 12.5, end: 102.75, source: .aniskip),
            ending: nil
        )
        return model
    }

    @Test func 自动跳的落点就是 aniskip 的 end() {
        let model = makeModel()
        model.position = 8
        model.update()
        #expect(model.isVisible)

        model.position = 12.5
        model.update()
        #expect(model.consumeSeekTarget() == 102.75)
    }

    @Test func 手动点跳过落点也是 end() {
        let model = makeModel()
        model.position = 8
        model.update()
        #expect(model.isVisible)

        model.skipNow()
        #expect(model.consumeSeekTarget() == 102.75)
    }

    @Test func 撤销跳回 start() {
        let model = makeModel()
        model.position = 8
        model.update()
        model.position = 12.5
        model.update()
        #expect(model.consumeSeekTarget() == 102.75)

        model.undo()
        #expect(model.consumeSeekTarget() == 12.5)
    }

    @Test func 没到提前量之前不跳也不弹() {
        let model = makeModel()
        model.position = 5
        model.update()
        #expect(model.isVisible == false)
        #expect(model.consumeSeekTarget() == nil)
    }
}
