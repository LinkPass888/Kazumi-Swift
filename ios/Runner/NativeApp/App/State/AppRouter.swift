//
//  AppRouter.swift
//  Kazumi
//
//  与 lib/pages/router.dart + lib/pages/menu/menu.dart 对应的导航状态。
//  一级目的地与 App 底部标签栏一一对应：推荐 / 时间表 / 追番 / 我的。
//  （原版底部只有这四个入口；搜索是顶栏按钮推入的二级页面，不是标签页，
//   以图搜番则是搜索页顶栏里的按钮，同样不是独立入口。）
//

import Foundation
import Observation

/// Pure URL parsing; receiving an invalid URL must not change navigation state.
enum KazumiLink: Equatable, Sendable {
    case bangumi(Int)
    case search(String)
    case library
    case history
    case downloads
    /// A local shortcut to details; source selection remains an explicit user action.
    case watch(Int)

    static func parse(_ url: URL) -> KazumiLink? {
        guard url.scheme?.lowercased() == "kazumi",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host else { return nil }
        // Validate UTF-8/percent decoding before Foundation's queryItems convenience API.
        guard components.percentEncodedPath.removingPercentEncoding != nil,
              components.percentEncodedQuery?.removingPercentEncoding != nil
                || components.percentEncodedQuery == nil else { return nil }
        switch host.lowercased() {
        case "bangumi", "watch":
            let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 2, segments[0].isEmpty,
                  let raw = String(segments[1]).removingPercentEncoding,
                  !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let id = Int(raw), id > 0, String(id) == raw else { return nil }
            return host.lowercased() == "watch" ? .watch(id) : .bangumi(id)
        case "search":
            // Match URI query semantics: '+' means space; encoded %2B remains a plus.
            let pairs = (components.percentEncodedQuery ?? "").split(separator: "&")
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                guard name == "query" else { continue }
                let value = parts.count == 2 ? String(parts[1]) : ""
                guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
                let query = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                return query.isEmpty ? nil : .search(query)
            }
            return nil
        case "library", "history", "downloads":
            guard components.path.isEmpty || components.path == "/",
                  components.query == nil, components.fragment == nil else { return nil }
            switch host.lowercased() {
            case "library": return .library
            case "history": return .history
            default: return .downloads
            }
        default:
            return nil
        }
    }
}

/// 一级目的地。
enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case popular
    case timeline
    case collect
    case my

    var id: String { rawValue }

    /// 与 menu.dart 的 LiquidGlassBarItem label 一致。
    ///
    /// 包一层 `String(localized:)`：这是 String 上下文，`Tab(...)` 拿到的是
    /// String 不会查目录，只能在这里自己查（Ato 6442 第一步）。
    var title: String {
        switch self {
        case .popular: String(localized: "推荐")
        case .timeline: String(localized: "时间表")
        case .collect: String(localized: "追番")
        case .my: String(localized: "我的")
        }
    }

    /// 与 menu.dart 的 sfSymbol 一致。
    ///
    /// 时间表用日历符号：原版在详情页里点亮「在时间表展示」时用的就是
    /// CupertinoIcons.calendar（见 bangumi_info_card.dart），底部入口用同一个符号，
    /// 两处能对上。原版菜单里的 Icons.timeline 在 SF Symbols 里没有对应图形。
    ///
    /// 「我的」用人像（LP 2026-10-25）：底栏原来是齿轮，和「我的」页右上角那颗
    /// 设置按钮撞图形；底栏换人像后齿轮只归右上角，各归各位（Colo 2370）。
    /// 只换符号，填充行为跟原来一样 —— 写描边名，选中态由系统补 .fill。
    var symbolName: String {
        switch self {
        case .popular: "house"
        case .timeline: "calendar"
        case .collect: "heart"
        case .my: "person.crop.circle"
        }
    }

    /// 从原版的启动页路径解析出要打开的标签。
    ///
    /// 原版把启动页存成页面路径（'/tab/popular/'、'/tab/timeline/' 这类，
    /// 见 interface_settings.dart 的 defaultPageMap），这里按最后一段匹配。
    static func from(startupPage: String) -> AppDestination {
        let trimmed = startupPage.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let component = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        switch component.lowercased() {
        case "timeline": return .timeline
        case "collect": return .collect
        case "my": return .my
        default: return .popular
        }
    }
}

