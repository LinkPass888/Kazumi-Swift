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

/// 线程安全的取消标记。下载循环在后台线程，用户在界面点取消，靠它传话。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
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
        // 盘上已有的分片（上次下到一半 / 续传）：先算进进度，但不让它们再被计一次。
        // 之前两处都算，续传时同一个分片数了两遍，进度能到 198%（LP 5129）。
        let existingNames = Set(plan.segmentFileNames.filter { name in
            FileManager.default.fileExists(atPath: directory.appending(path: name).path)
        })
        var completed = existingNames.count
        var receivedBytes = Int64(0)
        if !existingNames.isEmpty, total > 0 {
            onProgress(DownloadProgress(
                receivedBytes: 0,
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

    /// 直接使用不带 completionHandler 的 `URLSessionDownloadTask` 并挂载 `task.delegate`：
    /// Swift 标准库的 `session.download(for:delegate:)` 内部自建了完成回调包装器，只会转发 `URLSessionTaskDelegate`
    /// 而不会转发 `URLSessionDownloadDelegate.didWriteData`，会导致直链 MP4 下载全程停在 0% 直至下完跳 100%。
    private func runDownloadTask(
        request: URLRequest,
        resumeData: Data?,
        resumeSaveURL: URL?,
        target: URL,
        expectedBytes: Int64,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> Int64 {
        let currentSession = session
        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            task = currentSession.downloadTask(withResumeData: resumeData)
        } else {
            task = currentSession.downloadTask(with: request)
        }
        let sink = DownloadTaskSink(
            targetURL: target,
            resumeSaveURL: resumeSaveURL,
            expectedBytes: expectedBytes,
            onProgress: onProgress,
            cancellation: cancellation
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sink.start(task: task, continuation: continuation)
            }
        } onCancel: {
            sink.cancelTask(task)
        }
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

/// 接管单个 `URLSessionDownloadTask` 的实时字节进度、临时文件搬运与完成/续传回执。
private final class DownloadTaskSink: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let targetURL: URL
    private let resumeSaveURL: URL?
    private let expectedBytes: Int64
    private let onProgress: (@Sendable (DownloadProgress) -> Void)?
    private let cancellation: CancellationFlag

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var finishOutcome: Result<Int64, Error>?
    private var didRequestCancel = false
    private var lastReportedBytes: Int64 = 0
    private var lastReportedUptime: TimeInterval = 0

    init(
        targetURL: URL,
        resumeSaveURL: URL?,
        expectedBytes: Int64,
        onProgress: (@Sendable (DownloadProgress) -> Void)?,
        cancellation: CancellationFlag
    ) {
        self.targetURL = targetURL
        self.resumeSaveURL = resumeSaveURL
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.cancellation = cancellation
    }

    func start(task: URLSessionDownloadTask, continuation: CheckedContinuation<Int64, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        task.delegate = self
        if cancellation.isCancelled || Task.isCancelled {
            cancelTask(task)
        }
        task.resume()
    }

    func cancelTask(_ task: URLSessionDownloadTask) {
        lock.lock()
        let alreadyCancelling = didRequestCancel
        didRequestCancel = true
        lock.unlock()
        guard !alreadyCancelling else { return }
        if let saveURL = resumeSaveURL {
            task.cancel { data in
                if let data, !data.isEmpty {
                    try? data.write(to: saveURL, options: .atomic)
                }
            }
        } else {
            task.cancel()
        }
    }

    private func resolveTotalBytes(
        task: URLSessionDownloadTask,
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
        task: URLSessionDownloadTask,
        written: Int64,
        expectedToWrite: Int64,
        force: Bool = false
    ) {
        guard let onProgress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = force
            || lastReportedUptime == 0
            || written - lastReportedBytes >= 256 * 1024
            || now - lastReportedUptime >= 0.25
        if shouldReport {
            lastReportedBytes = written
            lastReportedUptime = now
        }
        lock.unlock()
        guard shouldReport else { return }

        let total = resolveTotalBytes(task: task, expectedToWrite: expectedToWrite)
        onProgress(DownloadProgress(
            receivedBytes: written,
            totalBytes: total,
            fraction: total > 0 ? min(1, Double(written) / Double(total)) : -1
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        if cancellation.isCancelled {
            cancelTask(downloadTask)
            return
        }
        emitProgress(
            task: downloadTask,
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
        if cancellation.isCancelled {
            cancelTask(downloadTask)
            return
        }
        emitProgress(
            task: downloadTask,
            written: totalBytesWritten,
            expectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            lock.withLock { finishOutcome = .failure(DownloadEngineError.badStatus(http.statusCode)) }
            return
        }
        if cancellation.isCancelled {
            try? FileManager.default.removeItem(at: location)
            lock.withLock { finishOutcome = .failure(DownloadEngineError.cancelled) }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        do {
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: location, to: targetURL)
            lock.withLock { finishOutcome = .success(size) }
        } catch {
            lock.withLock { finishOutcome = .failure(error) }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let pending: CheckedContinuation<Int64, Error>?
        let outcome: Result<Int64, Error>?
        lock.lock()
        pending = continuation
        continuation = nil
        outcome = finishOutcome
        lock.unlock()

        guard let pending else { return }
        if let error {
            if cancellation.isCancelled || (error as? URLError)?.code == .cancelled {
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
}
