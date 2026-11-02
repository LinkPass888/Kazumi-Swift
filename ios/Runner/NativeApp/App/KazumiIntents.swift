import AppIntents
import Foundation
import SwiftUI

struct LocalAnimeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "本机番剧"
    static let defaultQuery = LocalAnimeQuery()

    let id: Int
    let name: String
    let originalName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "本机收藏或观看历史 · \(id)")
    }
}

struct LocalAnimeQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [LocalAnimeEntity] {
        let all = LocalIntentData.entities(in: LocalIntentData.library())
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var seen = Set<Int>()
        return identifiers.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
    }

    @MainActor
    func suggestedEntities() async throws -> [LocalAnimeEntity] {
        Array(LocalIntentData.entities(in: LocalIntentData.library()).prefix(12))
    }

    @MainActor
    func entities(matching string: String) async throws -> [LocalAnimeEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = LocalIntentData.entities(in: LocalIntentData.library())
        return Array(all.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || $0.originalName.localizedStandardContains(query) || String($0.id) == query
        }.prefix(12))
    }
}

enum IntentLibraryFilter: String, AppEnum, CaseIterable {
    case all, watching, wish, onHold, watched, dropped
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "收藏状态"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "全部", .watching: "在看", .wish: "想看", .onHold: "搁置", .watched: "看过", .dropped: "抛弃",
    ]
    var collectType: CollectType? {
        switch self {
        case .all: nil
        case .watching: .watching
        case .wish: .wish
        case .onHold: .onHold
        case .watched: .watched
        case .dropped: .dropped
        }
    }
    var title: String { collectType?.title ?? "全部" }
}

enum KazumiIntentError: Error, CustomLocalizedStringResourceConvertible {
    case missingAnime, emptyQuery
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .missingAnime: "本机收藏和观看历史中已找不到这部番剧，请重新选择。"
        case .emptyQuery: "请输入要搜索的番剧名称。"
        }
    }
}

@MainActor
private enum LocalIntentData {
    static func library() -> LibraryStore {
        let store = LibraryStore()
        store.load()
        return store
    }

