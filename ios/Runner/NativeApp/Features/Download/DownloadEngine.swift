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
        let finalURL = (response as? HTTPURLResponse)?.url ?? url
        let text = String(data: prefix, encoding: .utf8) ?? ""
        let contentType = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksHLS = text.hasPrefix("#EXTM3U")
            || finalURL.path.contains(".m3u8")
            || url.absoluteString.contains(".m3u8")
            || contentType.contains("mpegurl")
        if looksHLS {
            return Probe(kind: .hls(finalURL), prefixText: text)
        }
        return Probe(kind: .file(finalURL, (response as? HTTPURLResponse)?.expectedContentLength ?? -1), prefixText: text)
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

        // 已经有同名文件就算下完（大小对得上时）。
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64,
           expectedBytes > 0, size == expectedBytes {
            return target
        }

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
                    onProgress: onProgress
                )
                return target
            } catch let error as DownloadEngineError where error == .cancelled {
                throw error
            } catch {
                attempt += 1
                if attempt >= maxRetries || cancellation.isCancelled {
                    throw error
                }
            }
        }
    }

    // MARK: - 单个文件

    /// 一个 URL 一个任务，落到 `target`。
    private func fetchToFile(
        _ url: URL,
        referer: String?,
        userAgent: String?,
        target: URL,
        cancellation: CancellationFlag,
        expectedBytes: Int64 = -1,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: url)
        apply(headers: request, referer: referer, userAgent: userAgent)
        if let referer, !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        applyCookie(to: &request, url: url)

        let progressSink = ProgressSink(
            expectedBytes: expectedBytes,
            onProgress: onProgress,
            cancellation: cancellation
        )
        let (tempURL, response) = try await session.download(for: request, delegate: progressSink)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadEngineError.badStatus(http.statusCode)
        }
        if cancellation.isCancelled {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadEngineError.cancelled
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        // 小分片直接覆盖；大文件也已经下全了，一样覆盖。
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tempURL, to: target)
        if let onProgress {
            onProgress(DownloadProgress(receivedBytes: size, totalBytes: size, fraction: 1))
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

    private lazy var sessionProvider = ProxyAwareURLSession {
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

/// 给 `URLSession.download` 报进度用。它只在 session 的 delegate 队列上被调用。
private final class ProgressSink: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onProgress: (@Sendable (DownloadProgress) -> Void)?
    private let cancellation: CancellationFlag
    private var lastReported: Int64 = 0

    init(
        expectedBytes: Int64,
        onProgress: (@Sendable (DownloadProgress) -> Void)?,
        cancellation: CancellationFlag
    ) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.cancellation = cancellation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if cancellation.isCancelled {
            downloadTask.cancel()
            return
        }
        guard let onProgress else { return }
        // 半 MB 报一次就够，界面是进度条，不需要每个字节都刷新。
        guard totalBytesWritten - lastReported >= 512 * 1024 else { return }
        lastReported = totalBytesWritten
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite
            : (expectedBytes > 0 ? expectedBytes : -1)
        onProgress(DownloadProgress(
            receivedBytes: totalBytesWritten,
            totalBytes: total,
            fraction: total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : -1
        ))
    }
}
