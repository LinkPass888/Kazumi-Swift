//
//  DownloadDirectoryStore.swift
//  Kazumi
//
//  下载目录：默认在 Documents/下载（「文件」App 里看得见），
//  用户可以选「文件」App 里的一个文件夹（或 iCloud 盘里的）当下载目录。
//
//  外部目录这次选择给的只是一个临时授权，App 一退出就没了，所以选完立刻
//  做一份安全作用域书签存起来，下次启动用书签换回访问权（原版
//  lib/services/download/download_directory_service.dart 也是这个办法）。
//  书签和路径都不进设置备份：那是这台设备的沙箱状态，拷到别的机器上无效。
//
//  默认目录为什么在 Documents 而不是 Application Support：「文件」App 只能看见
//  Documents，「我的 iPhone」里才会出现以 App 命名的那个文件夹，下完的东西用户
//  才拿得到（LP 5262）。Application Support 下的目录它永远看不见。
//  老版本下在 Application Support（原版还少一层 Kazumi），不搬了：两个版本的
//  落盘形状和记录都对不上，搬过来也认不成「已下载」。旧位置里有东西时，
//  存储页会多一行「清除旧位置的下载」（LP 5280）。
//

import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DownloadDirectoryStore {
    /// 与 main 的 settings 键同名（settings_keys.dart 里的 downloadDirectory /
    /// downloadDirectoryBookmark），这样两版的设置备份里这两个键的口径一致。
    private static let pathKey = "downloadDirectory"
    private static let bookmarkKey = "downloadDirectoryBookmark"

    private let defaults: UserDefaults
    /// 选过的目录路径。书签这次没解析成功时也留着，页面不会在启动那一瞬
    /// 闪回默认位置；真正能不能写由 `hasAccess` 说了算。
    private(set) var savedPath: String
    /// 这次启动有没有真的拿到访问权。
    private(set) var hasAccess = false

    /// 解析成功的外部目录；访问结束时要在 deinit 之前 stop。
    private var scopedURL: URL?
    private var isAccessing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.savedPath = defaults.string(forKey: Self.pathKey) ?? ""
        restoreAccess()
    }

    @MainActor
    deinit {
        // 访问权是常驻的（下载、写入都靠它），实例销毁时得放掉。
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - 当前位置

    /// 现在真正会写进去的目录：外部目录拿到访问权就是它，否则回 Documents/下载。
    var directoryURL: URL {
        if let scopedURL { return scopedURL }
        return Self.defaultDirectory
    }

    /// 页面右侧那行字：这个目录在「文件」App 里长什么样，就照那个写。
    ///
    /// 默认是「我的 iPhone › Kazumi › 下载」，用户照着去「文件」里找就行；
    /// 换过目录就写他选的那个文件夹在「文件」里的位置（LP 5303）。
    var displayName: String {
        guard !savedPath.isEmpty else { return Self.fileAppPath(for: Self.defaultDirectory) }
        return Self.fileAppPath(for: URL(fileURLWithPath: savedPath))
    }

    /// 把沙箱里的真实路径翻译成「文件」App 里看得见的那几层。
    ///
    /// 系统只给真实路径，不会给「文件」里的显示路径，所以只能按位置认：
    ///
    /// - 我们自己容器里的：`NSHomeDirectory()` 之后那几级，前面补
    ///   「我的 iPhone › <应用名>」——「文件」把我们的 Documents 挂在以 App
    ///   命名的那个文件夹下面（磁盘上那一层叫 File Provider Storage，不能直摆）。
    /// - 本机存储里别的文件夹（选择器给的是 App 组容器下的路径）：
    ///   从 `File Provider Storage` 之后那几级照写，前面补「我的 iPhone ›」。
    /// - iCloud 盘：路径里那段 `com~apple~CloudDocs` 对应「iCloud 云盘」。
    /// - 认不出来的（别的 App 的容器）：只写最后两级目录名，前面补一个「…」。
    ///
    /// 底线：UUID 一律不上屏。别的 App 容器那段是
    /// `/var/mobile/Containers/Data/Application/<UUID>/…`，没有任何公开 API 能把
    /// UUID 换回 App 名，露出来只会让人看不懂（Fuck 5305 / Camo 5306）。
    static func fileAppPath(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let components = path.split(separator: "/").map(String.init)

        // 我们自己容器里的。
        // Documents 这一层在「文件」App 里不显示——它的内容直接挂在以 App 命名的
        // 那个文件夹下面，所以要把 Documents 抹掉，否则会多出一层。
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            var rest = path.dropFirst(home.count).split(separator: "/").map(String.init)
            if rest.first == "Documents" { rest.removeFirst() }
            return rest.isEmpty ? appFolderName : ([localRootName, appFolderName] + rest).joined(separator: " › ")
        }

        // iCloud 盘。
        let iCloudMarker = "com~apple~CloudDocs"
        if let markerIndex = components.firstIndex(of: iCloudMarker) {
            let rest = components[(markerIndex + 1)...]
            let tail = rest.count > 2 ? ["…"] + rest.suffix(2) : Array(rest)
            return (["iCloud 云盘"] + tail).joined(separator: " › ")
        }

        // 本机存储（「我的 iPhone」）。系统把这一层放在 App 组容器下面的
        // `File Provider Storage` 里，磁盘上还夹着 `Shared`、`AppGroup`、UUID
        // 这几级，全是系统内部名，一个都不上屏（Camo 5314）。
        // 用户选的是哪一级，就看这个标记后面还剩几级。
        let fileProviderMarker = "File Provider Storage"
        if let markerIndex = components.firstIndex(of: fileProviderMarker) {
            let rest = Array(components[(markerIndex + 1)...])
            return rest.isEmpty ? localRootName : ([localRootName] + rest).joined(separator: " › ")
        }

        // 认不出来：最后两级目录名，UUID 那类目录名不上屏。
        let visible = components.filter { !looksLikeUUID($0) }
        if visible.count <= 2 { return visible.joined(separator: " › ") }
        return "… › " + visible.suffix(2).joined(separator: " › ")
    }

    /// 目录名长得像 UUID 吗（8-4-4-4-12 的十六进制）。
    private static func looksLikeUUID(_ component: String) -> Bool {
        component.count == 36
            && component.filter { $0 == "-" }.count == 4
            && component.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// 「文件」App 里我们的文稿目录挂在一个以 App 命名的文件夹下面。
    static var appFolderName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Kazumi"
    }

    /// 「文件」App 里本机存储那一层的叫法。iPad 上显示的是设备名，我们按 iPhone 口径写。
    private static let localRootName = "我的 iPhone"

    /// 选过一个外部目录（不管这次解析成功没有）。
    var hasCustomSelection: Bool { !savedPath.isEmpty }

    /// 选了目录、但这次没拿到访问权。
    ///
    /// 以前这种情况是静默的：`directoryURL` 悄悄回退到应用内目录，页面右侧还写着
    /// 用户选的那个文件夹名——看上去就是「自定义下载目录不好使」（LP 5218）。
    /// 现在把这个状态摆到页面上，不再默默写去别的地方。
    var customUnavailable: Bool { !savedPath.isEmpty && !hasAccess }

    /// 默认目录。下载列表、播放器落盘都从这里取默认值。
    ///
    /// 固定在 Documents/下载：「文件」App 只能看见 Documents，
    /// 下完的东西要在「我的 iPhone」里拿得到（LP 5262）。
    static var defaultDirectory: URL { AppEnvironment.downloadRoot }

    // MARK: - 选目录

    /// 打开系统的文件夹选择器。选完存路径与书签；取消则什么都不改。
    func choose(completion: ((Result<Void, Error>) -> Void)? = nil) {
        // 面板的起点：App 自己的「文稿」目录（在「文件」App 里就是「我的 iPhone > Kazumi」）。
        // 不给起点就会落在空的「Recents」，那里的「打开」是灰的，点了没反应。
        let start = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))
        DocumentPickerBridge.open(types: [.folder], asCopy: false, startingDirectory: start) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    completion?(.failure(DocumentPickerBridge.PickerError.cancelled))
                    return
                }
                completion?(self.adopt(url))
            case .failure(let error):
                completion?(.failure(error))
            }
        }
    }

    /// 换回应用内目录，并把存下来的路径与书签一起清掉。
    func reset() {
        stopAccessing()
        savedPath = ""
        hasAccess = false
        defaults.removeObject(forKey: Self.pathKey)
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    /// 书签换回访问权。启动时跑一次；换不回来（文件夹被删、盘没挂）就
    /// 退回应用内并忘掉那条路径——留着一个写不进去的目录比退回更糟。
    func restoreAccess() {
        guard let raw = defaults.string(forKey: Self.bookmarkKey), !raw.isEmpty,
              let data = Data(base64Encoded: raw) else {
            if !savedPath.isEmpty { reset() }
            return
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            // iOS 上安全域是书签自带的，不能传 .withSecurityScope（那个选项 macOS 才有）。
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            log("下载目录：书签换不回地址，退回默认位置")
            reset()
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            log("下载目录：书签解析到了但拿不到访问权，退回默认位置")
            reset()
            return
        }
        stopAccessing()
        scopedURL = url
        isAccessing = true
        hasAccess = true
        savedPath = url.path(percentEncoded: false)
        defaults.set(savedPath, forKey: Self.pathKey)
        log("下载目录：书签已接回访问权 \(savedPath)")
        // 书签过期就趁这次有访问权重新做一份，下次启动还能用。
        if stale { persistBookmark(for: url) }
    }

    // MARK: - 内部

    private func adopt(_ url: URL) -> Result<Void, Error> {
        // 之前已经持有这个目录的访问权就别重复开：重复开又不关会漏。
        let alreadyOpen = isAccessing && scopedURL == url
        // 选择器给的是临时授权：先开，开完才能读书签、也才能判断真能不能写。
        // 成功时不当场放掉，由下面接管成常驻。
        let opened = alreadyOpen || url.startAccessingSecurityScopedResource()
        KazumiLogBuffer.storage("下载目录：拿到临时授权=\(opened)，路径 \(url.path(percentEncoded: false))")
        guard opened else {
            return .failure(DirectoryError.noAccess)
        }
        func bail(_ error: DirectoryError) -> Result<Void, Error> {
            if !alreadyOpen { url.stopAccessingSecurityScopedResource() }
            return .failure(error)
        }

        let writable = FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false))
        KazumiLogBuffer.storage("下载目录：可写=\(writable ? "是" : "否")")
        guard writable else {
            return bail(.notWritable)
        }

        let bookmarked = persistBookmark(for: url)
        KazumiLogBuffer.storage("下载目录：书签=\(bookmarked ? "成" : "败")")
        guard bookmarked else {
            return bail(.bookmarkFailed)
        }

        // 访问权直接接管成常驻，不再「先放掉、再靠书签重开」：
        // 刚 stopAccessing 立刻 startAccessing 有拿不回来的情况，
        // 那时表现就是选了文件夹点打开、位置还停在应用内（LP 5218）。
        if !alreadyOpen {
            stopAccessing()
        }
        scopedURL = url
        isAccessing = true
        hasAccess = true
        savedPath = url.path(percentEncoded: false)
        defaults.set(savedPath, forKey: Self.pathKey)
        // 书签刚由选择器给的新地址生成，趁现在有访问权重做一份，下次冷启动能直接接上。
        persistBookmark(for: url)
        KazumiLogBuffer.storage("下载目录：已接管访问权 \(savedPath)")
        return .success(())
    }

    @discardableResult
    private func persistBookmark(for url: URL) -> Bool {
        // iOS 上从安全域 URL 生成的书签自带安全域，不用（也不能）加 .withSecurityScope。
        guard let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        defaults.set(data.base64EncodedString(), forKey: Self.bookmarkKey)
        return true
    }

    /// 写进「运行日志 → 存储」一栏：这条路径失败时 os.Logger 是看不见的，
    /// 而这正是用户能自己翻出来看的地方。
    private func log(_ message: String) {
        KazumiLog.storage.warning("\(message, privacy: .public)")
        KazumiLogBuffer.storage(message)
    }

    private func stopAccessing() {
        guard isAccessing, let scopedURL else { return }
        scopedURL.stopAccessingSecurityScopedResource()
        isAccessing = false
        self.scopedURL = nil
    }

    enum DirectoryError: LocalizedError {
        case noAccess
        case bookmarkFailed
        case notWritable

        var errorDescription: String? {
            switch self {
            case .noAccess: return "打不开这个文件夹"
            case .bookmarkFailed: return "记不住这个文件夹，换一个试试"
            case .notWritable: return "这个文件夹不能写，换一个试试"
            }
        }
    }
}
