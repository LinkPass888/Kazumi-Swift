//
//  KazumiImageCache.swift
//  Kazumi
//
//  网络图片缓存，对应原版 lib/bean/card/network_img_layer.dart 依赖的
//  CachedNetworkImage（磁盘 + 内存两级缓存）：
//
//   * 磁盘层：按图片 URL 落盘，键就是那个地址，不掺别的；
//   * 内存层 NSCache：滚动时立刻拿到首帧，不出现「灰块 → 图片」的闪动；
//   * 解码按显示尺寸做（对应原版的 memCacheWidth / memCacheHeight）——
//     整张原图解码一张就几十 MB，一屏几十张会把内存缓存挤爆，刚存进去
//     的图立刻被淘汰，视图拿不到就永久停在占位图上；
//   * 同一个 URL 的并发请求合并成一次（single flight）；
//   * 失败不记账、不留状态：取不到就画占位，下次显示再取一次。
//
//  Swift 6 严格并发下 UIImage 不作为值跨隔离域传递：加载方法只负责把图片放进
//  NSCache 并返回是否成功，视图再用同步方法从缓存里取。
//

import CryptoKit
import Foundation
import ImageIO
import UIKit

/// 两级图片缓存。NSCache 本身线程安全，因此这个类型可以安全地被并发访问。
final class KazumiImageLoader: @unchecked Sendable {
    static let shared = KazumiImageLoader()

    /// 磁盘缓存上限（字节）。
    ///
    /// LP 3442：首启就要缓存 200 多 M，原版（main）才一百多。除了这里给的额度，
    /// 更主要的原因是同一张图被存了两份——我们自己按 URL 落盘一份，URLSession
    /// 的 URLCache 又按 HTTP 缓存落一份（下面磁盘 256MB 那层）。那一层已经去掉，
    /// 这里也从 300MB 收到 120MB，比原版略宽。
    private static let maxDiskBytes = 120 * 1024 * 1024
    /// 没量到尺寸时按这个像素解码（约等于一张列表封面的两倍）。
    private static let defaultPixelSize = 600

    /// 屏幕倍率。屏幕倍率只能在主线程读，而尺寸换算要在解码前后随时算，
    /// 所以由场景代理在窗口就绪时写一次进来（iOS 26 起 `UIScreen.main` 已弃用）。
    nonisolated(unsafe) static var screenScale: CGFloat = 3

    /// 内存里存图 + 它当时的解码档位。同一张图只留一份：预取按 600 解的那份
    /// 可以直接给 300 档的小卡片用，不会因为档位不同而互相看不到。
    private final class Entry {
        let image: UIImage
        let bucket: Int
        init(image: UIImage, bucket: Int) {
            self.image = image
            self.bucket = bucket
        }
    }

    private let memory = NSCache<NSString, Entry>()
    private let lock = NSLock()
    /// 在途下载。用它按身份比较，只有「真的在等这个任务」的调用方会在结束后
    /// 把自己那条摘掉，任务体本身不碰这张表（否则直接 fetch 的路径会把别人的
    /// 登记删掉，同一个地址被重复下载、把闸门占满）。
    private final class InFlight {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
    }
    private var inFlight: [String: InFlight] = [:]
    private let directory: URL
    /// 旧版本用过的目录：只读回退，避免升级后明明有缓存却全部重新下载。
    private let legacyDirectories: [URL]
    private let sessionProvider: ProxyAwareURLSession
    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private var session: URLSession { sessionProvider.session }
    /// 同时在跑的下载上限。一屏几十张图全放出去，连接会被自己挤爆、
    /// 单张动不动失败，表现就是「总有封面加载不出来」（LP 3446）。
    private let gate = DownloadGate(limit: 6)
    /// 写盘计数，够一批就检查一次容量（原来只在启动时检查）。
    private let pruneCounter = Counter()