/// 二级路由（对应原项目 pushNamed 的页面路径）。
enum AppRoute: Hashable, Sendable {
    /// `zoom: false` 时这一页不做缩放转场、走系统默认的横向翻页（推荐页大封面用）。
    case bangumiInfo(bangumiID: Int, zoom: Bool = true)
    case search(keyword: String)
    /// 推荐页某一行「更多」的落点：看这一组的全部（原来那套网格）。
    case popularList(PopularListSource)
    case webSearchHistory
    /// 以图搜番：从搜索页顶栏进入的二级页面（原版路径 /search/image）。
    /// `onPick` 由 SearchScreen 传入，用于把识别到的番名直接填进搜索框。
    case imageSearch(onPick: @MainActor @Sendable (String) -> Void)
    /// 播放：bangumiID + 集数；由选源面板进入时带上规则名与分集页面地址。
    /// 续播：`resumeFromHistory` 为真表示这是「接着看」（详情页开始观看、推荐页开始观看、
    /// 历史页继续观看），线路和集数都要在范围内才用，否则整条不用、从第一集第一条线路起
    /// （跟 main 的 `_initOnlineMode` 一致）。用户点的某一集不带这个标记，越界按夹取处理。
    case player(
        bangumiID: Int,
        episode: Int,
        source: PlaybackSource?,
        resumeRoad: Int?,
        resumeFromHistory: Bool,
        resumeRule: String?
    )

    /// 兼容原有调用点：只带 bangumiID 与集数时，视为「待选源」。
    static func player(bangumiID: Int, episode: Int) -> AppRoute {
        .player(
            bangumiID: bangumiID,
            episode: episode,
            source: nil,
            resumeRoad: nil,
            resumeFromHistory: false,
            resumeRule: nil
        )
    }

    case pluginEditor(ruleID: String?)
    /// 规则测试：对一条规则跑一次「搜索 → 取第一集的播放线路」（对应原版
    /// /settings/plugin/test）。用已保存的规则为输入，测试结果不影响规则本身。
    case pluginTest(ruleID: String)
    /// 规则管理：已安装规则列表（对应原版 /settings/plugin）。
    case pluginList
    /// 规则仓库：可安装的规则目录（对应原版 /settings/plugin/shop）。
    case pluginShop
    case history
    case download
    case settings
    case about
    case logs
    case danmakuShield
    /// 账号与备份主页：Bangumi 账号、WebDAV 备份与设置备份的入口。
    /// 现在还没有自动同步能力，真正落地后再改回「同步备份」。
    case syncBackup
    /// 存储管理：图片缓存与运行日志（对应原版 /settings/storage）。
    case storage
    /// 通知设置（对应原版 /settings/notification）。
    case notificationSettings
    /// 播放设置（对应原版 /settings/player）。
    case playerSettings
    /// 弹幕设置（对应原版 /settings/danmaku）。
    case danmakuSettings
    /// 外观与界面（LP 2594 合并了原版分开的两页，Camo 2599 定名）。
    case themeSettings
    /// 网络设置（对应原版 /settings/proxy）。
    case networkSettings
    /// 更新设置（对应原版 /settings/update）。
    case updateSettings
    /// 下载设置（对应原版 /settings/download）。
    case downloadSettings
    /// 关于页的更新日志（读仓库 CHANGELOG.md，LP 2541）。
    case changelog
}

