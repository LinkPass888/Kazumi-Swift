//
//  AppEnvironment.swift
//  Kazumi
//
//  应用级依赖装配点（对应原项目的 coreModule）。
//  采用「组合根」模式：所有单例在这里创建，通过 Environment 注入到视图层，
//  Step 2~4 的模块只需要在这里多加一行，视图代码无需感知具体实现。
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppEnvironment {
    struct StartupFailure: Identifiable, Sendable {
        let id = UUID()
        let message: String
    }

    struct LaunchResult {
        let environment: AppEnvironment
        let failure: StartupFailure?
    }

    /// 应用根依赖（与原 coreModule 的单例注册一一对应）。
    let settings: SettingsStore
    /// 下载目录：设置页选的文件夹、播放器落盘、下载列表三处共用一份，
    /// 「落在哪儿」才不会一处一套。
    let downloadDirectory: DownloadDirectoryStore
    let library: LibraryStore
    let router: AppRouter
    let plugins: PluginsController
    let pluginSearch: PluginSearchService
    let updates: AppUpdateService
    /// 追番同步引擎：设置页、详情页与播放器共用一份，三处对「连没连上」才一致。
    let bangumiSync: BangumiSyncEngine
    /// 「自动标记看过」的消费端，播放器把进度喂给它。
    let bangumiProgress: BangumiProgressService
    /// 离线缓存：解析、排队、落盘、记录一份，播放页与下载页共用。
    @MainActor let downloads: DownloadCenter

    @ObservationIgnored private var notificationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherNotificationRefresh = false
    @ObservationIgnored private var watchingChangeDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastNotificationRefreshAt: Date?

    private init(settings: SettingsStore, library: LibraryStore, router: AppRouter) {
        self.settings = settings
        let downloadDirectory = DownloadDirectoryStore(defaults: .standard)
        self.downloadDirectory = downloadDirectory
        self.library = library
        self.router = router
        let plugins = PluginsController()
        plugins.load()
        self.plugins = plugins
        self.pluginSearch = PluginSearchService(plugins: plugins)
        self.updates = AppUpdateService()
        self.bangumiSync = BangumiSyncEngine(settings: settings, library: library)
        self.bangumiProgress = BangumiProgressService(settings: settings)
        // 用局部变量传参：闭包里读 self 的成员会被判成「初始化完成前捕获 self」。
        let store = downloadDirectory
        self.downloads = MainActor.assumeIsolated {
            DownloadCenter(directory: store, plugins: plugins, settings: settings)
        }
        library.onWatchingChanged = { [weak self] in
            self?.scheduleWatchingNotificationRefresh()
        }
    }

    /// 与原 main.dart 一致：先确保存储目录可用，失败时返回错误页而不是崩溃。
    static func makeAtLaunch() -> LaunchResult {
        do {
            try AppEnvironment.prepareStorageDirectories()
            let settings = SettingsStore()
            let library = LibraryStore()
            library.load()
            let router = AppRouter(defaultStartupPage: settings.defaultStartupPage)
            let environment = AppEnvironment(settings: settings, library: library, router: router)
            return LaunchResult(environment: environment, failure: nil)
        } catch {
            KazumiLog.storage.error("存储初始化失败：\(error.localizedDescription, privacy: .public)")
            // 仍然构造一个可用的内存环境，保证错误页能正常渲染。
            let environment = AppEnvironment(
                settings: SettingsStore(defaults: UserDefaults(suiteName: "kazumi.ephemeral") ?? .standard),
                library: LibraryStore(),
                router: AppRouter()
            )
            return LaunchResult(
                environment: environment,
                failure: StartupFailure(message: error.localizedDescription)
            )
        }
    }

    /// Application Support/hive 对应原工程的存储根目录；原生版改为 Application Support/Kazumi。
    static func prepareStorageDirectories() throws {
        // 图片解码要的屏幕倍率由场景代理在窗口就绪时写入（`KazumiImageLoader.screenScale`）：
        // iOS 26 起 `UIScreen.main` 已弃用，倍率要从窗口所在的场景里取，启动这一刻还没有场景。
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appending(path: "Kazumi", directoryHint: .isDirectory)
        let directories = [
            root,
            root.appending(path: "rules", directoryHint: .isDirectory),
            root.appending(path: "cache", directoryHint: .isDirectory),
            root.appending(path: "images", directoryHint: .isDirectory),
            root.appending(path: "snapshots", directoryHint: .isDirectory),
            // 下载目录不再开在 Application Support：「文件」App 看不见那里。
            // 老位置（root/downloads）由 DownloadDirectoryStore 启动时搬进 Documents/Download。
            downloadRoot,
        ]
        for directory in directories where !manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 追番列表（「在看」）变更后轻量防抖自动重排通知，刚追的番无需重启即可进入排程。
    private func scheduleWatchingNotificationRefresh() {
        watchingChangeDebounceTask?.cancel()
        watchingChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.refreshUpdateNotifications()
        }
    }

    /// 回到前台时按需续排（距离上次刷新超过 30 分钟才跑），避免驻留后台多日后 7 天滚动窗口耗尽。
    func refreshUpdateNotificationsOnForegroundIfNeeded() async {
        guard settings.updateNotificationEnabled else { return }
        if let last = lastNotificationRefreshAt, Date().timeIntervalSince(last) < 1_800 {
            return
        }
        await refreshUpdateNotifications()
    }

    /// 等待可能正在防抖或执行中的通知重排完成（打开「查看排程」前调用）。
    func settlePendingUpdateNotifications() async {
        if let debounce = watchingChangeDebounceTask {
            debounce.cancel()
            watchingChangeDebounceTask = nil
            await refreshUpdateNotifications()
            return
        }
        await notificationRefreshTask?.value
    }

    /// 重排番剧更新提醒（设置页改开关、追番列表变动、启动时都走这里）。
    ///
    /// 单飞合并：重叠调用会复用同一条重排任务并在尾部补跑最新状态，防止并发重排互相撤空。
    func refreshUpdateNotifications() async {
        watchingChangeDebounceTask?.cancel()
        watchingChangeDebounceTask = nil

        if let running = notificationRefreshTask {
            needsAnotherNotificationRefresh = true
            await running.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherNotificationRefresh = false
                await self.performUpdateNotificationRefresh()
            } while self.needsAnotherNotificationRefresh
        }
        notificationRefreshTask = task
        await task.value
        notificationRefreshTask = nil
    }

    private func performUpdateNotificationRefresh() async {
        guard settings.updateNotificationEnabled else {
            await UpdateNotificationScheduler.shared.cancelAll()
            lastNotificationRefreshAt = Date()
            return
        }
        let watching = library.entries.filter { $0.collectType == .watching }
        guard !watching.isEmpty else {
            await UpdateNotificationScheduler.shared.cancelAll()
            lastNotificationRefreshAt = Date()
            return
        }
        await BangumiAirTimeService.shared.ensureLoaded(entries: watching)
        await BangumiAirTimeService.shared.ensureAniListLoaded(watching.map(\.id))
        await UpdateNotificationScheduler.shared.reschedule(watching: watching)
        lastNotificationRefreshAt = Date()
    }

    /// App 的 Application Support 目录（唯一出处见 `AppStoragePaths`）。
    nonisolated private static var applicationSupportRoot: URL {
        AppStoragePaths.applicationSupportRoot
    }

    /// App 的「文稿」目录。放进这里的文件在「文件」App 的「我的 iPhone > App 名」下看得见。
    nonisolated private static var documentsRoot: URL {
        (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? storageRoot
    }

    /// 存储根目录（Step 3 的 JSON 存储与 WebDAV 备份都基于它）。
    nonisolated static var storageRoot: URL {
        AppStoragePaths.storageRoot
    }

    /// 图片缓存目录。
    static var imageCacheRoot: URL {
        storageRoot.appending(path: "images", directoryHint: .isDirectory)
    }

    /// 下载目录。
    ///
    /// 必须放在 Documents 里，不能放 Application Support：「文件」App 只能看见
    /// Documents，「我的 iPhone」里才会出现以 App 命名的那个文件夹，下完的东西
    /// 用户才拿得到（LP 5262）。Application Support 下的目录它永远看不见。
    ///
    /// 名字用中文「下载」而不是 Download：外面一层已经叫 Kazumi，里面再叫
    /// Download 会跟系统的下载目录撞（LP 5275，Camo 定名）。
    nonisolated static var downloadRoot: URL {
        documentsRoot.appending(path: "下载", directoryHint: .isDirectory)
    }

    /// 老版本的下载目录（Application Support/Kazumi/downloads）。
    /// 换目录不会自动搬文件，这些文件就留在原地了。
    nonisolated static var legacyDownloadRoot: URL {
        storageRoot.appending(path: "downloads", directoryHint: .isDirectory)
    }

    /// 原版（main）的下载目录：Application Support/downloads，比现在少一层 Kazumi。
    nonisolated static var mainDownloadRoot: URL {
        applicationSupportRoot.appending(path: "downloads", directoryHint: .isDirectory)
    }

    /// 一度用过、现在已经换掉的目录名（Documents/Download）。
    nonisolated static var interimDownloadRoot: URL {
        documentsRoot.appending(path: "Download", directoryHint: .isDirectory)
    }

    /// 旧版本留下的下载目录，现在一个都不用。
    ///
    /// 不搬：原版的落盘形状（一集一个分片目录）和记录（Hive）都跟现在对不上，
    /// 搬过来也认不成「已下载」。所以只在存储页留一个「清除旧版本离线下载」，
    /// 有东西才显示（LP 5280/5281）。
    nonisolated static var legacyDownloadRoots: [URL] {
        [legacyDownloadRoot, mainDownloadRoot, interimDownloadRoot]
    }

    /// 旧下载目录里还剩多少字节。全空时返回 nil，存储页那一行就不出现。
    ///
    /// 只报占用，不报集数：旧目录的形状有两种（原版一集一个分片目录，
    /// 我们那一版一集一堆 ep-3 开头的文件），数集要按前缀归并，
    /// 而 LP 5289 觉得不值当——大小已经够说明「这里有东西可以清」。
    /// 可能扫几百 MB，调用方放后台线程跑。
    nonisolated static func legacyDownloadUsage() -> Int64? {
        let fileManager = FileManager.default
        var bytes: Int64 = 0
        for root in legacyDownloadRoots where root.path != downloadRoot.path {
            guard let shows = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for show in shows {
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: show,
                    includingPropertiesForKeys: nil
                ) else { continue }
                for entry in entries { bytes += directorySize(entry) }
            }
        }
        return bytes > 0 ? bytes : nil
    }

    /// 把旧下载目录整个删掉。
    nonisolated static func clearLegacyDownloads() {
        let fileManager = FileManager.default
        for root in legacyDownloadRoots where root.path != downloadRoot.path {
            try? fileManager.removeItem(at: root)
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let walker = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// 规则目录（内置规则与订阅规则）。
    static var rulesRoot: URL {
        AppStoragePaths.rulesRoot
    }

    /// 检查剩余空间（对应原 iOS 通道的 getAvailableStorage）。
    static func availableDiskSpace() -> Int64 {
        let values = try? storageRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }
}
