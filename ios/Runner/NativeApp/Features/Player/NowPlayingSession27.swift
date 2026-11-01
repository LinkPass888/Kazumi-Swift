//
//  NowPlayingSession27.swift
//  Kazumi
//
//  iOS 27 起「正在播放」多了一条路：NowPlaying 框架里的 MediaSession。
//
//  为什么要走这条（Fuck 5597 之后查出来的）：真机 iOS 27 上，控制中心 / 灵动岛 /
//  锁屏那张卡片**点卡片本体不会把 App 叫到前台**（场景、App 生命周期一个回调都没有），
//  而同一张卡上的播放/暂停/上一集/下一集都正常。新接口把会话归属分成两层：
//  `requestToBecomeApplicationPrimary()` 只管本 App 内谁是主会话，
//  `requestToBecomeSystemPrimary()` 才继续申请系统主会话。真机已经证明前一层不够，
//  所以两层都申请；但 SDK 没有「点卡片」回调，也没承诺系统主会话一定负责拉起 App，
//  这仍是一次有明确观测值的真机实验，不把它写成已证明的修复。
//
//  用户拍板：27 用新接口，27 以下用旧的（"那就在27使用新接口，27以下用旧的"）。
//  所以整个文件 `@available(iOS 27.0, *)`，由 `NowPlayingCenter` 在
//  `if #available` 里分支调用；旧路径一个字都没改。
//
//  链接方式：NowPlaying.framework 是 iOS 27 才有的框架，ios/project.yml 里挂的是
//  **弱链接**。强链接会让 iOS 26 的设备在 dyld 阶段就找不到符号、App 直接起不来。
//
//  几个必须知道的点：
//   * MediaSession 没有 `update()`：换内容只能改 representable。所以 representable
//     必须是**引用类型且可观察**（`@Observable`），我们拿着同一个对象改它的
//     `content` / `playbackSnapshot` / `commands`，系统那边才看得到变化。
//   * 释放 MediaSession 就是把这张卡从系统撤掉（Apple 文档：deinit 即移除），
//     所以 `clear()` 只做「放掉引用」。
//   * 两层主会话申请都是 async throws：应用主会话失败就退回旧接口；系统主会话
//     失败只记日志并保留已经可用的应用主会话，不能因为实验失败把卡片一起撤掉。
//

import Foundation

// 整个文件只在 SDK 带 NowPlaying 模块时才参与编译（iOS 27 SDK 起才有）。
// 万一用旧 SDK 构建，`NowPlayingCenter` 拿不到实现，自然一直走旧接口。
// 注意这只是**编译期**的兜底；运行期的 iOS 26 靠的是 project.yml 里的弱链接
// 加 `if #available(iOS 27.0, *)`。
#if canImport(NowPlaying)

import NowPlaying
import Observation

@available(iOS 27.0, *)
@MainActor
final class NowPlayingSessionPublisher: NowPlayingModernPublishing {
    /// 抢主会话失败时的退路，由 `NowPlayingCenter` 接上：它会用旧接口把这一集重写一遍。
    var onFailure: (@MainActor () -> Void)?
    /// 主会话真拿到了：`NowPlayingCenter` 用它把退避计数归零，
    /// 否则中途偶尔失败一次的旧账会一直算到这一场播完。
    var onActive: (@MainActor () -> Void)?

    /// 会话 id 固定不变：同一次播放里换集只换 content，不换会话本身
    /// （换会话就要重新抢一次主会话，既慢又容易失败）。
    private let card = NowPlayingSessionCard()
    /// 遥控键的闭包在 `NowPlayingCenter` 那边（跟旧接口共用同一个盒子），
    /// 这里只借它把 commands 数组造出来。
    private let makeCommands: @MainActor (Bool, Bool) -> [MediaCommand]

    private var session: MediaSession<NowPlayingSessionCard>?
    private var activation: Task<Void, Never>?
    /// 已经拆掉 / 已经失败：之后任何异步回调都不许再动系统状态。
    private var terminated = false
    /// 上一集 / 下一集的可用性。nil = 还不知道（集列表没拉到），保持可用。
    private var nextEnabled: Bool?
    private var previousEnabled: Bool?

    init(makeCommands: @escaping @MainActor (Bool, Bool) -> [MediaCommand]) {
        self.makeCommands = makeCommands
    }

    // MARK: - NowPlayingModernPublishing

    func publish(_ payload: NowPlayingPublishPayload) {
        guard !terminated else { return }

        // 箭头可用性跟着这一次的内容一起来：第一次发卡片时 `setCommandAvailability`
        // 还没人调过，不能等到下个轮询才把「第一集的上一集」置灰。
        applyCommandAvailability(next: payload.nextEnabled, previous: payload.previousEnabled)

        // 只有换了集（或封面终于到了）才重建 content：每 2 秒一次的进度更新
        // 只动 playbackSnapshot，别让系统反复收一份一模一样的内容。
        if payload.rebuildContent || card.content == nil {
            card.content = Self.makeContent(payload)
            card.commands = makeCommands(nextEnabled ?? true, previousEnabled ?? true)
        }
        card.playbackSnapshot = Self.makeSnapshot(payload)

        startSessionIfNeeded()
    }

