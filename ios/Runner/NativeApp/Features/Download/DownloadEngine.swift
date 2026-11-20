//
//  DownloadEngine.swift
//  Kazumi
//
//  真正落盘的那一层：把媒体地址变成能离线播的本地文件。
//
//  跟原版 `download_manager.dart` 同一个形状：并行的单位是**文件**，不把单个文件切段。
//    * HLS（.m3u8）：每个分片一个任务，并发数由设置里的「每集分片并发」卡住，
//      各落成 `seg_00000.ts` 加一份改写过的本地播放列表。重下时跳过盘上已有的分片，
//      这就是续传。
//    * 直链（mp4 之类）：整份一个任务，断了用 `Range: bytes=N-` 接着下。
//
//  一个文件一个 `URLSessionDownloadTask`：它自带进度、失败重试、写到临时文件再交回来，
//  比自己拼 Data 稳。
//

import Foundation

/// 线程安全的取消标记。下载循环在后台线程，用户在界面点取消，靠它立即传话并触发正在进行的任务取消。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    func cancel() {
        let callbacks: [@Sendable () -> Void]
        lock.lock()
        value = true
        callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        for callback in callbacks {
            callback()
        }
    }

    /// 注册取消回调；若已取消则立刻触发。返回 token 供任务结束后注销。
    @discardableResult
    func addCancelHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        var fireImmediately = false
        lock.lock()
        if value {
            fireImmediately = true
        } else {
            handlers[token] = handler
        }
        lock.unlock()
        if fireImmediately {
            handler()
        }
        return token
    }

    func removeCancelHandler(_ token: UUID) {
        lock.lock()
        handlers.removeValue(forKey: token)
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 下载过程中的进度。都在后台线程回调，调用方自己切主线程。
struct DownloadProgress: Sendable {
    var receivedBytes: Int64
    var totalBytes: Int64
    /// 0…1；总大小未知时是 -1，界面画不确定进度。
    var fraction: Double
}

enum DownloadEngineError: LocalizedError, Equatable {
    case badStatus(Int)
    case notMedia
    case emptyPlaylist
    case encrypted
    case multipleInitSegments
    case cancelled
    case diskFull

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): String(localized: "服务器返回 \(String(describing: code))")
        case .notMedia: String(localized: "这个地址不是视频，可能规则给错了")
        case .emptyPlaylist: String(localized: "播放列表是空的")
        case .encrypted: String(localized: "这一集是加密的，下不了")
        case .multipleInitSegments: String(localized: "这一集有多个初始化段，下不了")
        case .cancelled: String(localized: "已取消")
        case .diskFull: String(localized: "存储空间不够")
        }
    }
}

final class DownloadEngine: @unchecked Sendable {
    /// 单个文件失败后重试几次（原版也是三次）。
    private let maxRetries = 3

    /// 取某个地址该带的 Cookie：规则登录过才有，按地址的域和路径筛（Fuck 5469 第 2 条）。
    /// 下载取的是播放页里那份媒体，规则要登录时这份请求同样得带。
    private let cookieForURL: (@Sendable (URL) -> String?)?

    init(cookieForURL: (@Sendable (URL) -> String?)? = nil) {
        self.cookieForURL = cookieForURL
    }

    private func applyCookie(to request: inout URLRequest, url: URL) {
        guard let cookie = cookieForURL?(url), !cookie.isEmpty else { return }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }

    /// 下一集到 `directory`，返回能播的那个本地文件。
    ///
    /// - Parameters:
    ///   - baseName: 这一集的名字前缀（`ep-3`），分片与播放列表都按它开头。
    ///   - segmentConcurrency: 一集内部同时拉几个分片。
    func download(
        mediaURL: String,
        referer: String?,
        userAgent: String?,
        to directory: URL,
        baseName: String,
        segmentConcurrency: Int,
        cancellation: CancellationFlag,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        guard let url = URL(string: mediaURL) else { throw DownloadEngineError.notMedia }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 先取前 2KB 看一眼：是播放列表还是整份文件。
        let probe = try await probeKind(url, referer: referer, userAgent: userAgent)
        if cancellation.isCancelled { throw DownloadEngineError.cancelled }

        switch probe.kind {
        case .hls(let playlistURL):
            return try await downloadHLS(
                playlistURL: playlistURL,
                referer: referer,
                userAgent: userAgent,
                to: directory,
                baseName: baseName,
                segmentConcurrency: segmentConcurrency,
                cancellation: cancellation,
                onProgress: onProgress
            )
        case .file(let resolvedURL, let expectedBytes):
            return try await downloadFile(
                resolvedURL,
                expectedBytes: expectedBytes,
                referer: referer,
                userAgent: userAgent,
                to: directory,
                baseName: baseName,
                cancellation: cancellation,
                onProgress: onProgress
            )
        }
    }

