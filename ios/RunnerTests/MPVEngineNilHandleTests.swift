//
//  MPVEngineNilHandleTests.swift
//  RunnerTests
//
//  回归：EXC_BAD_ACCESS / SIGSEGV at 0x48（mpv_get_property 里解引用 NULL handle）。
//
//  崩溃栈是 PiPFrameCopier.requestCapture 的异步任务 → captureRawFrameForPictureInPicture
//  → stringProperty("hwdec-current") → mpv_get_property。播放页退场时引擎已经 stop()，
//  handle 被 mpv_terminate_destroy 后设成 nil，但这个挂起的 Task 还会恢复；
//  libmpv 的 C API 不接受 NULL，Swift 导入成 Optional 所以编译期一声不吭。
//
//  前两条用例锁住「没有内核时所有读/写属性与取帧入口都安全返回」，第二条尤其要跨过
//  2 秒的诊断门槛：旧实现正是在那里读 stringProperty 崩掉的。第三条锁住代数判定：
//  同一个引擎 stop() 后又 start() 时，handle 重新非 nil，但迟到任务仍不能继续。
//

import Testing
@testable import Runner

@MainActor
struct MPVEngineNilHandleTests {
    @Test func 未启动的内核读写属性不会崩() {
        let engine = MPVEngine()
        #expect(engine.currentTimePosition == nil)
        #expect(engine.playableTime == 0)
        #expect(engine.appliedShaderCount() == 0)
        #expect(engine.playbackInfo() == PlaybackInfo())
        // 旧实现会在 mpv_set_property(NULL, …) 里崩。
        engine.setSpeed(1.5)
        let timing = engine.pictureInPictureTiming()
        #expect(timing.time == 0)
        #expect(timing.paused)
    }

    @Test func 取帧任务恢复时内核已销毁不会崩() async throws {
        let engine = MPVEngine()
        // 第一次取帧：拿不到帧，记下「开始缺帧」的时间。
        let first = await engine.captureRawFrameForPictureInPicture()
        #expect(first == nil)
        // 等过 2 秒的诊断门槛，再让那个迟到的任务恢复。
        try await Task.sleep(for: .seconds(2.1))
        let second = await engine.captureRawFrameForPictureInPicture()
        #expect(second == nil)
    }

    @Test func 换过内核的迟到取帧任务不再继续() {
        #expect(
            MPVEngine.shouldContinuePictureInPictureCapture(
                hasHandle: true, entryGeneration: 3, currentGeneration: 3
            )
        )
        #expect(
            !MPVEngine.shouldContinuePictureInPictureCapture(
                hasHandle: false, entryGeneration: 3, currentGeneration: 3
            )
        )
        // stop() → start() 之后 handle 又是非 nil，但代号已经变了。
        #expect(
            !MPVEngine.shouldContinuePictureInPictureCapture(
                hasHandle: true, entryGeneration: 3, currentGeneration: 4
            )
        )
    }
}