    static func entities(in store: LibraryStore) -> [LocalAnimeEntity] {
        var byID: [Int: LocalAnimeEntity] = [:]
        var dates: [Int: Date] = [:]
        for entry in store.entries where entry.id > 0 {
            let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            byID[entry.id] = LocalAnimeEntity(id: entry.id, name: name, originalName: entry.name)
            dates[entry.id] = entry.updatedAt
        }
        for record in store.history.sorted(by: { $0.updatedAt > $1.updatedAt }) where record.bangumiID > 0 {
            let name = record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if byID[record.bangumiID] == nil {
                byID[record.bangumiID] = LocalAnimeEntity(id: record.bangumiID, name: name, originalName: name)
            }
            dates[record.bangumiID] = max(dates[record.bangumiID] ?? .distantPast, record.updatedAt)
        }
        return byID.values.sorted {
            let left = dates[$0.id] ?? .distantPast
            let right = dates[$1.id] ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }

    static func validate(_ anime: LocalAnimeEntity) throws {
        guard entities(in: library()).contains(where: { $0.id == anime.id }) else {
            throw KazumiIntentError.missingAnime
        }
    }

    static func dateText(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.dateFormat = "yyyy年M月d日 HH:mm"
        return format.string(from: date)
    }

    static func progress(_ anime: LocalAnimeEntity) -> String {
        guard let record = library().record(for: anime.id) else {
            return String(localized: "本机没有《\(anime.name)》的观看进度；未查询云端。")
        }
        let episode = record.episodeTitle.isEmpty ? String(localized: "第\(record.episodeNumber)集") : record.episodeTitle
        let seconds = record.progressSeconds
        let position = seconds.isFinite && seconds >= 0 && seconds < Double(Int.max)
            ? WatchRecord.clock(seconds) : "未知位置"
        let source = record.sourceRuleName.isEmpty ? String(localized: "未记录来源") : "来源：\(record.sourceRuleName)"
        return String(localized: "《\(anime.name)》最近看到\(episode)，位置 \(position)。\(source)。记录时间：\(dateText(record.updatedAt))。仅本机历史，不合并不同来源的集数，不代表整部看完。")
    }

    static func libraryText(_ filter: IntentLibraryFilter) -> String {
        let entries = library().entries.filter {
            $0.collectType != .none && (filter.collectType == nil || $0.collectType == filter.collectType)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        guard !entries.isEmpty else { return String(localized: "本机没有“\(filter.title)”收藏记录；未查询云端。") }
        let names = entries.prefix(30).map { "《\($0.displayName)》（\($0.collectType.title)）" }.joined(separator: "、")
        let suffix = entries.count > 30 ? String(localized: "，这里只列出最近更新的30部") : ""
        return String(localized: "本机“\(filter.title)”收藏共\(entries.count)部\(suffix)：\(names)。仅本机已保存记录，未查询云端。")
    }

    static func today(now: Date = Date()) -> String {
        guard let snapshot = TimelineCache.shared.localCurrentSnapshot(
            seasonStart: AnimeSeason.seasonRange(for: now).start
        ) else {
            return "本机没有可用的当季时间表缓存，无法判断今天的计划。请先在应用内查看时间表；本次未联网，也不能据此判断今天没有更新。"
        }
        let days: [[BangumiItem]] = snapshot.days.map { day in
            guard case let .array(list) = day else { return [] }
            return list.compactMap { entry in
                guard !entry["subject"].isNull else { return nil }
                return BangumiItem.fromJSON(entry["subject"])
            }
        }
        let weekday = (Calendar.current.component(.weekday, from: now) + 5) % 7 + 1
        let store = library()
        let localEntities = entities(in: store)
        let calendarIDs = Set(days.flatMap { $0.map(\.id) })
        let custom: [String: BangumiTimelineEntry]
        if let data = UserDefaults.standard.data(forKey: "kazumi.settings.bangumiTimelineEntries"),
           let decoded = try? JSONDecoder().decode([String: BangumiTimelineEntry].self, from: data) {
            custom = decoded
        } else {
            custom = [:]
        }
        var titles: [Int: String] = [:]
        for (index, items) in days.enumerated() {
            for item in items where item.id > 0 {
                let setting = custom[String(item.id)]
                let day = setting.flatMap { $0.weekdayCustom ? $0.weekday : nil } ?? index + 1
                if day == weekday { titles[item.id] = item.displayName }
            }
        }
        for entity in localEntities where !calendarIDs.contains(entity.id) {
            guard let setting = custom[String(entity.id)], setting.showInTimeline,
                  setting.weekday == weekday,
                  setting.weekdayCustom || store.entry(for: entity.id)?.collectType == .watching else { continue }
            titles[entity.id] = entity.name
        }
        let ordered = titles.sorted { $0.key < $1.key }
        let text: String
        if ordered.isEmpty {
            text = "缓存中今天没有计划条目。"
        } else {
            let names = ordered.prefix(30).map { "《\($0.value)》" }.joined(separator: "、")
            let more = ordered.count > 30 ? "（仅列出前30部）" : ""
            text = String(localized: "缓存中今天计划\(ordered.count)部\(more)：\(names)。")
        }
        let saved = snapshot.savedAt.map { String(localized: "缓存保存时间：\(dateText($0))。") } ?? "缓存保存时间未知。"
        return String(localized: "\(text)\(saved)按设备当地星期及本机手动星期设置读取；仅当季缓存计划，不使用页面筛选，不校正播出时刻，不代表片源已更新。本次未联网。")
    }
}

struct OpenAnimeIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "打开番剧"
    static let description = IntentDescription("从本机收藏或观看历史选择番剧，打开详情供你选择片源，不自动播放。")
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "番剧") var anime: LocalAnimeEntity
    static var parameterSummary: some ParameterSummary { Summary("打开\(\.$anime)的详情") }
    @MainActor
    func perform() async throws -> some IntentResult {
        try LocalIntentData.validate(anime)
        return .result()
    }
}