    private init() {
        // 首选 App 启动时已经建好的存储根（Application Support/Kazumi/images），
        // 它比这里自己拼路径更可靠；其余几个位置按顺序兜底。
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let candidates: [(String, URL?)] = [
            (String(localized: "准备好的目录"), support?.appendingPathComponent("Kazumi/images", isDirectory: true)),
            ("Application Support", support?.appendingPathComponent("Kazumi/Images", isDirectory: true)),
            ("Caches", caches?.appendingPathComponent("Kazumi/Images", isDirectory: true)),
            ("Documents", documents?.appendingPathComponent("Kazumi/Images", isDirectory: true)),
            (String(localized: "临时目录"), URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KazumiImages", isDirectory: true)),
        ]
        // 逐个试写，用第一个真能写的位置：Application Support 下的子目录
        // 在某些容器里建不出来（大小写不同的同名目录冲突），写盘会一直失败。
        let candidateURLs = candidates.compactMap { $0.1 }
        var chosen: URL?
        for (_, target) in candidates {
            guard let target else { continue }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let probe = target.appendingPathComponent(".probe")
                try Data([0x01]).write(to: probe)
                try? FileManager.default.removeItem(at: probe)
                chosen = target
                break
            } catch {
                continue
            }
        }
        directory = chosen ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let chosenPath = directory.standardizedFileURL.path
        legacyDirectories = candidateURLs.filter {
            $0.standardizedFileURL.path != chosenPath
                && FileManager.default.fileExists(atPath: $0.path)
        }

        memory.countLimit = 600
        // 按显示尺寸解码之后，一张列表封面在内存里只有几百 KB，128 MB 足够
        // 装下整屏加上前后几屏，滚动回来不必重新解码。
        memory.totalCostLimit = 128 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        // 不再要 URLSession 自己那份缓存：它存的是同一批图片字节，
        // 磁盘上会跟下面按 URL 落盘的文件重复一遍（LP 3442 说的 200 多 M）。
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        sessionProvider = ProxyAwareURLSession {
            KazumiNetworkPolicy.applyProxy(to: configuration)
            return configuration
        }

        // 启动时检查一轮容量；放后台，不阻塞首屏。
        let target = directory
        Task.detached(priority: .utility) {
            KazumiImageLoader.prune(directory: target)
        }
    }

    // MARK: - 尺寸