extension AppRoute {
    /// 与 Dart 的页面路径语义一致：导航栈只比较「去了哪一页」，不比较闭包这类附属数据。
    /// `.imageSearch` 的回调在页面内部重新绑定，因此这里用分支序号参与哈希与相等比较。
    static func == (lhs: AppRoute, rhs: AppRoute) -> Bool {
        lhs.kind == rhs.kind && lhs.associatedValuesEqual(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hashAssociatedValues(into: &hasher)
    }

    /// 分支序号：声明顺序，新增分支时追加在末尾即可。
    var kind: Int {
        switch self {
        case .bangumiInfo: 0
        case .search: 1
        case .webSearchHistory: 2
        case .imageSearch: 3
        case .player: 4
        case .pluginEditor: 5
        case .pluginList: 15
        case .pluginShop: 6
        case .pluginTest: 20
        case .history: 7
        case .download: 8
        case .settings: 9
        case .about: 10
        case .logs: 11
        case .danmakuShield: 12
        // 21 是追加序号：20 已给 pluginTest，序列不必连号，只要唯一。
        case .syncBackup: 21
        case .storage: 16
        case .notificationSettings: 17
        case .playerSettings: 18
        case .danmakuSettings: 19
        case .themeSettings: 22
        case .networkSettings: 24
        case .updateSettings: 25
        case .downloadSettings: 26
        case .changelog: 27
        // 28 是追加序号：推荐页某一行「更多」的列表页。
        case .popularList: 28
        }
    }

    private func associatedValuesEqual(_ other: AppRoute) -> Bool {
        switch (self, other) {
        case let (.bangumiInfo(lhsID, lhsZoom), .bangumiInfo(rhsID, rhsZoom)):
            lhsID == rhsID && lhsZoom == rhsZoom
        case let (.search(lhs), .search(rhs)):
            lhs == rhs
        case (.webSearchHistory, .webSearchHistory):
            true
        case (.imageSearch, .imageSearch):
            // 回调不参与相等比较，页面自己持有识别状态。
            true
        case let (.player(lhsID, lhsEpisode, lhsSource, lhsRoad, lhsResume, lhsRule),
                  .player(rhsID, rhsEpisode, rhsSource, rhsRoad, rhsResume, rhsRule)):
            lhsID == rhsID && lhsEpisode == rhsEpisode && lhsSource == rhsSource
                && lhsRoad == rhsRoad && lhsResume == rhsResume && lhsRule == rhsRule
        case let (.pluginEditor(lhs), .pluginEditor(rhs)):
            lhs == rhs
        case let (.pluginTest(lhs), .pluginTest(rhs)):
            lhs == rhs
        case let (.popularList(lhs), .popularList(rhs)):
            lhs == rhs
        case (.pluginShop, .pluginShop),
             (.pluginList, .pluginList),
             (.history, .history),
             (.download, .download),
             (.settings, .settings),
             (.about, .about),
             (.logs, .logs),
             (.danmakuShield, .danmakuShield),
             (.syncBackup, .syncBackup),
             (.storage, .storage),
             (.notificationSettings, .notificationSettings),
             (.playerSettings, .playerSettings),
             (.danmakuSettings, .danmakuSettings),
             (.themeSettings, .themeSettings),
             (.networkSettings, .networkSettings),
             (.updateSettings, .updateSettings),
             (.downloadSettings, .downloadSettings),
             (.changelog, .changelog):
            true
        default:
            false
        }
    }

    private func hashAssociatedValues(into hasher: inout Hasher) {
        switch self {
        case .bangumiInfo(let bangumiID, let zoom):
            hasher.combine(bangumiID)
            hasher.combine(zoom)
        case .search(let keyword):
            hasher.combine(keyword)
        case .player(
            let bangumiID,
            let episode,
            let source,
            let resumeRoad,
            let resumeFromHistory,
            let resumeRule
        ):
            hasher.combine(bangumiID)
            hasher.combine(episode)
            hasher.combine(source)
            hasher.combine(resumeRoad)
            hasher.combine(resumeFromHistory)
            hasher.combine(resumeRule)
        case .pluginEditor(let ruleID):
            hasher.combine(ruleID)
        case .pluginTest(let ruleID):
            hasher.combine(ruleID)
        case .popularList(let source):
            hasher.combine(source)
        case .webSearchHistory,
             .imageSearch,
             .pluginShop,
             .pluginList,
             .history,
             .download,
             .settings,
             .about,
             .logs,
             .danmakuShield,
             .syncBackup,
             .storage,
             .notificationSettings,
             .playerSettings,
             .danmakuSettings,
             .themeSettings,
             .networkSettings,
             .updateSettings,
             .downloadSettings,
             .changelog:
            break
        }
    }
}

/// 选源结果（对应 lib/pages/video/video_playback_args.dart 的核心字段）。
struct PlaybackSource: Hashable, Sendable {
    /// 规则名，用于取出插件的 UA / Referer / 解析器版本。
    var pluginName: String
    /// 搜索结果的条目名。
    var itemName: String
    /// 条目详情页地址（章节抓取的输入）。
    var detailURL: String
    /// 直接可播的媒体地址（旧版解析器已还原出 m3u8/mp4 时）。
    var directMediaURL: String?
}



@MainActor
@Observable
final class AppRouter {
    var selectedDestination: AppDestination = .popular