    func setCommandAvailability(next: Bool?, previous: Bool?) {
        guard !terminated else { return }
        applyCommandAvailability(next: next, previous: previous)
    }

    private func applyCommandAvailability(next: Bool?, previous: Bool?) {
        guard next != nextEnabled || previous != previousEnabled else { return }
        nextEnabled = next
        previousEnabled = previous
        guard card.content != nil else { return }
        card.commands = makeCommands(next ?? true, previous ?? true)
    }

    func clear() {
        terminated = true
        activation?.cancel()
        activation = nil
        // 放掉会话就等于把这张卡从系统撤走（deinit 即移除）。
        session = nil
        card.content = nil
        card.playbackSnapshot = nil
        card.commands = []
    }

    // MARK: - 内部

    private func startSessionIfNeeded() {
        guard session == nil else { return }

        card.commands = makeCommands(nextEnabled ?? true, previousEnabled ?? true)
        let session = MediaSession(card)
        self.session = session

        // 抢不到主会话就没什么可等的：直接退回旧接口，别让卡片空着。
        guard session.canBecomeApplicationPrimary else {
            fail(reason: "canBecomeApplicationPrimary=false")
            return
        }

        activation = Task { [weak self] in
            do {
                try await session.requestToBecomeApplicationPrimary()
                guard let self, !self.terminated else { return }

                // `isApplicationPrimary` 只说明它赢了本 App 内的会话竞争。LP 的 27.0.1
                // 已经实测这时点卡片仍无任何场景回调，所以继续申请系统主会话。
                // SDK 没有 card-tap 回调，也没保证这一步会拉起 App；日志把两层状态
                // 都打出来，真机才能判定「没申请上」还是「申请上也不管点击」。
                if !session.isSystemPrimary {
                    do {
                        try await session.requestToBecomeSystemPrimary()
                    } catch {
                        guard !self.terminated else { return }
                        KazumiLogBuffer.player(
                            "正在播放（iOS 27）：申请系统主会话失败（\(error)），保留应用主会话"
                        )
                    }
                }
                guard !self.terminated else { return }
                self.onActive?()
                KazumiLogBuffer.player(
                    "正在播放（iOS 27）：主会话状态 application=\(session.isApplicationPrimary) system=\(session.isSystemPrimary)"
                )
            } catch {
                guard let self, !self.terminated else { return }
                KazumiLogBuffer.player("正在播放（iOS 27）：申请应用主会话失败（\(error)），退回旧接口")
                self.fail(reason: "requestToBecomeApplicationPrimary failed")
            }
        }
    }

    /// 失败时只记日志 + 交棒，不崩：卡片能不能出来比「用哪条接口」重要。
    private func fail(reason: String) {
        guard !terminated else { return }
        terminated = true
        activation?.cancel()
        activation = nil
        session = nil
        card.content = nil
        card.playbackSnapshot = nil
        KazumiLogBuffer.player("正在播放（iOS 27）：新接口不可用（\(reason)）")
        onFailure?()
    }

    /// 元数据对齐旧路径：剧名 → title，「第几集 · 副标题」→ subtitle，总长、封面一致。
    private static func makeContent(_ payload: NowPlayingPublishPayload) -> GenericContent {
        GenericContent(
            id: payload.contentID,
            title: payload.title,
            subtitle: payload.subtitle.isEmpty ? nil : payload.subtitle,
            // 报「音频」不报「视频」（沿用旧路径 LP 4720）：报成视频，系统会把这张卡
            // 按视频内容处理，点一下是展开而不是把 App 叫到前台——正好是我们要修的现象。
            type: .audio,
            duration: payload.duration > 0 ? .finite(payload.duration) : nil,
            artwork: makeArtwork(payload)
        )
    }

    /// 封面走按需回调：系统来要图时我们直接给事先编好的数据。
    /// `ArtworkRepresentation` 只接受 `Data` / `CGImage`，所以用的是换集时编好的 JPEG。
    private static func makeArtwork(_ payload: NowPlayingPublishPayload) -> Artwork? {
        guard let data = payload.artworkData else { return nil }
        return Artwork(id: payload.artworkID) { _ in
            try ArtworkRepresentation(data: data)
        }
    }

    /// 进度 / 状态 / 速率。播放中给真实倍速，零速播放意图映射为缓冲，用户暂停仍为暂停。
    private static func makeSnapshot(_ payload: NowPlayingPublishPayload) -> MediaPlaybackSnapshot {
        let state: MediaPlaybackSnapshot.PlaybackState =
            payload.isPlaying
                ? (payload.rate > 0 ? .playing(rate: Float(payload.rate)) : .buffering)
                : .paused
        return MediaPlaybackSnapshot(
            state: state,
            elapsedTime: payload.elapsed,
            timestamp: Date()
        )
    }
}

/// MediaSession 认的 representable：必须是引用类型 + `@Observable`，
/// 后续所有更新都是改这个对象上的属性（框架没有 update 方法）。
@available(iOS 27.0, *)
@Observable
@MainActor
private final class NowPlayingSessionCard: MediaSessionRepresentable {
    let id = "kazumi.now-playing.session"
    var content: (any MediaContentRepresentable)?
    var playbackSnapshot: MediaPlaybackSnapshot?
    var commands: [MediaCommand] = []
}

#endif
