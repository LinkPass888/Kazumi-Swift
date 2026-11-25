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
//  污染 cookie 与脚本状态。同时开几个由调用方（`DownloadCenter`）的并发限流器管。
//
//  收结果采用锁保护的 `CheckedContinuation` + 取消/超时即刻唤醒：
//  任意回调、取消或超时都通过单次消费状态机安全 resume 一次，命中或取消后零延迟释放 WebView。
//

import Foundation

@MainActor
final class EpisodeMediaResolver {
    /// 一次解析的结果。
    struct Result: Sendable {
        var url: String
        var format: VideoSourceFormat
    }

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
        if cancellation.isCancelled || Task.isCancelled {
            throw DownloadError.cancelled
        }

        let sniffer = VideoSourceWebView()
        let waiter = ResolveWaiter()
        var timeoutTask: Task<Void, Never>?
        var loadTask: Task<Void, Never>?
        var cancelToken: UUID?

        defer {
            if let token = cancelToken {
                cancellation.removeCancelHandler(token)
            }
            waiter.cancelGraceTask()
            timeoutTask?.cancel()
            loadTask?.cancel()
            sniffer.onVideoURLParser = nil
            sniffer.onPageLoaded = nil
            sniffer.releaseMedia()
            sniffer.dispose()
        }

        let graceDuration = graceAfterLoad
        sniffer.onVideoURLParser = { event in
            // 同一个地址会重复报（fetch 与 video 标签各一次），waiter 只收第一个并即刻唤醒。
            guard !event.url.isEmpty else { return }
            waiter.finish(with: .success(.init(url: event.url, format: event.format)))
        }
        // 「网页加载完」只能听 didFinish：`load(url:)` 在请求刚发出时就返回了，
        // 拿它当加载完会让每一集都秒判「没有地址」（LP 5112 那个红叹号就是这个）。
        // 网页报完加载后再给脚本一段宽限期拼地址，超时即刻唤醒判定无媒体。
        sniffer.onPageLoaded = {
            waiter.scheduleGraceTimeout(after: graceDuration)
        }

        cancelToken = cancellation.addCancelHandler {
            waiter.finish(with: .failure(DownloadError.cancelled))
        }

        timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                waiter.finish(with: .failure(DownloadError.timedOut))
            } catch {
                // 正常命中或取消，忽略睡眠中断。
            }
        }

        // 下载取的也是播放页里那份地址：规则要登录，这里同样得带上（Fuck 5469 第 2 条）。
        sniffer.configureSession(pluginName: pluginName, url: pageURL)
        loadTask = Task { @MainActor in
            await sniffer.load(url: pageURL, useLegacyParser: useLegacyParser)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.attach(continuation)
                if cancellation.isCancelled || Task.isCancelled {
                    waiter.finish(with: .failure(DownloadError.cancelled))
                }
            }
        } onCancel: {
            waiter.finish(with: .failure(DownloadError.cancelled))
        }
    }
}

/// 跨线程单次消费唤醒器：保证 `CheckedContinuation` 至多被 resume 一次，并托管页面加载宽限计时器。
private final class ResolveWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EpisodeMediaResolver.Result, Error>?
    private var pendingOutcome: Swift.Result<EpisodeMediaResolver.Result, Error>?
    private var graceTask: Task<Void, Never>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<EpisodeMediaResolver.Result, Error>) {
        var immediate: Swift.Result<EpisodeMediaResolver.Result, Error>?
        lock.lock()
        if let pending = pendingOutcome {
            pendingOutcome = nil
            immediate = pending
        } else if !finished {
            self.continuation = continuation
        }
        lock.unlock()
        if let immediate {
            continuation.resume(with: immediate)
        }
    }

    func finish(with outcome: Swift.Result<EpisodeMediaResolver.Result, Error>) {
        let toResume: CheckedContinuation<EpisodeMediaResolver.Result, Error>?
        let graceToCancel: Task<Void, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        graceToCancel = graceTask
        graceTask = nil
        if let cont = continuation {
            continuation = nil
            toResume = cont
        } else {
            pendingOutcome = outcome
            toResume = nil
        }
        lock.unlock()

        graceToCancel?.cancel()
        toResume?.resume(with: outcome)
    }

    func scheduleGraceTimeout(after duration: Duration) {
        lock.lock()
        guard !finished, graceTask == nil else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                self?.finish(with: .failure(DownloadEngineError.notMedia))
            } catch {
                // 已命中结果或外部取消，忽略。
            }
        }
        graceTask = task
        lock.unlock()
    }

    func cancelGraceTask() {
        lock.lock()
        let task = graceTask
        graceTask = nil
        lock.unlock()
        task?.cancel()
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
        case .cancelled: String(localized: "已取消")
        case .pluginMissing(let name): String(localized: "规则「\(String(describing: name))」不在了，没法解析这一集")
        }
    }
}
