//
//  InfoController.swift
//  Kazumi
//
//  对应 lib/pages/info/info_controller.dart 的原生子集：
//  * 详情懒刷新：summary 为空或缺票数分布时重新拉一次 next 域详情；
//  * 剧集列表走 /v0/episodes；
//  * 选源复用 PluginSearchService，对全部已装规则并发检索。
//

import Observation

@MainActor
@Observable
final class InfoController {
    private(set) var item: BangumiItem
    private(set) var episodes: [BangumiEpisode] = []
    private(set) var isLoadingDetail = false
    private(set) var isLoadingEpisodes = false

    /// 选源面板的聚合结果，按规则名索引。
    ///
    /// 是算出来的、不是快照：每条来源的状态会一个个变（检索中 → 结果 / 失败 /
    /// 超时），存一份快照就只有整轮跑完才刷新，单条超时或被看门狗判失败时
    /// 界面不会动。读的是 `searchService` 上的可观察状态，变了就重画。
    var sourceGroups: [SourceGroup] {
        let fallback = defaultKeyword
        return plugins.pluginList.map { plugin in
            SourceGroup(
                name: plugin.name,
                status: searchService.status(for: plugin.name) ?? .pending,
                results: searchService.responses(for: plugin.name),
                keyword: sourceKeywords[plugin.name] ?? fallback
            )
        }
    }
    private(set) var isSearchingSources = false

    /// 单条来源的那份数据。面板逐行用它：规则几百条，整表一次 map 出来
    /// 每帧都要建几百个对象，面板第一次弹出来就卡在那儿（LP 2026-10-28
    ///「加载个规则列表为什么白屏等待」）。逐行算，只算看得见的那几行。
    func sourceGroup(named name: String) -> SourceGroup {
        SourceGroup(
            name: name,
            status: searchService.status(for: name) ?? .pending,
            results: searchService.responses(for: name),
            keyword: sourceKeywords[name] ?? defaultKeyword
        )
    }

    /// 面板里哪些来源是展开着的。放在控制器上，是为了返回播放页再弹回面板时还在。
    var sourceExpanded: Set<String> = []

    /// 这一部番已经检索过一轮没有。没检索过才查，重检会把已有结果冲掉。
    private var hasSearchedSources = false

    /// 按名字取规则，供「在浏览器中打开」拼网址用。
    func plugin(named name: String) -> Plugin? {
        plugins.plugin(named: name)
    }

    let searchService: PluginSearchService
    private let plugins: PluginsController

    /// 已安装的规则，按安装顺序。面板逐行渲染用它（不整表 map，见 sourceGroup）。
    var installedRules: [Plugin] { plugins.pluginList }
    /// 每个来源各自的检索词。对应原版 _SourceSearchGroup.keyword：
    /// 默认是番剧名，改过检索词或用别名检索后，这个来源就用自己的词。
    private var sourceKeywords: [String: String] = [:]

    /// 默认检索词：中文名优先，缺失时用原名（与原版一致）。
    private var defaultKeyword: String { item.nameCn.isEmpty ? item.name : item.nameCn }
    struct SourceGroup: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var status: PluginSearchStatus
        var results: [SearchItem]
        var keyword: String

        var statusLabel: String {
            switch status {
            case .pending: String(localized: "检索中…")
            case .success: results.isEmpty ? String(localized: "无结果") : String(localized: "\(String(describing: results.count)) 个结果")
            case .noResult: "无结果"
            case .error: String(localized: "检索失败")
            case .captcha: String(localized: "需要验证")
            }
        }