    // MARK: - 探类型

    private enum ProbeKind {
        /// 播放列表：主列表和媒体列表都算。
        case hls(URL)
        /// 整份文件。
        case file(URL, Int64)
    }

    private struct Probe {
        var kind: ProbeKind
        /// 探针读到的开头文本，媒体列表直接拿它解析，省一次请求。
        var prefixText: String
    }

    private func probeKind(_ url: URL, referer: String?, userAgent: String?) async throws -> Probe {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        apply(headers: request, referer: referer, userAgent: userAgent)
        if let referer, !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        applyCookie(to: &request, url: url)

        // 用流式请求只读开头：有的服务器不理 Range，直接回整个文件，
        // 用 data(for:) 会把几百 MB 全塞进内存。
        var prefix = Data()
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadEngineError.badStatus(http.statusCode)
        }
        for try await byte in bytes {
            prefix.append(byte)
            if prefix.count >= 2048 { break }
        }
        let http = response as? HTTPURLResponse
        let finalURL = http?.url ?? url
        let text = String(data: prefix, encoding: .utf8) ?? ""
        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksHLS = text.hasPrefix("#EXTM3U")
            || finalURL.path.contains(".m3u8")
            || url.absoluteString.contains(".m3u8")
            || contentType.contains("mpegurl")
        if looksHLS {
            return Probe(kind: .hls(finalURL), prefixText: text)
        }
        return Probe(kind: .file(finalURL, Self.totalContentBytes(from: http)), prefixText: text)
    }

    /// 提取完整文件长度：206 分片响应从 `Content-Range: bytes a-b/total` 取总长度，避免把探针分片大小（2048）当成完整文件。
    fileprivate static func totalContentBytes(from response: HTTPURLResponse?) -> Int64 {
        guard let response else { return -1 }
        if response.statusCode == 206 {
            guard let rangeHeader = response.value(forHTTPHeaderField: "Content-Range"),
                  let slash = rangeHeader.lastIndex(of: "/") else {
                return -1
            }
            let totalPart = rangeHeader[rangeHeader.index(after: slash)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let total = Int64(totalPart), total > 0 {
                return total
            }
            return -1
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : -1
    }

    // MARK: - HLS

    private func downloadHLS(
        playlistURL: URL,
        referer: String?,
        userAgent: String?,
        to directory: URL,
        baseName: String,
        segmentConcurrency: Int,
        cancellation: CancellationFlag,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        var text = try await fetchText(playlistURL, referer: referer, userAgent: userAgent)
        var baseURL = playlistURL

        // 主列表：挑码率最高的一条子列表。用户是「下载」，不是「省流量」。
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = HLSPlaylist.bestVariant(from: text, baseURL: playlistURL) else {
                throw DownloadEngineError.emptyPlaylist
            }
            text = try await fetchText(variant, referer: referer, userAgent: userAgent)
            baseURL = variant
        }

        let plan = try HLSPlaylist.localPlan(from: text, baseURL: baseURL, prefix: baseName)
        guard !plan.segmentURLs.isEmpty else { throw DownloadEngineError.emptyPlaylist }

        // 初始化段（fMP4 少了它不能播）。
        var initName: String?
        if let initURL = plan.initURL {
            let name = "\(baseName)-init.mp4"
            let target = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try await fetchToFile(initURL, referer: referer, userAgent: userAgent, target: target, cancellation: cancellation)
            }
            initName = name
        }

        // 分片并发下载。已经存在的分片直接跳过——断点续传靠这个。
        let total = plan.segmentURLs.count
        // 盘上已有的分片（上次下到一半 / 续传）：既计入已完成片数，也累加真实已落盘字节数，
        // 避免暂停再继续时已下载大小被清零重算。
        var existingNames = Set<String>()
        var receivedBytes: Int64 = 0
        if let initName {
            let initPath = directory.appending(path: initName).path
            if let initSize = (try? FileManager.default.attributesOfItem(atPath: initPath)[.size] as? Int64), initSize > 0 {
                receivedBytes += initSize
            }
        }
        for name in plan.segmentFileNames {
            let path = directory.appending(path: name).path
            if FileManager.default.fileExists(atPath: path) {
                existingNames.insert(name)
                if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64), size > 0 {
                    receivedBytes += size
                }
            }
        }
        var completed = existingNames.count
        if !existingNames.isEmpty, total > 0 {
            onProgress(DownloadProgress(
                receivedBytes: receivedBytes,
                totalBytes: 0,
                fraction: Double(completed) / Double(total)
            ))
        }

        let limit = max(1, segmentConcurrency)
        try await withThrowingTaskGroup(of: (bytes: Int64, wasExisting: Bool).self) { group in
            var iterator = zip(plan.segmentURLs, plan.segmentFileNames).makeIterator()
            var running = 0

            func addNext() -> Bool {
                guard let (segmentURL, name) = iterator.next() else { return false }
                let target = directory.appending(path: name)
                group.addTask {
                    if cancellation.isCancelled { throw DownloadEngineError.cancelled }
                    if FileManager.default.fileExists(atPath: target.path) {
                        // 已经在盘上：不重下，也不再加数（上面已经算过了）。
                        return (0, true)
                    }
                    let size = try await self.fetchSegmentToFile(
                        segmentURL,
                        referer: referer,
                        userAgent: userAgent,
                        target: target,
                        cancellation: cancellation
                    )
                    return (size, false)
                }
                running += 1
                return true
            }

            for _ in 0..<limit where addNext() {}

            while running > 0 {
                let result = try await group.next() ?? (0, true)
                running -= 1
                receivedBytes += result.bytes
                if !result.wasExisting { completed += 1 }
                // 进度只报 0…1；切片数算出来的已经是比例，别让调用方再除一次。
                onProgress(DownloadProgress(
                    receivedBytes: receivedBytes,
                    totalBytes: 0,
                    fraction: total > 0 ? min(1, Double(completed) / Double(total)) : 0
                ))
                if cancellation.isCancelled { throw DownloadEngineError.cancelled }
                _ = addNext()
            }
        }

        // 改写一份指向本地分片的播放列表，mpv 直接读它。
        let playlistName = "\(baseName).m3u8"
        let localText = plan.render(initName: initName)
        try localText.write(
            to: directory.appending(path: playlistName),
            atomically: true,
            encoding: .utf8
        )
        return directory.appending(path: playlistName)
    }

    // MARK: - 直链

    private func downloadFile(
        _ url: URL,
        expectedBytes: Int64,
        referer: String?,
        userAgent: String?,
        to directory: URL,
        baseName: String,
        cancellation: CancellationFlag,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let target = directory.appending(path: "\(baseName).\(ext)")
        let resumeURL = directory.appending(path: "\(baseName).\(ext).resume")

        // 已经有同名文件就算下完（大小对得上时）。
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64,
           expectedBytes > 0, size == expectedBytes {
            try? FileManager.default.removeItem(at: resumeURL)
            return target
        }

        var resumeData = try? Data(contentsOf: resumeURL)
        var attempt = 0
        while true {
            do {
                try await fetchToFile(
                    url,
                    referer: referer,
                    userAgent: userAgent,
                    target: target,
                    cancellation: cancellation,
                    expectedBytes: expectedBytes,
                    resumeData: resumeData,
                    resumeSaveURL: resumeURL,
                    onProgress: onProgress
                )
                try? FileManager.default.removeItem(at: resumeURL)
                return target
            } catch let error as DownloadEngineError where error == .cancelled {
                throw error
            } catch {
                if let extracted = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   !extracted.isEmpty {
                    resumeData = extracted
                    try? extracted.write(to: resumeURL, options: .atomic)
                } else if resumeData != nil {
                    // 续传数据失效（如服务端返回 403/416）时清空，下一轮回退到完整新请求。
                    resumeData = nil
                    try? FileManager.default.removeItem(at: resumeURL)
                }
                attempt += 1
                if attempt >= maxRetries || cancellation.isCancelled {
                    throw error
                }
            }
        }
    }

    // MARK: - 单个文件

    /// 一个 URL 一个任务，落到 `target`（可选从 `resumeData` 断点续传，暂停时把进度存回 `resumeSaveURL`）。
    private func fetchToFile(
        _ url: URL,
        referer: String?,
        userAgent: String?,
        target: URL,
        cancellation: CancellationFlag,
        expectedBytes: Int64 = -1,
        resumeData: Data? = nil,
        resumeSaveURL: URL? = nil,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: url)
        apply(headers: request, referer: referer, userAgent: userAgent)
        if let referer, !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        applyCookie(to: &request, url: url)

        let size = try await runDownloadTask(
            request: request,
            resumeData: resumeData,
            resumeSaveURL: resumeSaveURL,
            target: target,
            expectedBytes: expectedBytes,
            cancellation: cancellation,
            onProgress: onProgress
        )
        if let onProgress {
            onProgress(DownloadProgress(receivedBytes: size, totalBytes: size, fraction: 1))
        }
    }

    /// 交给系统级后台 `URLSession`（`BackgroundDownloadSession.shared`）执行下载：
    /// App 退后台或锁屏后由系统 `nsurlsessiond` 接管续传，并在会话级 delegate 里实时回传字节进度与保存续传数据。
    private func runDownloadTask(
        request: URLRequest,
        resumeData: Data?,
        resumeSaveURL: URL?,
        target: URL,
        expectedBytes: Int64,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> Int64 {
        try await BackgroundDownloadSession.shared.download(
            request: request,
            resumeData: resumeData,
            resumeSaveURL: resumeSaveURL,
            targetURL: target,
            expectedBytes: expectedBytes,
            cancellation: cancellation,
            onProgress: onProgress
        )
    }

    /// 分片下来直接写盘，不报进度（一集的总进度按片数算，由调用方汇总）。
    private func fetchSegmentToFile(
        _ url: URL,
        referer: String?,
        userAgent: String?,
        target: URL,
        cancellation: CancellationFlag
    ) async throws -> Int64 {
        var lastError: Error = DownloadEngineError.notMedia
        for _ in 0..<maxRetries {
            do {
                try await fetchToFile(
                    url,
                    referer: referer,
                    userAgent: userAgent,
                    target: target,
                    cancellation: cancellation
                )
                return (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            } catch let error as DownloadEngineError where error == .cancelled {
                throw error
            } catch {
                lastError = error
                if cancellation.isCancelled { throw DownloadEngineError.cancelled }
            }
        }
        throw lastError
    }

    private func fetchText(_ url: URL, referer: String?, userAgent: String?) async throws -> String {
        var request = URLRequest(url: url)
        apply(headers: request, referer: referer, userAgent: userAgent)
        if let referer, !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        applyCookie(to: &request, url: url)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadEngineError.badStatus(http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func apply(headers request: URLRequest, referer: String?, userAgent: String?) {
        // 占位：header 在上面逐个设，保留这个入口方便以后统一加。
        _ = request
        _ = referer
        _ = userAgent
    }

    private let sessionProvider = ProxyAwareURLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        // 并发由我们自己的信号量控制，别让系统的每主机上限再压一层。
        config.httpMaximumConnectionsPerHost = 10
        KazumiNetworkPolicy.applyProxy(to: config)
        return config
    }

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private var session: URLSession { sessionProvider.session }
}

/// 全局后台下载会话：使用 `URLSessionConfiguration.background(withIdentifier:)` 与会话级 delegate，
/// 让 iOS 在 App 退后台/锁屏后继续由 `nsurlsessiond` 持续拉取视频与分片，并在暂停时等续传数据落盘后再结束任务。
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.linkpass.kazumi.download.background"
    static let shared = BackgroundDownloadSession()

    private final class TaskEntry: @unchecked Sendable {
        let task: URLSessionDownloadTask
        let targetURL: URL
        let resumeSaveURL: URL?
        let expectedBytes: Int64
        let onProgress: (@Sendable (DownloadProgress) -> Void)?
        let cancellation: CancellationFlag
        var cancelToken: UUID?
        var continuation: CheckedContinuation<Int64, Error>?
        var finishOutcome: Result<Int64, Error>?
        var didRequestCancel = false
        var waitingForResumeDataFlush = false
        var didComplete = false
        var pendingCompletionError: Error?
        var lastReportedBytes: Int64 = 0
        var lastReportedUptime: TimeInterval = 0

        init(
            task: URLSessionDownloadTask,
            targetURL: URL,
            resumeSaveURL: URL?,
            expectedBytes: Int64,
            onProgress: (@Sendable (DownloadProgress) -> Void)?,
            cancellation: CancellationFlag
        ) {
            self.task = task
            self.targetURL = targetURL
            self.resumeSaveURL = resumeSaveURL
            self.expectedBytes = expectedBytes
            self.onProgress = onProgress
            self.cancellation = cancellation
        }
    }

    private let lock = NSLock()
    private var entries: [Int: TaskEntry] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.httpMaximumConnectionsPerHost = 10
        KazumiNetworkPolicy.applyProxy(to: config)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// 供 `KazumiAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` 接入。
    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        // 确保后台 session 已初始化并重新绑定代理以接收待投递事件。
        _ = session
    }

    func download(
        request: URLRequest,
        resumeData: Data?,
        resumeSaveURL: URL?,
        targetURL: URL,
        expectedBytes: Int64,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> Int64 {
        if cancellation.isCancelled || Task.isCancelled {
            throw DownloadEngineError.cancelled
        }

        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }

        let entry = TaskEntry(
            task: task,
            targetURL: targetURL,
            resumeSaveURL: resumeSaveURL,
            expectedBytes: expectedBytes,
            onProgress: onProgress,
            cancellation: cancellation
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                entry.continuation = continuation
                entries[task.taskIdentifier] = entry
                lock.unlock()

                let token = cancellation.addCancelHandler { [weak self] in
                    self?.cancelEntry(taskID: task.taskIdentifier)
                }
                lock.lock()
                entry.cancelToken = token
                lock.unlock()

                if cancellation.isCancelled || Task.isCancelled {
                    cancelEntry(taskID: task.taskIdentifier)
                } else {
                    task.resume()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelEntry(taskID: task.taskIdentifier)
        }
    }

    private func cancelEntry(taskID: Int) {
        let entry: TaskEntry?
        var shouldSaveResume = false
        lock.lock()
        entry = entries[taskID]
        if let entry, !entry.didRequestCancel {
            entry.didRequestCancel = true
            shouldSaveResume = entry.resumeSaveURL != nil
            if shouldSaveResume {
                entry.waitingForResumeDataFlush = true
            }
        } else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let entry else { return }
        if let saveURL = entry.resumeSaveURL, shouldSaveResume {
            entry.task.cancel { [weak self] data in
                if let data, !data.isEmpty {
                    try? data.write(to: saveURL, options: .atomic)
                }
                self?.markResumeDataFlushed(taskID: taskID)
            }
        } else {
            entry.task.cancel()
        }
    }

    private func markResumeDataFlushed(taskID: Int) {
        var toResume: CheckedContinuation<Int64, Error>?
        var completionError: Error?
        var finishOutcome: Result<Int64, Error>?
        var wasCancelled = false
        var cancelToken: UUID?
        var cancellation: CancellationFlag?

        lock.lock()
        if let entry = entries[taskID] {
            entry.waitingForResumeDataFlush = false
            if entry.didComplete {
                toResume = entry.continuation
                entry.continuation = nil
                completionError = entry.pendingCompletionError
                finishOutcome = entry.finishOutcome
                wasCancelled = entry.cancellation.isCancelled || entry.didRequestCancel
                cancelToken = entry.cancelToken
                cancellation = entry.cancellation
                entries.removeValue(forKey: taskID)
            }
        }
        lock.unlock()

        if let cancelToken, let cancellation {
            cancellation.removeCancelHandler(cancelToken)
        }
        if let toResume {
            resumeContinuation(toResume, error: completionError, outcome: finishOutcome, wasCancelled: wasCancelled)
        }
    }

    private func resolveTotalBytes(
        task: URLSessionDownloadTask,
        expectedBytes: Int64,
        expectedToWrite: Int64
    ) -> Int64 {
        if expectedToWrite > 0 { return expectedToWrite }
        if let http = task.response as? HTTPURLResponse {
            let fromHeader = DownloadEngine.totalContentBytes(from: http)
            if fromHeader > 0 { return fromHeader }
        }
        return expectedBytes > 0 ? expectedBytes : -1
    }

    private func emitProgress(
        for entry: TaskEntry,
        written: Int64,
        expectedToWrite: Int64,
        force: Bool = false
    ) {
        guard let onProgress = entry.onProgress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = force
            || entry.lastReportedUptime == 0
            || written - entry.lastReportedBytes >= 256 * 1024
            || now - entry.lastReportedUptime >= 0.25
        if shouldReport {
            entry.lastReportedBytes = written
            entry.lastReportedUptime = now
        }
        lock.unlock()
        guard shouldReport else { return }

        let total = resolveTotalBytes(
            task: entry.task,
            expectedBytes: entry.expectedBytes,
            expectedToWrite: expectedToWrite
        )
        onProgress(DownloadProgress(
            receivedBytes: written,
            totalBytes: total,
            fraction: total > 0 ? min(1, Double(written) / Double(total)) : -1
        ))
    }

    private func resumeContinuation(
        _ pending: CheckedContinuation<Int64, Error>,
        error: Error?,
        outcome: Result<Int64, Error>?,
        wasCancelled: Bool
    ) {
        if let error {
            if wasCancelled || (error as? URLError)?.code == .cancelled {
                pending.resume(throwing: DownloadEngineError.cancelled)
            } else {
                pending.resume(throwing: error)
            }
            return
        }
        switch outcome {
        case .success(let size):
            pending.resume(returning: size)
        case .failure(let moveError):
            pending.resume(throwing: moveError)
        case .none:
            pending.resume(throwing: URLError(.cannotWriteToFile))
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        let entry = lock.withLock { entries[downloadTask.taskIdentifier] }
        guard let entry else { return }
        if entry.cancellation.isCancelled {
            cancelEntry(taskID: downloadTask.taskIdentifier)
            return
        }
        emitProgress(
            for: entry,
            written: fileOffset,
            expectedToWrite: expectedTotalBytes,
            force: true
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let entry = lock.withLock { entries[downloadTask.taskIdentifier] }
        guard let entry else { return }
        if entry.cancellation.isCancelled {
            cancelEntry(taskID: downloadTask.taskIdentifier)
            return
        }
        emitProgress(
            for: entry,
            written: totalBytesWritten,
            expectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let entry = lock.withLock { entries[downloadTask.taskIdentifier] }
        guard let entry else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            lock.withLock { entry.finishOutcome = .failure(DownloadEngineError.badStatus(http.statusCode)) }
            return
        }
        if entry.cancellation.isCancelled {
            try? FileManager.default.removeItem(at: location)
            lock.withLock { entry.finishOutcome = .failure(DownloadEngineError.cancelled) }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        do {
            try? FileManager.default.removeItem(at: entry.targetURL)
            try FileManager.default.moveItem(at: location, to: entry.targetURL)
            lock.withLock { entry.finishOutcome = .success(size) }
        } catch {
            lock.withLock { entry.finishOutcome = .failure(error) }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        var toResume: CheckedContinuation<Int64, Error>?
        var outcome: Result<Int64, Error>?
        var wasCancelled = false
        var cancelToken: UUID?
        var cancellation: CancellationFlag?

        lock.lock()
        if let entry = entries[task.taskIdentifier] {
            // 若因系统中断或网络错误附带了续传数据，顺手落盘避免丢进度。
            if let saveURL = entry.resumeSaveURL,
               let nsError = error as NSError?,
               let extracted = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !extracted.isEmpty {
                try? extracted.write(to: saveURL, options: .atomic)
            }
            entry.didComplete = true
            entry.pendingCompletionError = error
            if !entry.waitingForResumeDataFlush {
                toResume = entry.continuation
                entry.continuation = nil
                outcome = entry.finishOutcome
                wasCancelled = entry.cancellation.isCancelled || entry.didRequestCancel
                cancelToken = entry.cancelToken
                cancellation = entry.cancellation
                entries.removeValue(forKey: task.taskIdentifier)
            }
        }
        lock.unlock()

        if let cancelToken, let cancellation {
            cancellation.removeCancelHandler(cancelToken)
        }
        if let toResume {
            resumeContinuation(toResume, error: error, outcome: outcome, wasCancelled: wasCancelled)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (() -> Void)? = lock.withLock {
            let current = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return current
        }
        guard let handler else { return }
        DispatchQueue.main.async {
            handler()
        }
    }
}