struct SearchAnimeIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "搜索番剧"
    static let description = IntentDescription("打开应用内现有搜索。此动作只传递关键词；搜索页面可能按应用设置联网。")
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "关键词") var query: String
    static var parameterSummary: some ParameterSummary { Summary("搜索番剧\(\.$query)") }
    @MainActor
    func perform() async throws -> some IntentResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KazumiIntentError.emptyQuery
        }
        return .result()
    }
}

struct OpenLibraryIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "打开收藏库"
    static let description = IntentDescription("打开应用的收藏库，不修改收藏状态。")
    static let supportedModes: IntentModes = .foreground
    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct OpenHistoryIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "打开观看历史"
    static let description = IntentDescription("打开本机观看历史，由你选择接下来要看的番剧。")
    static let supportedModes: IntentModes = .foreground
    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct OpenDownloadsIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "打开下载"
    static let description = IntentDescription("打开下载页面，不新建下载或自动播放。")
    static let supportedModes: IntentModes = .foreground
    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct ReadTodayScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "查看今日缓存计划"
    static let description = IntentDescription("离线读取当季时间表缓存中的今日计划及保存时间，不查询云端，不保证片源可用。")
    static let supportedModes: IntentModes = .background
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = LocalIntentData.today()
        return .result(value: text, dialog: "\(text)")
    }
}

struct ReadWatchProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "查看观看进度"
    static let description = IntentDescription("读取所选番剧在本机最近一次观看记录，保留来源和记录时间，不查询云端。")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "番剧") var anime: LocalAnimeEntity
    static var parameterSummary: some ParameterSummary { Summary("查看\(\.$anime)的本机观看进度") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = LocalIntentData.progress(anime)
        return .result(value: text, dialog: "\(text)")
    }
}

struct ReadLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "查看本机收藏"
    static let description = IntentDescription("按收藏状态读取本机列表，最多返回最近更新的30部，不同步、不修改收藏。")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "收藏状态", default: .watching) var filter: IntentLibraryFilter
    static var parameterSummary: some ParameterSummary { Summary("查看本机\(\.$filter)收藏") }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = LocalIntentData.libraryText(filter)
        return .result(value: text, dialog: "\(text)")
    }
}

struct KazumiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAnimeIntent(), phrases: ["用\(.applicationName)打开番剧"], shortTitle: "打开番剧", systemImageName: "play.rectangle")
        AppShortcut(intent: SearchAnimeIntent(), phrases: ["用\(.applicationName)搜索番剧"], shortTitle: "搜索番剧", systemImageName: "magnifyingglass")
        AppShortcut(intent: ReadTodayScheduleIntent(), phrases: ["查看\(.applicationName)今日计划", "\(.applicationName)今天更新什么"], shortTitle: "今日缓存计划", systemImageName: "calendar")
        AppShortcut(intent: OpenLibraryIntent(), phrases: ["打开\(.applicationName)收藏库"], shortTitle: "收藏库", systemImageName: "heart")
        AppShortcut(intent: OpenHistoryIntent(), phrases: ["查看\(.applicationName)观看历史"], shortTitle: "观看历史", systemImageName: "clock")
    }
    static let shortcutTileColor: ShortcutTileColor = .blue
}

