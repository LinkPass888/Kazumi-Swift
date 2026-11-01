//
//  NowPlayingCenter.swift
//  Kazumi
//
//  控制中心 / 通知中心 / 锁屏的「正在播放」信息（LP 4433、Colo 4434）。
//
//  实时活动（灵动岛）是另一套，互不冲突：
//   * 这里交给系统的是「我在放什么」——剧名、第几话、封面、进度、播放速率；
//   * 系统拿这些自己画控制中心那张卡，也自己画灵动岛上 Apple Music 那种样子
//     （左封面、右声谱）——所以 LP 4431 想要的那个效果，主要靠这一层。
//
//  几个必须知道的点：
//   * iOS 27 起卡片改由 NowPlaying 框架的 MediaSession 发（点卡片回 App 那条路）；
//     iOS 26 及以下仍走这里的 MPNowPlayingInfoCenter / MPRemoteCommandCenter。
//     分支在 `write()` / `clear()` 里，新接口全部在 NowPlayingSession27.swift。
//   * 只在「状态/元数据变了」或「系统自己推算的进度跟真实进度差到 1.5 秒以上」时
//     写一次（LP 4925 Step 1）：原来每 2 秒无条件赋一次值，那是实打实的一次
//     跨进程全量覆盖写；系统自己会按我们给的速率往前推，不用我们一直喂。
//   * 封面图片是异步取的，取不到就先不带封面，取到了立刻补一次更新。
//   * 退出播放器、播完、出错都要 `clear()`，否则上一集留在控制中心卡片上。
//

import MediaPlayer
import QuartzCore
import UIKit
// iOS 27 起的新发布接口。框架本身只在 27 存在，所以项目里挂的是弱链接；
// 用到它的每一处都在 `if #available(iOS 27.0, *)` 里（见 NowPlayingSession27.swift）。
#if canImport(NowPlaying)
import NowPlaying
#endif

/// iOS 27+ 那条新路（NowPlaying 框架的 MediaSession）要的「这一次写什么」。
/// 故意只用 Foundation 类型：façade 自己不用带 `@available(iOS 27.0, *)`，
/// 新框架的类型全关在 `NowPlayingSession27.swift` 里。
struct NowPlayingPublishPayload {
    var artworkID: String
    var contentID: String
    var title: String
    var subtitle: String
    var duration: Double
    var elapsed: Double
    var isPlaying: Bool
    var rate: Double
    var artworkData: Data?
    /// 上一集 / 下一集是否可用；nil = 还不知道（集列表没拉到），保持可用。
    var nextEnabled: Bool?
    var previousEnabled: Bool?
    /// 换集 / 封面到了才重建 content；平时只更新进度快照。
    var rebuildContent: Bool
}