    /// 强调色面板由外壳（KazumiTabShell）来弹，不在设置页自己弹（Colo 7614）：
    /// 设置页在 `.id(themeRevision)` 那棵子树里，换一次色子树整体换身份，
    /// 从里面弹出的面板会被一起拆掉——表现就是「点一下颜色面板就没了」。
    var isShowingThemeColorSheet = false

    /// 每个目的地独立的导航栈，切换 Tab 时保留各自的页面。
    var popularPath: [AppRoute] = []
    var timelinePath: [AppRoute] = []
    var collectPath: [AppRoute] = []
    var myPath: [AppRoute] = []

    /// Invalidate source-sheet return callbacks before any external path mutation.
    private(set) var externalNavigationRevision: UInt = 0
    private(set) var externalModalDismissalRevision: UInt = 0
    private(set) var pendingExternalLink: KazumiLink?
    private(set) var externalRequestRevision: UInt = 0
    var isRootMounted = false
    /// Screenshot export can defer navigation without stopping or replacing the player.
    var externalNavigationDeferralCount = 0
    @ObservationIgnored var onExternalNavigationRequested: (() -> Void)?

    /// 前台 App Intent 在自己的进程里跑，拿不到 SwiftUI 环境，只能从这里回到同一个 router。
    static weak var activeInstance: AppRouter?
    /// 冷启动时意图可能先于根视图就绪，先存着，等 AppRoot 挂上再发出去。
    static var pendingFromIntent: KazumiLink?

    static func openFromIntent(_ link: KazumiLink) {
        if let active = activeInstance {
            active.open(link)
        } else {
            pendingFromIntent = link
        }
    }

    @discardableResult
    func openURL(_ url: URL) -> Bool {
        guard let link = KazumiLink.parse(url) else { return false }
        open(link)
        return true
    }

    /// Shared ingress for validated foreground App Intent and debug requests.
    func open(_ link: KazumiLink) {
        externalRequestRevision &+= 1
        pendingExternalLink = link
        onExternalNavigationRequested?()
    }

    func beginExternalNavigation() {
        externalNavigationRevision &+= 1
    }

    func externalModalsDidDismiss() {
        externalModalDismissalRevision &+= 1
    }

    /// Preserve unrelated tab stacks, but remove every player and everything above it.
    /// The target stack is cleared separately, then mounted before its new route is pushed.
    func prepareExternalNavigation() -> AppDestination? {
        guard let link = pendingExternalLink else { return nil }
        let target: AppDestination
        switch link {
        case .library: target = .collect
        case .history, .downloads: target = .my
        case .bangumi, .search, .watch: target = selectedDestination
        }
        for destination in AppDestination.allCases {
            let routes = path(for: destination)
            if destination == target {
                setPath([], for: destination)
            } else if let index = routes.firstIndex(where: {
                if case .player = $0 { return true }
                return false
            }) {
                setPath(Array(routes.prefix(index)), for: destination)
            }
        }
        selectedDestination = target
        return target
    }

    func finishExternalNavigation() {
        guard let link = pendingExternalLink else { return }
        pendingExternalLink = nil
        switch link {
        case .bangumi(let id), .watch(let id): push(.bangumiInfo(bangumiID: id, zoom: false))
        case .search(let query): push(.search(keyword: query))
        case .library: break
        case .history: push(.history)
        case .downloads: push(.download)
        }
    }

    /// 启动时打开的标签（对应原版的 defaultStartupPage）。
    init(defaultStartupPage: String = "/tab/popular/") {
        selectedDestination = AppDestination.from(startupPage: defaultStartupPage)
        AppRouter.activeInstance = self
    }

    func path(for destination: AppDestination) -> [AppRoute] {
        switch destination {
        case .popular: popularPath
        case .timeline: timelinePath
        case .collect: collectPath
        case .my: myPath
        }
    }

    func setPath(_ path: [AppRoute], for destination: AppDestination) {
        switch destination {
        case .popular: popularPath = path
        case .timeline: timelinePath = path
        case .collect: collectPath = path
        case .my: myPath = path
        }
    }

    /// 在当前 Tab 内推入页面。
    func push(_ route: AppRoute) {
        setPath(path(for: selectedDestination) + [route], for: selectedDestination)
    }

    /// 从搜索页打开以图搜番（对应原版 context.pushNamed('/search/image')）。
    func pushImageSearch(onPick: @escaping @MainActor @Sendable (String) -> Void) {
        push(.imageSearch(onPick: onPick))
    }

    func popToRoot() {
        setPath([], for: selectedDestination)
    }
}
