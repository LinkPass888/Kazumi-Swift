//
//  SearchScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/search/search_page.dart：
//  * 顶部是大号搜索框（左侧搜索图标，右侧清空与筛选）；
//  * 未搜索时展示「按条件查找」入口（条件串只在内部拼，屏上不出现搜索语法）；
//  * 搜索结果复用推荐页的竖版卡片网格，滚到底自动续页。
//

import SwiftUI

struct SearchScreen: View {
    var initialKeyword: String = ""
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @State private var controller = SearchController()
    @State private var input = ""
    @State private var submittedQuery: String?
    @State private var isShowingFilters = false
    @State private var isShowingImageSearch = false
    /// 两颗「隐藏」开关：不在条件串里，是搜索页自己的设置（与 main 一致），落盘记住。
    @State private var notShowWatched = UserDefaults.standard.bool(forKey: "kazumi.settings.searchNotShowWatched")
    @State private var notShowAbandoned = UserDefaults.standard.bool(forKey: "kazumi.settings.searchNotShowAbandoned")
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    /// 最近搜索每颗胶囊的最小宽度跟着字号长：写死 96 点时最大字号下
    /// 「轻小说改」被挤成一列，只能截成「轻…」（Ato 6571）。
    @ScaledMetric(relativeTo: .footnote) private var recentChipMinWidth: CGFloat = 96