    /// 把视图尺寸换算成解码像素：按屏幕倍率放大，夹在 120…1600 之间。
    static func pixelSize(for size: CGSize) -> Int {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return defaultPixelSize }
        let pixels = Int((longest * screenScale).rounded(.up))
        return min(max(pixels, 120), 1600)
    }

    /// 解码档位：同一张图在小卡片和大封面上分别解一份，按 100 像素归档。
    private static func bucket(_ pixelSize: Int) -> Int {
        max(120, (pixelSize / 100) * 100)
    }

    private static func memoryKey(_ key: String, bucket: Int) -> String {
        "\(key)#\(bucket)"
    }

    /// 够用的档位：命中比需要的略小一档（差 100 像素以内）也认，避免
    /// 300 档的图服务不了 400 档的视图、白解一次。
    private static func satisfies(_ entry: Entry, bucket: Int) -> Bool {
        entry.bucket + 100 >= bucket
    }

    // MARK: - 同步读内存

    /// 已解码好的图片，命中时视图可以直接当首帧画出来。
    func cachedImage(for url: String, pixelSize: Int) -> UIImage? {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return nil }
        let bucket = Self.bucket(pixelSize)
        let exact = memory.object(forKey: Self.memoryKey(key, bucket: bucket) as NSString)
        if let exact { return exact.image }
        // 档位不同：看看有没有更大的一份，或者略小一点还能用的。
        for candidate in stride(from: bucket + 100, through: bucket + 400, by: 100) {
            if let entry = memory.object(forKey: Self.memoryKey(key, bucket: candidate) as NSString) {
                return entry.image
            }
        }
        for candidate in stride(from: bucket - 100, through: max(100, bucket - 300), by: -100) {
            if let entry = memory.object(forKey: Self.memoryKey(key, bucket: candidate) as NSString),
               Self.satisfies(entry, bucket: bucket) {
                return entry.image
            }
        }
        return nil
    }

    /// 把一个远端地址换算成缓存键（同时做 http -> https 的归一）。
    static func cacheKey(for url: String) -> String {
        normalizedURLString(url)
    }

    /// Bangumi 图床会给出 http / 协议相对地址，统一补成 https 后再算键，
    /// 这样同一张图不会因为地址写法不同而缓存两份。
    static func normalizedURLString(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") {
            return "https://" + trimmed.dropFirst("http://".count)
        }
        return trimmed
    }

    // MARK: - 异步加载

    /// 确保这个地址的图片已经进入内存缓存。返回 true 表示可以立刻取图。
    ///
    /// 同一个地址上已经在跑的请求会被复用；调用方（视图的 `.task`）被取消时
    /// 不会连带取消下载 —— 图还是要落盘，下次滚动回来才能直接命中。
    @discardableResult
    func load(_ url: String, pixelSize: Int = defaultPixelSize) async -> Bool {
        await load(url, pixelSize: pixelSize, highPriority: true)
    }

    /// 只查本地：内存命中直接返回，否则从磁盘解码。绝不发网络请求。
    ///
    /// 追番页用它先把已有缓存并行铺出来；网络回源另走 `loadSequentially`。
    @discardableResult
    func loadFromDisk(_ url: String, pixelSize: Int = defaultPixelSize) async -> Bool {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return false }
        if cachedImage(for: url, pixelSize: pixelSize) != nil { return true }
        return await loadFromDisk(key: key, bucket: Self.bucket(pixelSize))
    }

    /// 列表专用：按调用顺序一次只取一张，失败也只试一次，避免一张坏图卡住整队。
    /// 本地缓存仍然优先，因此串行只约束真正的网络回源。
    @discardableResult
    func loadSequentially(_ url: String, pixelSize: Int = defaultPixelSize) async -> Bool {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return false }
        if cachedImage(for: url, pixelSize: pixelSize) != nil { return true }
        await fetch(key: key, bucket: Self.bucket(pixelSize), highPriority: false)
        return cachedImage(for: url, pixelSize: pixelSize) != nil
    }

    @discardableResult
    private func load(_ url: String, pixelSize: Int, highPriority: Bool) async -> Bool {
        let key = Self.cacheKey(for: url)
        guard !key.isEmpty else { return false }
        let bucket = Self.bucket(pixelSize)
        if cachedImage(for: url, pixelSize: pixelSize) != nil { return true }

        let box: InFlight = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let created = InFlight(Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.fetch(key: key, bucket: bucket, highPriority: highPriority)
            })
            inFlight[key] = created
            return created
        }
        await box.task.value
        lock.withLock { if inFlight[key] === box { inFlight[key] = nil } }
        if cachedImage(for: url, pixelSize: pixelSize) != nil { return true }

        // 那个任务按别的档位解的（例如预取用的是 600，这张要 800）：再解一次。
        //
        // LP 3457：这一步原来无条件用高优先级，于是**预取失败也会升级成三条
        // 高优先级的重试**。换一天要预取一百多张，网络一抖就有上百个高优先级
        // 请求排在闸门里，屏幕里要显示的封面全被压在后面——表现就是「封面一直
        // 不出来、也不重新加载」。预取就让它失败，别抢屏幕的队。
        guard highPriority else { return false }
        await fetch(key: key, bucket: bucket, highPriority: true)
        return cachedImage(for: url, pixelSize: pixelSize) != nil
    }

    /// 预取：给列表里即将出现的图片预热缓存，不阻塞调用方。
    ///
    /// LP 3492：这条原来「不按屏幕内优先」。原因不在闸门的排序，而在这里——
    /// 预取一上来就给每一张都登记一个在途任务，视图真要显示某张时，`load`
    /// 发现同一张已经在途，就直接 `await` 预取那个任务。预取是低优先级、
    /// 排在几十张后面，屏幕里那张也就跟着排在后面，它自己的高优先级根本没机会用。
    ///
    /// 现在预取**不登记在途、也不占名额**：只有闸门空着（没有高优先级在等、
    /// 还有空位）才下下一张，屏幕里的请求随时能插到前面。URL 按显示顺序传进来，
    /// 屏幕上那几张就先取。
    func prefetch(_ urls: [String], pixelSize: Int = defaultPixelSize) {
        guard !urls.isEmpty else { return }
        let bucket = Self.bucket(pixelSize)
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for url in urls {
                if Task.isCancelled { return }
                let key = Self.cacheKey(for: url)
                guard !key.isEmpty else { continue }
                if self.cachedImage(for: url, pixelSize: pixelSize) != nil { continue }
                // 屏幕里有东西在等，就先让路；别自己先占满名额再让屏幕排后面。
                while await self.gate.shouldHoldPrefetch() {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                await self.fetch(key: key, bucket: bucket, highPriority: false)
            }
        }
    }

    private func fetch(key: String, bucket: Int, highPriority: Bool) async {
        // 1. 磁盘：命中的是原图字节，再按当前显示尺寸解码。
        if await loadFromDisk(key: key, bucket: bucket) { return }

        // 2. 网络
        guard let logical = URL(string: key) else { return }
        let remote = BangumiImageRewriter.rewritten(logical)

        // 屏幕里要显示的多给两次机会并退避；预取的只试一次，把连接让出来。
        let attempts = highPriority ? 3 : 1
        for attempt in 0..<attempts {
            // 下载前先过闸门：同时最多 6 条，屏幕内的先拿。
            await gate.acquire(high: highPriority)
            let outcome: (Data?, Bool)
            do {
                let (data, response) = try await session.data(from: remote)
                let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? true
                outcome = (ok ? data : nil, ok)
            } catch {
                outcome = (nil, false)
            }
            await gate.release()

            if let data = outcome.0 {
                guard let image = await Self.decode(data, pixelSize: bucket) else { return }
                store(image, key: key, bucket: bucket)
                do {
                    try ensureDirectory()
                    let fileURL = directory.appendingPathComponent(Self.fileName(for: key))
                    try data.write(to: fileURL, options: .atomic)
                    schedulePruneIfNeeded()
                } catch {
                    // 写盘失败不影响这次显示，下次再取。
                }
                return
            }
            guard attempt < attempts - 1 else { return }
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
    }

    private func loadFromDisk(key: String, bucket: Int) async -> Bool {
        let name = Self.fileName(for: key)
        let canonical = directory.appendingPathComponent(name)
        for fileURL in [canonical] + legacyDirectories.map({ $0.appendingPathComponent(name) }) {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            if let image = await Self.decode(data, pixelSize: bucket) {
                store(image, key: key, bucket: bucket)
                if fileURL != canonical {
                    try? ensureDirectory()
                    try? FileManager.default.copyItem(at: fileURL, to: canonical)
                }
                return true
            }
            // 文件坏了就删掉，别一直拿它解码失败。
            try? FileManager.default.removeItem(at: fileURL)
        }
        return false
    }

    /// 每写满一批就检查一次容量：原来只在启动时检查，用起来只涨不降。
    private func schedulePruneIfNeeded() {
        let count = pruneCounter.increment()
        guard count % 40 == 0 else { return }
        let target = directory
        Task.detached(priority: .utility) {
            KazumiImageLoader.prune(directory: target)
        }
    }

    private func store(_ image: UIImage, key: String, bucket: Int) {
        let scale = image.scale
        let cost = Int(image.size.width * image.size.height * scale * scale * 4)
        memory.setObject(Entry(image: image, bucket: bucket), forKey: Self.memoryKey(key, bucket: bucket) as NSString, cost: cost)
    }

    /// 按显示尺寸解码（对应原版的 memCacheWidth / memCacheHeight）：
    /// 只解出这么大的位图，内存和耗时都小一个数量级。
    ///
    /// 用 ImageIO 直接出缩略图，而不是先 UIImage(data:) 再缩 —— 后者要先把整张
    /// 原图解码出来，正是「一屏几十张就把内存挤爆」的来源。
    private static func decode(_ data: Data, pixelSize: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> DecodeResult in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return DecodeResult(image: nil)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, pixelSize),
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return DecodeResult(image: UIImage(cgImage: cgImage))
            }
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return DecodeResult(image: UIImage(cgImage: cgImage))
            }
            return DecodeResult(image: nil)
        }.value.image
    }

    /// 解码结果。UIImage 不是 Sendable，用一个带 @unchecked 的盒子从后台线程带回来。
    private struct DecodeResult: @unchecked Sendable {
        var image: UIImage?
    }

    // MARK: - 诊断

    /// 缓存目录可能在初始化时没建成（或事后被系统清理），写盘前再确认一次。
    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 维护

    /// 清空两级缓存（设置页「清除图片缓存」用）。
    func clear() {
        memory.removeAllObjects()
        let targets = [directory] + legacyDirectories
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            for target in targets {
                guard let files = try? manager.contentsOfDirectory(
                    at: target,
                    includingPropertiesForKeys: nil
                ) else { continue }
                for file in files {
                    try? manager.removeItem(at: file)
                }
            }
        }
    }

    /// 磁盘缓存占用（字节）。
    func diskSizeInBytes() async -> Int {
        let targets = [directory] + legacyDirectories
        return await Task.detached(priority: .utility) { () -> Int in
            let manager = FileManager.default
            var total = 0
            for target in targets {
                guard let files = try? manager.contentsOfDirectory(
                    at: target,
                    includingPropertiesForKeys: [.fileSizeKey]
                ) else { continue }
                for file in files {
                    total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            }
            return total
        }.value
    }

    /// 只按容量淘汰，不再按天数整批过期。
    private static func prune(directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var survivors: [(url: URL, date: Date, size: Int)] = []
        var total = 0

        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            survivors.append((file, date, size))
            total += size
        }

        guard total > maxDiskBytes else { return }
        for entry in survivors.sorted(by: { $0.date < $1.date }) {
            guard total > maxDiskBytes else { break }
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - 并发闸门

    /// 一个带优先级的上限闸门：高优先（屏幕里要显示的）先拿名额，
    /// 低优先（预取）在后面排队。名额让出去时直接转交给等待者，
    /// 因此 active 只在「没人等」时才减一。
    actor DownloadGate {
        private let limit: Int
        private var active = 0
        private var highWaiters: [CheckedContinuation<Void, Never>] = []
        private var lowWaiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) {
            self.limit = limit
        }

        /// 预取该不该让路：有高优先级在排队、或名额已经占满，就先别动。
        func shouldHoldPrefetch() -> Bool {
            !highWaiters.isEmpty || active >= limit
        }

        func acquire(high: Bool) async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { continuation in
                if high {
                    highWaiters.append(continuation)
                } else {
                    lowWaiters.append(continuation)
                }
            }
        }

        func release() {
            if !highWaiters.isEmpty {
                highWaiters.removeFirst().resume()
            } else if !lowWaiters.isEmpty {
                lowWaiters.removeFirst().resume()
            } else {
                active = max(0, active - 1)
            }
        }
    }

    /// 数写盘次数用的小盒子。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    // MARK: - 文件名

    /// 用 URL 的 SHA256 做文件名：长度固定、不含路径分隔符，也避免中文/特殊字符。
    private static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