#if DEBUG
struct KazumiIntentDebugView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var anime: [LocalAnimeEntity] = []
    @State private var selectedID: Int?
    @State private var filter: IntentLibraryFilter = .watching
    @State private var output = "尚未运行"

    private var selected: LocalAnimeEntity? { anime.first { $0.id == selectedID } }

    var body: some View {
        Form {
            Section("验证范围") {
                Text("读取按钮执行真实的指令方法。导航按钮执行方法后打开同一类型路由；这里没有系统快捷指令运行环境，不能证明 Siri、参数询问或系统跳转已通过。")
                    .font(.footnote)
                Button("刷新本机候选") { Task { await refresh() } }
                    .accessibilityIdentifier("debug-intents-refresh")
                Picker("番剧", selection: $selectedID) {
                    Text("请选择").tag(Optional<Int>.none)
                    ForEach(anime) { item in Text(item.name).tag(Optional(item.id)) }
                }
            }
            Section("本机只读结果") {
                Button("运行：今日缓存计划") {
                    run { (try await ReadTodayScheduleIntent().perform()).value ?? "没有返回内容" }
                }.accessibilityIdentifier("debug-intents-today")
                Picker("收藏状态", selection: $filter) {
                    ForEach(IntentLibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("运行：本机收藏") {
                    run {
                        let intent = ReadLibraryIntent()
                        intent.filter = filter
                        return (try await intent.perform()).value ?? "没有返回内容"
                    }
                }.accessibilityIdentifier("debug-intents-library-read")
                Button("运行：观看进度") {
                    guard let selected else { return }
                    run {
                        let intent = ReadWatchProgressIntent()
                        intent.anime = selected
                        return (try await intent.perform()).value ?? "没有返回内容"
                    }
                }.disabled(selected == nil)
                    .accessibilityIdentifier("debug-intents-progress")
            }
            Section("前台导航（不自动播放）") {
                TextField("搜索关键词", text: $query)
                    .accessibilityIdentifier("debug-intents-query")
                Button("运行并打开：搜索番剧") {
                    run {
                        let intent = SearchAnimeIntent()
                        intent.query = query
                        _ = try await intent.perform()
                        environment.router.open(.search(query.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return "已请求打开现有搜索页面；页面可能联网。"
                    }
                }.accessibilityIdentifier("debug-intents-search")
                Button("运行并打开：番剧详情") {
                    guard let selected else { return }
                    run {
                        let intent = OpenAnimeIntent()
                        intent.anime = selected
                        _ = try await intent.perform()
                        environment.router.open(.bangumi(selected.id))
                        return "已请求打开番剧详情，不自动播放。"
                    }
                }.disabled(selected == nil)
                    .accessibilityIdentifier("debug-intents-open-anime")
                Button("运行并打开：收藏库") {
                    run {
                        _ = try await OpenLibraryIntent().perform()
                        environment.router.open(.library)
                        return "已请求打开收藏库。"
                    }
                }.accessibilityIdentifier("debug-intents-open-library")
                Button("运行并打开：观看历史") {
                    run {
                        _ = try await OpenHistoryIntent().perform()
                        environment.router.open(.history)
                        return "已请求打开观看历史。"
                    }
                }.accessibilityIdentifier("debug-intents-open-history")
                Button("运行并打开：下载") {
                    run {
                        _ = try await OpenDownloadsIntent().perform()
                        environment.router.open(.downloads)
                        return "已请求打开下载页面。"
                    }
                }.accessibilityIdentifier("debug-intents-open-downloads")
            }
            Section("最近结果") {
                Text(output).textSelection(.enabled)
                    .accessibilityIdentifier("debug-intents-result")
            }
        }
        .navigationTitle("快捷指令验证")
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        do {
            anime = try await LocalAnimeQuery().suggestedEntities()
            if selectedID == nil || !anime.contains(where: { $0.id == selectedID }) { selectedID = anime.first?.id }
            output = String(localized: "已读取\(anime.count)个本机候选（最多12个），未联网。")
        } catch { output = error.localizedDescription }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> String) {
        Task { @MainActor in
            do { output = try await operation() }
            catch {
                output = (error as? any CustomLocalizedStringResourceConvertible)
                    .map { String(localized: $0.localizedStringResource) } ?? error.localizedDescription
            }
        }
    }
}
#endif