/// 新接口发布器的门面。`NowPlayingCenter` 只认这个协议，
/// 具体实现（`NowPlayingSessionPublisher`）整个带 `@available(iOS 27.0, *)`，
/// 这样 iOS 26 的部署目标也能编译。
@MainActor
protocol NowPlayingModernPublishing: AnyObject {
    /// 抢主会话失败时的退路：交回旧接口重写一次，卡片不能消失。
    var onFailure: (@MainActor () -> Void)? { get set }
    func publish(_ payload: NowPlayingPublishPayload)
    /// 上一集 / 下一集是否可用；nil = 还不知道（集列表没拉到），保持可用。
    func setCommandAvailability(next: Bool?, previous: Bool?)
    func clear()
}

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    /// 控制中心那几颗按钮按下去要做什么，由播放页面接上。
    /// 没接就是空实现——显示出来点不动比不显示更难看，所以一进来就接好。
    /// 真正的存放处在 commands 盒子里：注册给系统的闭包只读盒子，不碰主线程状态。
    var onPlay: (() -> Void)? {
        get { commands.onPlay }
        set { commands.onPlay = newValue }
    }
    var onPause: (() -> Void)? {
        get { commands.onPause }
        set { commands.onPause = newValue }
    }
    var onNext: (() -> Void)? {
        get { commands.onNext }
        set { commands.onNext = newValue }
    }
    var onPrevious: (() -> Void)? {
        get { commands.onPrevious }
        set { commands.onPrevious = newValue }
    }
    var onSeek: ((Double) -> Void)? {
        get { commands.onSeek }
        set { commands.onSeek = newValue }
    }

    /// 遥控键的转接盒：回调与「是否在播」都在这里，不带主线程隔离。
    /// 系统在哪个队列回调都不会撞断言；真正动作回主线程做。
    private final class CommandBox: @unchecked Sendable {
        var onPlay: (() -> Void)?
        var onPause: (() -> Void)?
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var onSeek: ((Double) -> Void)?
        /// toggle 那颗键据此决定叫停还是叫播。
        var isPlaying = false
    }

    private let commands = CommandBox()

    /// 当前这一集的信息，用来判断要不要真的写一次 nowPlayingInfo。
    private struct Info: Equatable {
        var title: String
        var artist: String
        var albumTitle: String
        var artworkURL: String
        var duration: Double
        var episode: Int
        /// 这部一共多少集（0 = 不知道）。给系统写「队列第几项 / 一共几项」用。
        var episodeCount: Int
    }

    private var info: Info?
    /// 算好的封面按地址存着——避免每次换集都重新解码。
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    /// 同一张封面编码好的图片数据，只给 iOS 27 那条新接口用（见 `write`）。
    private var artworkDataCache: [String: Data] = [:]

    /// iOS 27+ 的新发布器。nil = 走旧接口（iOS 26 永远走旧接口）。
    /// 类型是协议而不是具体类，具体类整个带 `@available(iOS 27.0, *)`。
    private var modernPublisher: (any NowPlayingModernPublishing)?
    /// 新接口这一次已经失败过：不再重试，直接走旧接口；`clear()` 时重置。
    private var modernUnavailable = false
    private var commandsConfigured = false
    private var lastRate: Double = 0
    private var lastElapsed: Double = 0
    private var lastState: MPNowPlayingPlaybackState = .stopped

    /// 上一次**真的写进系统**时的样子（LP 4925 Step 1）。
    /// 拿它跟这一次比：状态没变就看系统自己推算到哪儿了，偏得不多就什么都不做。
    private struct SyncSnapshot {
        var title: String
        var artist: String
        var duration: Double
        var elapsedTime: Double
        /// 播放中为实际倍速，暂停 / 缓冲中为 0——系统就是按这个速率往前推的。
        var effectiveRate: Double
        var isPlaying: Bool
        /// 封面地址；封面是异步到的，到了要算一次变化（那时它才有得写）。
        var artworkKey: String
        /// 写入时的单调时钟，用来算系统侧自己走到了哪儿。
        var timestamp: CFTimeInterval
    }

    private var lastSyncSnapshot: SyncSnapshot?

    /// 写了几次 / 跳过了几次轮询。mpv 的 `wakeup` 日志一秒几十条、日志缓冲只留 200 条，
    /// 逐次写会被冲掉，所以每 8 次跳过记一条、停止时再记一条总的——
    /// 在「运行日志 → 播放」里能直接看到「每 2 秒一次全量写」是不是真没了（LP 4925）。
    private var writeCount = 0
    private var skipCount = 0

    private init() {}

    // MARK: - 遥控指令

    /// 接一次就够了。幂等：重复调用不会重复注册。
    func configureRemoteCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        // 快进/快退那几颗**必须显式关掉**（LP 5031）：控制中心/锁屏那排只有两个格子，
        // 系统默认会把 `skipForwardCommand` / `skipBackwardCommand`（±15 秒）摆上去，
        // 上一集/下一集就被挤没了。我们不做 15 秒跳，所以直接关。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false

        Self.registerCommandHandlers(commands)
        // iOS 27+ 另有一条新接口（见 NowPlayingSession27.swift），但这套 target **不拆**：
        // 新接口抢到主会话后旧接口这边没有 nowPlayingInfo、本来就没卡片可挂；
        // 而新接口一旦失败要立刻退回这套（`fallBackToLegacyPublisher`），拆了就得重建。
        // 反过来把旧接口先关掉的风险更大：控制中心那几颗键现在是好使的。
    }

    /// 故意 nonisolated：闭包在这个上下文里形成，才不继承主线程隔离。
    /// 系统在自己的队列上回调它们，哪怕闭包体自己再跳回主线程也没用——
    /// 隔离检查就压在闭包入口那一帧（真机报告里就是这么死的）。
    private nonisolated static func registerCommandHandlers(_ box: CommandBox) {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            guard box.onPlay != nil else { return .commandFailed }
            Task { @MainActor in box.onPlay?() }
            return .success
        }

        center.pauseCommand.addTarget { _ in
            guard box.onPause != nil else { return .commandFailed }
            Task { @MainActor in box.onPause?() }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { _ in
            guard box.onPlay != nil || box.onPause != nil else { return .commandFailed }
            Task { @MainActor in
                if box.isPlaying { box.onPause?() } else { box.onPlay?() }
            }
            return .success
        }

        // 上一集 / 下一集：控制中心那两颗箭头。
        //
        // 这两颗「点了没反应」最难查的是分不出「系统没送到」还是「送到了没做」（LP 5033）。
        // 所以每条路都留一行日志，日志类别用「播放」：
        //   - 什么都没有 → 系统根本没投递（就不是这段代码的问题）
        //   - 「收到下一集」但没有下一行 → 回调没接上
        //   - 「没有下一集」 → 集数/边界判据挡了
        center.nextTrackCommand.addTarget { _ in
            KazumiLogBuffer.player("遥控：收到下一集")
            guard box.onNext != nil else {
                KazumiLogBuffer.player("遥控：下一集没有回调（播放页没接上）")
                return .commandFailed
            }
            Task { @MainActor in box.onNext?() }
            return .success
        }

        center.previousTrackCommand.addTarget { _ in
            KazumiLogBuffer.player("遥控：收到上一集")
            guard box.onPrevious != nil else {
                KazumiLogBuffer.player("遥控：上一集没有回调（播放页没接上）")
                return .commandFailed
            }
            Task { @MainActor in box.onPrevious?() }
            return .success
        }

        // 锁屏那条进度条可以拖。
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  box.onSeek != nil
            else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in box.onSeek?(target) }
            return .success
        }
    }

    // MARK: - 更新

    /// 播放入口：剧名、第几话、封面地址、总长。
    /// - Parameters:
    ///   - isPlaying: 当前是否在播；直接决定速率，也决定控制中心那颗按钮画成什么。
    ///   - elapsed: 当前进度（秒）。
    ///   - rate: 实际倍速（播放中）。写进系统的就是它——系统按这个速率自己往前推进度，
    ///     暂停 / 缓冲时给 0。必须给真实值：给 1 的话，2 倍速时系统推得比真实慢一倍，
    ///     偏差每秒涨 1 秒，纠偏写入会从每 2 秒变成每 1.5 秒。
    func update(
        title: String,
        episode: Int,
        episodeTitle: String?,
        artworkURL: String?,
        duration: Double,
        elapsed: Double,
        isPlaying: Bool,
        rate: Double = 1,
        episodeCount: Int = 0
    ) {
        configureRemoteCommands()

        let artist = episodeTitle.map { "第 \(episode) 集 · \($0)" } ?? "第 \(episode) 集"
        let next = Info(
            title: title,
            artist: artist,
            albumTitle: "",
            artworkURL: artworkURL ?? "",
            duration: max(duration, 0),
            episode: episode,
            episodeCount: max(episodeCount, 0)
        )

        let isNewItem = info != next
        info = next

        // 上一集 / 下一集到两端要灰掉（LP 5060）：main 那边由 audio_service 按队列位置
        // 置灰，我们这边一直写死 `isEnabled = true`，所以第一集会点着「上一集」没反应。
        // 只拿 `episodeCount` 判：集列表还没拉回来（0）时不动，免得加载那两秒两颗键先灰一下。
        if episodeCount > 0 {
            let center = MPRemoteCommandCenter.shared()
            center.previousTrackCommand.isEnabled = episode > 1
            center.nextTrackCommand.isEnabled = episode < episodeCount
        }
        // 新接口的箭头可用性跟着同一套判据走（旧接口改的是 MPRemoteCommandCenter，
        // 新接口得重建 commands 数组）。刻意不经过下面的节流：集列表刚拉回来那一下
        // 元数据没变，`publish` 会跳过写，但两颗箭头该灰还是得灰。
        if #available(iOS 27.0, *) {
            modernPublisher?.setCommandAvailability(
                next: episodeCount > 0 ? episode < episodeCount : nil,
                previous: episodeCount > 0 ? episode > 1 : nil
            )
        }
        let effectiveRate = isPlaying ? max(rate, 0) : 0
        lastRate = effectiveRate
        lastElapsed = elapsed
        commands.isPlaying = isPlaying

        // 换集（或换剧）才重建整套信息；只是进度变了走轻量的那条——
        // 每两秒把整个字典重建再赋回去没必要，系统也多收一份重复更新。
        if isNewItem {
            publish(next, elapsed: elapsed, isPlaying: isPlaying, rate: effectiveRate, full: true)
            loadArtwork(for: next)
        } else {
            publish(next, elapsed: elapsed, isPlaying: isPlaying, rate: effectiveRate, full: false)
        }
    }

    /// 清空正在播放卡片与回调；调用本身不表明退出原因。
    func clear() {
        PlaybackLifecycleDiagnostics.log(
            "NowPlayingCenter.clear",
            details: "cardClear=invoked writes=\(writeCount) skips=\(skipCount)"
        )
        info = nil
        lastRate = 0
        lastElapsed = 0
        lastState = .stopped
        // 新接口的会话一并拆掉：释放 MediaSession 就等于把卡片从系统那边撤走。
        // 下一次播放重新建一个；`modernUnavailable` 也归零，下次重新试新接口。
        modernPublisher?.clear()
        modernPublisher = nil
        modernUnavailable = false
        artworkDataCache.removeAll()
        // 保留原有同步统计；上面的卡片清理标记也记录 0/0。
        if writeCount > 0 || skipCount > 0 { logSyncSummary() }
        writeCount = 0
        skipCount = 0
        // 快照一起清掉（LP 4925 Step 1）：不清的话，下一集第一次写入会跟上一集的
        // 快照比，可能被判成「没变化」而跳过——那一次跳过就是真的没写出去。
        lastSyncSnapshot = nil
        // 遥控键的盒子一起放掉（Fuck 4881）：那几个闭包强持有 surface，而这里是
        // 单例——不放掉，上一轮的 surface 一直被攥着（engine 早停了，但对象还在），
        // 退出播放器后系统再送遥控事件还会打到已经停掉的 surface 上。
        commands.onPlay = nil
        commands.onPause = nil
        commands.onNext = nil
        commands.onPrevious = nil
        commands.onSeek = nil
        commands.isPlaying = false
        // 遥控键回到「都可用」的默认态：`configureRemoteCommands()` 只会跑一次，
        // 这里若把两颗键留在灰的状态，下一轮播放要等第一次 `update()` 才恢复。
        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - iOS 27+ 的新接口

    /// 懒建新接口发布器（实现见 NowPlayingSession27.swift）。
    /// 只在 `if #available(iOS 27.0, *)` 分支里调得到。
    @available(iOS 27.0, *)
    private func makeModernPublisher() -> (any NowPlayingModernPublishing)? {
        #if canImport(NowPlaying)
        guard #available(iOS 27.0, *) else { return nil }
        // 遥控键继续用同一个盒子：新接口和旧接口打到的必须是同一批闭包。
        let box = commands
        let publisher = NowPlayingSessionPublisher { next, previous in
            Self.makeModernCommands(box, next: next, previous: previous)
        }
        publisher.onFailure = { [weak self] in
            self?.fallBackToLegacyPublisher()
        }
        modernPublisher = publisher
        return publisher
        #else
        return nil
        #endif
    }

    /// 新接口不行了（抢不到主会话 / 申请抛错）：把引用放掉，用旧接口把当前这一集
    /// 补写出去。卡片能不能出来比「用哪条接口」重要，所以这里一定不能静默。
    private func fallBackToLegacyPublisher() {
        modernPublisher = nil
        modernUnavailable = true
        guard let info else { return }
        KazumiLogBuffer.player("正在播放（iOS 27）：新接口不可用，退回旧接口发卡片")
        // 那一次已经算作「写过了」，不清掉节流快照的话这次会被判成没变化而跳过，
        // 结果就是退回旧接口了却没写出去。
        lastSyncSnapshot = nil
        publish(info, elapsed: lastElapsed, isPlaying: lastRate > 0, rate: lastRate, full: true)
    }

    /// 新接口的 commands 数组。逐条对齐旧接口（`registerCommandHandlers`）：
    /// 播放、暂停、播放/暂停、上一集、下一集、拖进度，打到的都是同一个盒子里的闭包。
    /// 快进/快退**不加**：旧接口也显式关着（LP 5031），我们本来就不做 15 秒跳。
    #if canImport(NowPlaying)
    @available(iOS 27.0, *)
    private nonisolated static func makeModernCommands(
        _ box: CommandBox,
        next: Bool,
        previous: Bool
    ) -> [MediaCommand] {
        [
            .play {
                guard box.onPlay != nil else { throw MediaSessionError.invalidState }
                Task { @MainActor in box.onPlay?() }
            },
            .pause {
                guard box.onPause != nil else { throw MediaSessionError.invalidState }
                Task { @MainActor in box.onPause?() }
            },
            .togglePlayPause {
                guard box.onPlay != nil || box.onPause != nil else {
                    throw MediaSessionError.invalidState
                }
                Task { @MainActor in
                    if box.isPlaying { box.onPause?() } else { box.onPlay?() }
                }
            },
            // 上一集 / 下一集：日志跟旧接口一样分「系统没投递 / 没接上 / 已切」，
            // 真机上才分得清是哪一段断的（LP 5033）。
            .next {
                KazumiLogBuffer.player("遥控（iOS 27）：收到下一集")
                guard box.onNext != nil else {
                    KazumiLogBuffer.player("遥控（iOS 27）：下一集没有回调（播放页没接上）")
                    throw MediaSessionError.invalidState
                }
                Task { @MainActor in box.onNext?() }
            }.enabled(next),
            .previous {
                KazumiLogBuffer.player("遥控（iOS 27）：收到上一集")
                guard box.onPrevious != nil else {
                    KazumiLogBuffer.player("遥控（iOS 27）：上一集没有回调（播放页没接上）")
                    throw MediaSessionError.invalidState
                }
                Task { @MainActor in box.onPrevious?() }
            }.enabled(previous),
            // 锁屏那条进度条可以拖。
            .seekToPosition { position in
                guard box.onSeek != nil else { throw MediaSessionError.invalidState }
                Task { @MainActor in box.onSeek?(position) }
            },
        ]
    }
    #endif

    // MARK: - 内部

    private func publish(_ info: Info, elapsed: Double, isPlaying: Bool, rate: Double, full: Bool) {
        let now = CACurrentMediaTime()
        let snapshot = SyncSnapshot(
            title: info.title,
            artist: info.artist,
            duration: info.duration,
            elapsedTime: elapsed,
            effectiveRate: rate,
            isPlaying: isPlaying,
            artworkKey: artworkCache[info.artworkURL] != nil ? info.artworkURL : "",
            timestamp: now
        )

        guard let last = lastSyncSnapshot else {
            lastSyncSnapshot = snapshot
            recordWrite()
            write(info, elapsed: elapsed, isPlaying: isPlaying, rate: rate, full: full)
            return
        }

        // 状态 / 元数据变了：立刻写。
        if last.title != snapshot.title
            || last.artist != snapshot.artist
            || last.artworkKey != snapshot.artworkKey
            || last.isPlaying != snapshot.isPlaying
            || last.effectiveRate != snapshot.effectiveRate
            || abs(last.duration - snapshot.duration) > 0.5
        {
            lastSyncSnapshot = snapshot
            recordWrite()
            write(info, elapsed: elapsed, isPlaying: isPlaying, rate: rate, full: full)
            return
        }

        // 都没变：系统自己按上次的速率往前推。推算值跟真实进度差不到 1.5 秒就
        // 不打扰它——差到了才写（拖了进度、+80 跳过、缓冲卡完恢复都算）。
        let expectedElapsed = last.elapsedTime + (now - last.timestamp) * last.effectiveRate
        guard abs(elapsed - expectedElapsed) >= 1.5 else {
            skipCount += 1
            if skipCount.isMultiple(of: 8) { logSyncSummary() }
            return
        }

        lastSyncSnapshot = snapshot
        recordWrite()
        write(info, elapsed: elapsed, isPlaying: isPlaying, rate: rate, full: full)
    }

    private func recordWrite() {
        writeCount += 1
    }

    private func logSyncSummary() {
        KazumiLogBuffer.shared.append(
            "正在播放：已写入 \(writeCount) 次，跳过 \(skipCount) 次轮询",
            category: .player
        )
    }

    /// 真正写一次：重建字典 + 赋值。`publish` 判定要写的时候才走到这里。
    private func write(_ info: Info, elapsed: Double, isPlaying: Bool, rate: Double, full: Bool) {
        // 卡片第一次写进系统的这一刻也补一次远程控制事件声明（LP 4961）：
        // 启动那一下是在场景还没进前台时调的。只补一次，见 `PlayerAudioSession`。
        PlayerAudioSession.declareRemoteControlEventsIfNeeded()

        // iOS 27+：卡片改由 NowPlaying 框架的 MediaSession 发（见 NowPlayingSession27.swift）。
        // 它抢不到主会话时会立刻回调 `onFailure`，把那一次退回下面的旧写法，
        // 所以这里就是「先试新的」——新的不行，一行都不少地跑旧代码。
        if #available(iOS 27.0, *), !modernUnavailable {
            let publisher = modernPublisher ?? makeModernPublisher()
            if let publisher {
                publisher.publish(
                    NowPlayingPublishPayload(
                        artworkID: info.artworkURL,
                        contentID: "\(info.title)#\(info.episode)",
                        title: info.title,
                        subtitle: info.artist,
                        duration: info.duration,
                        elapsed: elapsed,
                        isPlaying: isPlaying,
                        rate: rate,
                        artworkData: artworkDataCache[info.artworkURL],
                        nextEnabled: info.episodeCount > 0 ? info.episode < info.episodeCount : nil,
                        previousEnabled: info.episodeCount > 0 ? info.episode > 1 : nil,
                        rebuildContent: full
                    )
                )
                return
            }
        }

        var dictionary = full ? [String: Any]() : (MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:])

        dictionary[MPMediaItemPropertyTitle] = info.title
        dictionary[MPMediaItemPropertyArtist] = info.artist
        // 专辑那行不写：卡片上其实只有两行，写了反而跟副标题并成一串（Colo 4444）。
        if !info.albumTitle.isEmpty {
            dictionary[MPMediaItemPropertyAlbumTitle] = info.albumTitle
        } else {
            dictionary.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        dictionary[MPMediaItemPropertyPlaybackDuration] = info.duration
        dictionary[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        dictionary[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        if full {
            // 报「音频」不报「视频」（LP 4720）：报成视频，系统就按视频内容处理那颗
            // 「正在播放」指示——点一下是展开、不跳 App；音乐 App 报音频，点一下进 App。
            dictionary[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            // 集数：系统自带的「第 N 集」字段就是专辑里的音轨号，控制中心会拿出来显示。
            dictionary[MPMediaItemPropertyAlbumTrackNumber] = info.episode
            // 队列位置（LP 5038）：main 经 audio_service 会写这两个键，我们之前一个字都没写。
            // 系统靠它们把锁屏/控制中心那两颗箭头当成「在这一摞里的上一个/下一个」，
            // 不写就只有音乐 App 那种默认语义，遥控键可能不被当成可用的队列操作。
            if info.episodeCount > 0 {
                // 系统这两个键都是 0 起的，我们自己的集数是 1 起的。
                dictionary[MPNowPlayingInfoPropertyPlaybackQueueIndex] = max(0, info.episode - 1)
                dictionary[MPNowPlayingInfoPropertyPlaybackQueueCount] = info.episodeCount
            } else {
                dictionary.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueIndex)
                dictionary.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueCount)
            }
        }

        if let artwork = artworkCache[info.artworkURL] {
            dictionary[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = dictionary
        // 播放状态只在真的变了才写：每两秒重写一次没有意义。
        let state: MPNowPlayingPlaybackState = isPlaying ? .playing : .paused
        if state != lastState {
            MPNowPlayingInfoCenter.default().playbackState = state
            lastState = state
        }
    }

    /// 封面：先查缓存，没有就下载，拿到后再补一次更新。
    private func loadArtwork(for info: Info) {
        let url = info.artworkURL
        guard !url.isEmpty else { return }
        if artworkCache[url] != nil { return }

        Task { [weak self] in
            let loader = KazumiImageLoader.shared
            // 控制中心那张封面的显示尺寸比列表大，按 900 解一次足够。
            _ = await loader.load(url, pixelSize: 900)
            guard let image = loader.cachedImage(for: url, pixelSize: 900) else { return }
            // iOS 27 那条新接口的封面是按需回调的 `Artwork`，回调里只能直接给编码好的
            // `ArtworkRepresentation`（Data / CGImage）。所以先在这里编一次，
            // 别等系统来要图那一帧再同步编（那个回调不在主线程上，也不能再蹦去主线程）。
            var encodedData: Data?
            #if canImport(NowPlaying)
            if #available(iOS 27.0, *) {
                encodedData = await Self.encodeArtworkData(image)
            }
            #endif
            // 捕进 `MainActor.run` 的必须是常量：闭包是 @Sendable，
            // 捕一个 var 在 Swift 6 里直接是「并发代码里改了捕获变量」。
            let encoded = encodedData
            await MainActor.run {
                guard let self else { return }
                // 这颗闭包是系统在**后台队列**上调用的（它拿去编 JPEG）。
                // 在 MainActor 上下文里直接写闭包，闭包会继承主线程隔离，
                // 一被后台调用就撞隔离断言 → SIGTRAP（真机、模拟器都会）。
                // 所以交非隔离的静态方法去造，闭包才不带主线程隔离。
                let artwork = Self.makeArtwork(image: image)
                self.artworkCache[url] = artwork
                if let encoded { self.artworkDataCache[url] = encoded }
                // 图回来了，如果还是这一集，就把封面补进去（这一下才整套重建）。
                guard let current = self.info, current.artworkURL == url else { return }
                self.publish(
                    current,
                    elapsed: self.lastElapsed,
                    isPlaying: self.lastRate > 0,
                    rate: self.lastRate,
                    full: true
                )
            }
        }
    }

    /// 把 UIImage 编成 JPEG 数据，只给 iOS 27 新接口的封面回调用。
    /// `UIImage` 不是 Sendable，编出来的 `Data` 是；900px JPEG 编码也别压在主线程上。
    #if canImport(NowPlaying)
    @available(iOS 27.0, *)
    private nonisolated static func encodeArtworkData(_ image: UIImage) async -> Data? {
        let box = ArtworkImageBox(image)
        return await Task.detached(priority: .utility) {
            box.image.jpegData(compressionQuality: 0.92)
        }.value
    }
    #endif

    /// 包一层：UIImage 没标记可跨线程传递，交给系统闭包持有得由我们担保。
    private final class ArtworkImageBox: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    /// 故意 nonisolated：在这个上下文里形成的闭包不继承主线程隔离，
    /// 系统在哪个队列调它都不会撞断言。
    private nonisolated static func makeArtwork(image: UIImage) -> MPMediaItemArtwork {
        let box = ArtworkImageBox(image)
        return MPMediaItemArtwork(boundsSize: box.image.size) { _ in box.image }
    }
}