        var hasResults: Bool { status == .success && !results.isEmpty }
    }

    init(item: BangumiItem, plugins: PluginsController) {
        self.item = item
        self.plugins = plugins
        self.searchService = PluginSearchService(plugins: plugins)
    }

    /// 与原版一致：标题/简介缺失或票数分布不全时刷新详情。
    /// 本地缓存过期了也算需要刷新（缓存只用来先画页面，不代替刷新）。
    var needsDetailRefresh: Bool {
        item.summary.isEmpty
            || item.votes <= 0
            || item.votesCount.count < 10
            || BangumiSubjectCache.shared.needsInfoRefresh(item.id)
    }

    /// 用缓存先把剧集列表铺上，进页面时不再等网络。
    func applyCachedEpisodes() {
        guard episodes.isEmpty,
              let cached = BangumiSubjectCache.shared.episodes(for: item.id)
        else { return }
        episodes = cached
    }

    /// 内存里已有剧集时直接铺上（不读盘）。
    func replaceEpisodes(_ newEpisodes: [BangumiEpisode]) {
        episodes = newEpisodes
    }

    /// 磁盘里的那份条目：面板已经画出来之后再补，不压在点按那一下。
    /// 手上这份是列表里带来的（没简介），换成有简介的那份。
    func applyCachedItemIfNeeded() {
        guard item.summary.isEmpty,
              let cached = BangumiSubjectCache.shared.item(for: item.id)
        else { return }
        item = cached
    }

    func loadDetailIfNeeded() async {
        guard needsDetailRefresh, !isLoadingDetail else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        if let refreshed = await BangumiAPI.info(id: item.id) {
            item = refreshed
        }
    }

    func loadEpisodes() async {
        // 缓存里的剧集先铺上，后台再决定要不要刷新。
        applyCachedEpisodes()
        guard !isLoadingEpisodes else { return }
        // 缓存还新鲜就不用再拉；过期了也照拉，拉回来替换，期间页面上的旧列表不动。
        if !episodes.isEmpty, !BangumiSubjectCache.shared.needsEpisodesRefresh(item.id) { return }
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        let loaded = await BangumiAPI.episodes(subjectID: item.id)
        if !loaded.isEmpty || episodes.isEmpty {
            episodes = loaded
        }
    }

    // MARK: - 详情页分标签

    private(set) var comments: [BangumiCommentItem] = []
    private(set) var commentsTotal = 0
    private(set) var isLoadingComments = false

    private(set) var characters: [BangumiCharacterItem] = []
    private(set) var isLoadingCharacters = false

    private(set) var staff: [BangumiStaffItem] = []
    private(set) var isLoadingStaff = false

    private(set) var relations: [BangumiRelationItem] = []
    private(set) var isLoadingRelations = false

    /// 与原版一致：标签点开时才去拉数据，拉过一次就不再重复请求。
    func loadComments() async {
        guard !isLoadingComments, comments.isEmpty else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }
        let page = await BangumiAPI.comments(subjectID: item.id)
        comments = page.items
        commentsTotal = page.total
    }

    func loadCharacters() async {
        guard !isLoadingCharacters, characters.isEmpty else { return }
        isLoadingCharacters = true
        defer { isLoadingCharacters = false }
        characters = await BangumiAPI.characters(subjectID: item.id)
    }

    func loadStaff() async {
        guard !isLoadingStaff, staff.isEmpty else { return }
        isLoadingStaff = true
        defer { isLoadingStaff = false }
        staff = await BangumiAPI.staff(subjectID: item.id)
    }

    func loadRelations() async {
        guard !isLoadingRelations, relations.isEmpty else { return }
        isLoadingRelations = true
        defer { isLoadingRelations = false }
        // 与原版 resolveRelatedAnimeChain 一致：只保留动画，并把「前传 / 续集」
        // 整条主线串起来后按方向重新命名。
        relations = await RelatedAnimeChain.resolve(currentSubjectID: item.id) { @Sendable subjectID in
            await BangumiAPI.relations(subjectID: subjectID)
        }
    }

    // MARK: - 放送时刻

    /// 播出时刻（本地 "HH:mm"）。原版从 bangumi-mal 的季度表推导，取不到就 nil。
    var airTime: String? {
        BangumiAirTimeService.shared.airTime(for: item.id)
    }

    func loadAirTime() async {
        await BangumiAirTimeService.shared.ensureLoaded(
            subjectID: item.id,
            airDate: item.airDate
        )
    }

    // MARK: - 吐槽

    private(set) var isPostingComment = false

    /// 发表一条吐槽。Bangumi 的「吐槽」就是收藏评价，所以要把当前追番状态一起写，
    /// 否则接口会因为缺少 type 直接 400。
    func postComment(_ text: String, type: CollectType) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPostingComment else { return false }
        isPostingComment = true
        defer { isPostingComment = false }
        let ok = await BangumiAPI.updateCollection(
            subjectID: item.id,
            type: type,
            comment: trimmed
        )
        guard ok else { return false }
        // 发表成功后重新拉一遍，列表里就有自己的这条了。
        comments = []
        commentsTotal = 0
        await loadComments()
        return true
    }

    // MARK: - 选源

    /// 对应 SourceSheet 的 init：用中文名优先作为检索词。
    ///
    /// 返回播放页再弹回面板时不能重检：那批结果和展开状态都还在，重检会把它们冲掉。
    func searchAllSources() async {
        guard !plugins.pluginList.isEmpty else { return }
        guard !hasSearchedSources else { return }
        hasSearchedSources = true
        sourceKeywords = [:]
        isSearchingSources = true
        await searchService.queryAllSource(defaultKeyword)
        isSearchingSources = false
    }

    /// 手动关掉面板：下次再点「开始观看」要重新检索一遍。
    func closeSourceSearch() {
        searchService.cancel()
        isSearchingSources = false
        hasSearchedSources = false
        sourceExpanded = []
    }

    /// 对应原版 source_sheet.dart 的 _querySource：只检索指定来源。
    func retrySource(_ name: String, keyword: String? = nil) async {
        let resolved = (keyword ?? sourceKeywords[name] ?? defaultKeyword)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return }
        sourceKeywords[name] = resolved
        await searchService.querySource(resolved, pluginName: name)
    }

    /// 对应原版 _showAliasPicker → _querySource(alias, pluginName)：
    /// 用一个别名去检索指定来源，别名就是那次的检索词。
    func searchSourceWithAlias(_ alias: String, pluginName: String) async {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await retrySource(pluginName, keyword: trimmed)
    }

    /// 当前条目的别名（来自 infobox 的「别名」），对应原版 bangumiItem.alias。
    var aliases: [String] { item.alias }
}

