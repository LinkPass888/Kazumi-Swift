//
//  EpisodeMediaResolver.swift
//  Kazumi
//
//  离线缓存第一步：把「剧集页地址」嗅成「真实视频地址」。
//
//  规则给的只是网页地址，真正的 m3u8/mp4 是页面里 JS 拼出来、再发一次请求才有的。
//  播放器靠一个隐藏网页把它们截下来（`VideoSourceWebView`），下载走同一条路，
//  只是不显示画面。
//
//  一次解析一个 `VideoSourceWebView`：每个都带一个 WebContent 子进程，复用会互相
//  污染 cookie 与脚本状态。同时开几个由调用方（`DownloadCenter`）管。
//
//  收结果的写法是「锁保护的盒子 + 轮询」，不是 continuation：
//  continuation 套在 @MainActor 的 WebView 回调里，编译器的 region 隔离检查认不出来，
//  而且回调可能来两次，写不好就是 resume 两次崩溃。轮询 200ms 的代价小得多。
//

import Foundation

@MainActor
final class EpisodeMediaResolver {
    /// 一次解析的结果。
    struct Result: Sendable {
        var url: String
        var format: VideoSourceFormat
    }

    /// 轮询间隔。嗅到地址通常几百毫秒内就有，这个粒度够快又不烧 CPU。
    private let pollInterval: Duration = .milliseconds(200)

    /// 网页报加载完之后再等这么久（脚本还要拼地址、起播放器）。
    private let graceAfterLoad: Duration = .seconds(6)

    /// 解析一集。超时、取消、页面里没地址都会抛错。
    func resolve(
        pageURL: String,
        useLegacyParser: Bool,
        pluginName: String,
        timeout: Duration = .seconds(45),
        cancellation: CancellationFlag
    ) async throws -> Result {
        let sniffer = VideoSourceWebView()
        let box = EventBox()
        defer {
            sniffer.onVideoURLParser = nil
            sniffer.releaseMedia()
            sniffer.dispose()
        }

        sniffer.onVideoURLParser = { event in
            // 同一个地址会重复报（fetch 与 video 标签各一次），盒子只收第一个。
            guard !event.url.isEmpty else { return }
            box.deliver(.init(url: event.url, format: event.format))
        }
        // 「网页加载完」只能听 didFinish：`load(url:)` 在请求刚发出时就返回了，
        // 拿它当加载完会让每一集都秒判「没有地址」（LP 5112 那个红叹号就是这个）。
        sniffer.onPageLoaded = { box.markLoadFinished() }

        // 下载取的也是播放页里那份地址：规则要登录，这里同样得带上（Fuck 5469 第 2 条）。
        await MainActor.run {
            sniffer.configureSession(pluginName: pluginName, url: pageURL)
        }
        let loadTask = Task { @MainActor in
            await sniffer.load(url: pageURL, useLegacyParser: useLegacyParser)
        }
        defer { loadTask.cancel() }

        let started = ContinuousClock.now
        // 网页报完加载还要给脚本一点时间拼地址；过了这段宽限期仍然没有地址，
        // 那就是真没有，不用耗满超时。
        var pageLoadedAt: ContinuousClock.Instant?
        while true {
            if let result = box.take() { return result }
            if cancellation.isCancelled { throw DownloadError.cancelled }
            if box.loadFinished {
                if pageLoadedAt == nil { pageLoadedAt = ContinuousClock.now }
                if let loadedAt = pageLoadedAt, ContinuousClock.now - loadedAt > graceAfterLoad {
                    throw DownloadEngineError.notMedia
                }
            }
            if ContinuousClock.now - started > timeout { throw DownloadError.timedOut }
            try await Task.sleep(for: pollInterval)
        }
    }
}

/// 跨线程传「嗅到的第一个地址」的小盒子。
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: EpisodeMediaResolver.Result?
    private var delivered = false
    private var finished = false

    /// 只收第一个，后来的丢掉。
    func deliver(_ value: EpisodeMediaResolver.Result) {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return }
        delivered = true
        result = value
    }

    func take() -> EpisodeMediaResolver.Result? {
        lock.lock()
        defer { lock.unlock() }
        let value = result
        result = nil
        return value
    }

    func markLoadFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var loadFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

/// 解析这一步自己的错误（跟下载引擎的分开，报错话术不一样）。
enum DownloadError: LocalizedError {
    case timedOut
    case cancelled
    case pluginMissing(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "没等到视频地址，网页加载太慢或者要人点一下")
        case .cancelled: "已取消"
        case .pluginMissing(let name): String(localized: "规则「\(String(describing: name))」不在了，没法解析这一集")
        }
    }
}