    private var hasSearched: Bool { submittedQuery != nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    searchField
                    // 以图搜番：直径 44、图标 20 半粗、无底，跟返回按钮同一档；
                    // 贴右 16，跟搜索框同一行垂直居中（Colo 3098）。
                    Button {
                        openImageSearch()
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("以图搜番")
                }
                .padding(.top, hasSearched ? 8 : 20)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                if hasSearched {
                    results
                } else {
                    discovery
                }
            }
        }
        // 顶部滚动边缘：渐进模糊（.soft）。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.immediately)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingFilters) {
            SearchFilterSheet(
                initial: SearchParser(input).toFilterState(),
                notShowWatched: notShowWatched,
                notShowAbandoned: notShowAbandoned
            ) { result in
                notShowWatched = result.notShowWatched
                notShowAbandoned = result.notShowAbandoned
                UserDefaults.standard.set(notShowWatched, forKey: "kazumi.settings.searchNotShowWatched")
                UserDefaults.standard.set(notShowAbandoned, forKey: "kazumi.settings.searchNotShowAbandoned")
                // LP 3048：条件按 main 的格式写回搜索框（tag:后宫 score:7..10），
                // 用户改一个字就能接着搜。
                let query = SearchParser.fromFilterState(result.state)
                input = query
                submit(query)
            }
        }
        .navigationDestination(isPresented: $isShowingImageSearch) {
            ImageSearchScreen { keyword in
                // 对应 _imageSearch：拿到番名后直接提交搜索。
                input = keyword
                submit(keyword)
            }
        }
        .task {
            if !initialKeyword.isEmpty, input.isEmpty {
                input = initialKeyword
                submit(initialKeyword)
            }
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("搜索番剧名称", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isInputFocused)
                .onSubmit { submit(input) }

            if !input.isEmpty || hasSearched {
                Button {
                    input = ""
                    submittedQuery = nil
                    controller.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        // 命中区给到 44（Colo 3084）：原来只有图标那么大。
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }

        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme)
        )
    }

    // MARK: - 发现态

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isShowingFilters = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28)
                        // 大字号下标题要满宽，图标会被挤成一条竖缝——钉住不让压缩。
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按条件查找")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("题材、放送时间与评分")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            recentSearches
        }
    }

    /// 最近搜索：与原版一致，最多 10 条，点击即搜。
    @ViewBuilder
    private var recentSearches: some View {
        let recents = SearchHistoryStore.load()
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近搜索")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("查看全部") { router.push(.webSearchHistory) }
                        .font(.caption)
                }
                .padding(.horizontal, 20)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: recentChipMinWidth), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(recents.prefix(8), id: \.self) { keyword in
                        Button {
                            // LP 3072：历史里那条写人话（后宫），点它搜索框里要放查询串
                            // （tag:后宫），按条件查找里那颗标签也就是选中的——都走同一份状态。
                            input = keyword
                            submit(keyword)
                        } label: {
                            Text(readable(keyword))
                                .font(.footnote)
                                // 搜过的词不截：装不下就折行，胶囊自己长高（Ato 6571）。
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.secondary.opacity(0.12))
                                )
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 28)
        }
    }

    // MARK: - 结果

    /// 隐藏看过／抛弃之后剩下的条目（对应 main 的 _resultSlivers 前半段）。
    private var visibleItems: [BangumiItem] {
        guard notShowWatched || notShowAbandoned else { return controller.bangumiList }
        var hidden: Set<Int> = []
        for entry in library.entries {
            let type = CollectType(rawValue: entry.type)
            if notShowWatched, type == .watched { hidden.insert(entry.id) }
            if notShowAbandoned, type == .dropped { hidden.insert(entry.id) }
        }
        guard !hidden.isEmpty else { return controller.bangumiList }
        return controller.bangumiList.filter { !hidden.contains($0.id) }
    }

    /// 结果表头：标题 + 结果数 + 排序 + 筛选入口，一行读完（LP 3068）。
    private var resultsHeader: some View {
        let state = SearchParser(submittedQuery ?? "").toFilterState()
        // LP 3068：「搜索结果」右边只放搜到多少部，条件串本身不在这儿重复一遍
        // （它就在上面搜索框里，能直接改）。
        return VStack(alignment: .leading, spacing: 6) {
            // 辅助功能字号下「搜索结果」加结果数就把一行占满，排序和筛选按钮被挤，
            // 结果数被截成「11…」、排序名竖成一字一行（Ato 6561）。
            // 大字号下拆两行：第一行标题加结果数，第二行排序和筛选。
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 4) {
                    Text("搜索结果")
                        .font(.headline)
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                HStack(spacing: 4) {
                    Spacer(minLength: 8)
                    sortControl(state)
                    filterButton(state)
                }
            } else {
                HStack(spacing: 4) {
                    Text("搜索结果")
                        .font(.headline)
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 4)
                    Spacer(minLength: 8)
                    sortControl(state)
                    filterButton(state)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func sortControl(_ state: SearchFilterState) -> some View {
        if !state.isIdSearch {
            sortMenu(current: state.sort)
                .padding(.trailing, 4)
        }
    }

    private func filterButton(_ state: SearchFilterState) -> some View {
        Button {
            isShowingFilters = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if state.hasAdvancedFilters {
                        Circle()
                            .fill(KazumiPalette.accent(for: colorScheme))
                            .frame(width: 7, height: 7)
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选番剧")
    }

    /// 结果数那行：搜索中 / 共几部 / 被隐藏了几部（与 main 同一句）。
    private var countText: String {
        let all = controller.bangumiList
        if controller.isLoading && all.isEmpty { return String(localized: "正在搜索…") }
        let shown = visibleItems.count
        if shown < all.count {
            return String(localized: "\(String(describing: shown)) 部番剧 · 隐藏 \(String(describing: all.count - shown)) 部")
        }
        return String(localized: "\(String(describing: shown)) 部番剧")
    }

    /// 排序：按热度 / 排名 / 评分 / 匹配（原版是同一颗菜单，改完立刻重搜）。
    private func sortMenu(current: String) -> some View {
        Menu {
            ForEach(["heat", "rank", "score", "match"], id: \.self) { value in
                Button {
                    var state = SearchParser(submittedQuery ?? "").toFilterState()
                    state.sort = value
                    submit(SearchParser.fromFilterState(state))
                } label: {
                    if value == current {
                        Label(String(localized: "按\(String(describing: SearchFilterState.sortLabel(value)))排序"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "按\(String(describing: SearchFilterState.sortLabel(value)))排序"))
                    }
                }
            }
        } label: {
            // LP 3048 / 3072：只写「热度」这类名字，颜色提上来，右边跟一个下箭头——
            // 跟别的菜单长一个样，让人看得出这是能点的。
            HStack(spacing: 4) {
                Text(SearchFilterState.sortLabel(current))
                    .font(.subheadline.weight(.medium))
                // 尖角 17 半粗，跟时间表标题那颗一档（Colo 3085）。
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.primary)
            // 内边距 12 / 14，命中区撑到 44（Colo 3085）。
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    /// 历史串翻成人话：条件串本身不给用户看（LP 3022）。
    private func readable(_ query: String) -> String {
        let text = SearchParser(query).toFilterState().readableQuery
        return text.isEmpty ? query : text
    }

    @ViewBuilder
    private var results: some View {
        resultsHeader

        if controller.isLoading && controller.bangumiList.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if controller.bangumiList.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("没有找到番剧")
                    .font(.headline)
                Button("修改条件") { isShowingFilters = true }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(visibleItems) { item in
                    SearchResultCard(item: item, width: cardWidth, zoomNamespace: zoomNamespace)
                        .task { await loadMoreIfNeeded(current: item) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            Color.clear
                .frame(height: 1)
                .task(id: "\(controller.bangumiList.count)/\(visibleItems.count)") {
                    await loadMoreIfNeeded()
                }
        }
    }

    /// 列数按可用宽算（Colo 3053）：max(2, floor(可用宽 / 180))，402 屏是 2 列。
    /// 列间距 12、行间距 20；卡宽 =(可用宽 −(列数−1)×12)/列数，402 屏是 179。
    /// Ato 6561：辅助功能字号下两列装不下评分和年份（「3.1 202 5」就是这么断的），
    /// 改成一列。
    private var availableWidth: CGFloat {
        let width = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        return width - 32
    }

    private var columnCount: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return max(2, Int(floor(availableWidth / 180)))
    }

    private var cardWidth: CGFloat {
        (availableWidth - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(cardWidth), spacing: 12, alignment: .top),
            count: columnCount
        )
    }

    // MARK: - 行为

    /// 对应 _imageSearch：打开以图搜番。
    private func openImageSearch() {
        isInputFocused = false
        isShowingImageSearch = true
    }

    private func submit(_ value: String) {
        let state = SearchParser(value).toFilterState()
        let query = SearchParser.fromFilterState(state)
        isInputFocused = false
        // 面板点「查看结果」时会把条件串写回输入框（LP 3048，格式同 main），
        // 用户改一个字就能接着搜；打字搜索这条路不动输入框。
        submittedQuery = query
        if !query.isEmpty { SearchHistoryStore.record(query) }
        Task { await controller.searchBangumi(query, type: "init") }
    }

    private func loadMoreIfNeeded(current item: BangumiItem) async {
        guard !controller.isLoading, controller.hasMoreSearchResults else { return }
        let items = visibleItems
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 6,
              let query = submittedQuery else { return }
        await controller.searchBangumi(query)
    }

    private func loadMoreIfNeeded() async {
        guard !controller.isLoading, controller.hasMoreSearchResults,
              let query = submittedQuery else { return }
        await controller.searchBangumi(query)
    }
}