/// 剧集条目（对应 getBangumiEpisodesByID 返回的 EpisodeInfo 子集）。
struct BangumiEpisode: Identifiable, Hashable, Sendable {
    var id: Int
    var sort: Double
    /// 当季话数（Bangumi 的 `ep`）。
    ///
    /// 第二季之后的 `sort` 会接着上一季往下数（第三季第 1 集 sort = 49），
    /// 而播放器里的集号是「这一季的第几集」。所以认集必须先用 `ep`，
    /// 拿不到再用绝对话数 —— 原版 `bangumi_episode_matcher.dart` 就是这条规矩。
    var ep: Double
    /// 单集类型：0 = 本篇，1 = 特别篇，2 = OP，3 = ED 等。
    var type: Int
    var name: String
    var nameCn: String
    var airdate: String

    /// 与 Dart 版 EpisodeItem.displayName 一致：中文名优先。
    var displayName: String {
        let translated = nameCn.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty { return translated }
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return original.isEmpty ? String(localized: "第 \(String(describing: Int(sort))) 集") : original
    }

    static func fromJSON(_ json: JSONValue) -> BangumiEpisode {
        BangumiEpisode(
            id: json["id"].intValue ?? 0,
            sort: json["sort"].doubleValue ?? 0,
            ep: json["ep"].doubleValue ?? 0,
            type: json["type"].intValue ?? 0,
            name: json["name"].stringValue ?? "",
            nameCn: json["name_cn"].stringValue ?? "",
            airdate: json["airdate"].stringValue ?? ""
        )
    }
}
