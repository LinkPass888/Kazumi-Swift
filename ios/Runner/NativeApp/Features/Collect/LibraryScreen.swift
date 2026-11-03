//
//  LibraryScreen.swift
//  Kazumi
//
//  对应 lib/pages/collect/collect_page.dart + collect_library_view.dart：
//  * 顶栏是「追番」+ 右侧「同步」按钮；
//  * 控制条：分类菜单（全部 / 在看 / 想看 / 看过 / 搁置 / 抛弃，默认「在看」）
//    ＋ 排序菜单 ＋ 当前部数，右侧常驻搜索条；
//  * 主体是收藏卡片列表，点开进详情，右侧菜单可改收藏状态；
//  * 没有收藏时给出引导，而不是空白页。
//

import SwiftUI

struct LibraryScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @Environment(AppEnvironment.self) private var environment
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// nil 表示「全部」。
    private static let categories: [CollectType?] = [
        nil, .watching, .wish, .watched, .onHold, .dropped,
    ]

    @State private var selectedType: CollectType? = .watching
    /// 「在看」里记住的排序，存进 `SettingsStore.librarySort`。
    @State private var sort: CollectSort = .updateTime
    /// 其它分类里选的排序（只在本页会话里记），默认「最近变更」。
    @State private var otherSort: CollectSort = .recentlyChanged
    @State private var query = ""
    @State private var isSearching = false
    @State private var pendingID: Int?
    /// 同步失败这类一句提示。样式与详情页那颗一致。
    @State private var toastMessage: String?

    /// 「更新时间」排序用的时刻表：进页先算好，比较器只查表。
    @State private var updateTimes: [Int: Date] = [:]
    /// 季度时刻表是否已经跑完一轮。没跑完之前先按「最近变更」排，不转圈。
    @State private var updateTimesLoaded = false
    /// 网格封面按左到右、上到下完成一次回源后递增，让对应卡片重新查缓存。
    @State private var coverLoadRevision = 0

    @FocusState private var searchFocused: Bool

    /// 网格列数。改列数只改这一处，排版不重写（规格 §四）。
    /// 字号越大列越少：一份海报卡在最大字号下仍然要读得下标题，
    /// 三列会把字挤成两三个字一行（Colo 2026-10-24 定的三档）。
    private var columnCount: Int {
        if dynamicTypeSize >= .accessibility4 { return 1 }
        if dynamicTypeSize >= .accessibility1 { return 2 }
        // 按容器宽算列数（§6.2）：max(3, floor((容器宽 − 32 + 10) / 160))。
        return max(3, Int(floor((libraryContainerSize.width - 32 + 10) / 160)))
    }
    /// 网格列间距。
    private static let columnSpacing: CGFloat = 10

    /// 量到的页面尺寸（§6.0：列数与限宽都按容器算，不按整屏）。
    @State private var libraryContainerSize: CGSize = .zero

    /// B 档：宽且不矮。
    private var isWideTier: Bool {
        libraryContainerSize.width >= 700 && libraryContainerSize.height >= 600
    }

    /// C 档：宽但矮（§六之二）。
    private var isShortTier: Bool {
        libraryContainerSize.width >= 700 && libraryContainerSize.height < 600
    }

    /// 内容区宽度（左右各 16 之后）。
    private var libraryContentWidth: CGFloat {
        max(0, libraryContainerSize.width - 32)
    }

    /// 按视口宽和当前列数算出定宽列。
    private func gridColumns(width: CGFloat) -> [GridItem] {
        let count = columnCount
        guard width > 0 else {
            return Array(repeating: GridItem(.flexible(), spacing: Self.columnSpacing), count: count)
        }
        // 不取整：402 屏上每列 116.7，三列加两道间距正好铺满，右边不留缝。
        let total = width - Self.columnSpacing * CGFloat(count - 1)
        let each = max(1, total / CGFloat(count))
        // 宽档列宽封顶 200（§6.2）：辅助功能字号单列 / 两列时封面不再跟着整屏长。
        let columnWidth = libraryContainerSize.width >= 700 ? min(each, 200) : each
        return Array(repeating: GridItem(.fixed(columnWidth), spacing: Self.columnSpacing), count: count)
    }

    // MARK: - 数据

    /// 去掉首尾空白后的搜索词；判空和过滤都用它。
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前分类名，菜单按钮与无障碍文案共用。
    private var categoryTitle: String {
        selectedType?.title ?? "全部"
    }

    /// 实际生效的排序。
    ///
    /// 其它分类默认按 `updatedAt` 降序（也可以改成另外四档）；「在看」里如果
    /// 时刻表还没到，也先用最近变更把列表正常排出来，数据到了再切回用户选的排序。
    private var effectiveSort: CollectSort {
        guard selectedType == .watching else { return otherSort }
        if sort == .updateTime, !updateTimesLoaded { return .recentlyChanged }
        return sort
    }

    private var filteredEntries: [LibraryEntry] {
        let filtered = CollectLibraryQuery.filter(library.entries, type: selectedType, query: query)
        return CollectLibraryQuery.sort(filtered, by: effectiveSort, updateTimes: updateTimes)
    }

    var body: some View {
        content
            // 只量视口尺寸（宽档分档要用高度）：网格的左右内边距各 16，减掉就是可用内容宽。
            // 这颗探针必须在 ScrollView 外面，理由见 content 里那段注释。
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LibraryContentWidthKey.self,
                        value: proxy.size
                    )
                }
            }
            .onPreferenceChange(LibraryContentWidthKey.self) { size in
                guard size.width > 0 else { return }
                libraryContainerSize = size
            }
            // LP 2026-10-24（后一条）：追番页整体上移到原来的高度——不用系统大标题了，
            // 导航栏收起，标题照旧写在内容里，顶栏只剩控制条；「同步」仍留在控制条里。
            // 顶栏改纯色底（同一条）：标题＋控制条铺页面底色并铺进状态栏，上滑不透内容。
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    controlBar
                }
                .background(
                    KazumiPalette.background(for: colorScheme),
                    ignoresSafeAreaEdges: .top
                )
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            // 「同步」不在工具栏：LP 2026-10-24 要它回到搜索按钮右边、两颗一起靠右。
            .task {
                sort = CollectSort(rawValue: settings.librarySort) ?? .updateTime
            }
            .task(id: coverLoadKey) {
                await loadLibraryCovers()
            }
            // 追番条目变化时补齐时刻表：新加入「在看」的番也要拿到时刻。
            .task(id: library.watchingEntries.map(\.id)) {
                await loadUpdateTimes()
            }
            // 详情页改了放送星期 / 时间表加载完成后，按新的星期重排一次。
            .onChange(of: BangumiTimelineStore.shared.revision) { _, _ in
                guard updateTimesLoaded else { return }
                updateTimes = makeUpdateTimes(for: library.watchingEntries)
            }
            // 搜索栏是在 `if isSearching` 里才出现的，等它进布局再拿焦点。
            .onChange(of: isSearching) { _, value in
                searchFocused = value
            }
            .overlay(alignment: .bottom) { toastView }
    }

    // MARK: - 头部

    /// 「同步」不在这里：LP 2026-10-24 要它贴在控制条搜索按钮右边。
    private var header: some View {
        HStack(alignment: .center) {
            Text("追番")
                // C 档大标题改 inline（§六之二）：34 半粗 → 20 半粗。
                .font(isShortTier ? Font.title3.weight(.semibold) : Font.largeTitle.weight(.semibold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // Colo 3461：搜索状态下，搜索框以上这一整块是取消的**主要落点**——
        // 面积固定、永远在、不随结果多少变。列表那边不再挂手势。
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSearching else { return }
            cancelSearch()
        }
    }

    // MARK: - 控制条

    /// 一行控制条：分类菜单 ＋ 排序菜单 ＋ 部数，右侧搜索。
    /// 搜索展开时两个菜单和部数从布局里移除（不是盖住），整行高度不变。
    private var controlBar: some View {
        Group {
            if isSearching {
                searchRow
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                defaultRow
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        // LP 2026-10-23：切换原来是一帧跳过去，「太快太突兀」。
        .animation(.smooth(duration: 0.32), value: isSearching)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        // LP 2535 / Colo 2537：顶栏底色下沿贴着控制条下沿；原来那 12 点搬到网格顶上。
        // Colo 2550 提过底边留 −4 收回多出的那点，LP 2556 看了说不好看，回退成 0。
    }

    private var defaultRow: some View {
        // 一行放得下就一行；放不下（最大字号下这四样加起来 504，比 370 宽）
        // 就折成两行：筛选＋排序一行，部数＋搜索一行。
        // 顶栏不能靠缩网格救——网格缩到一列，这一行照样出界（Colo 2026-10-24 实测）。
        //
        // 宽度很卡平（LP 3425）：402 屏、正文宽 370，四个胶囊实测 70.3 / 100 / 44 / 79，
        // 间距 8 + Spacer 最少 8 时，「0 部」刚好 366 放得下，「27 部」多一位数就 371，
        // 当场折成两行——看着像 27.1 的毛病，其实是余量正好为零。
        // 间距改 6、Spacer 不留最小值，两位数的部数还有 16 点余量。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                categoryMenu
                sortMenu
                categoryCount

                Spacer(minLength: 0)

                // LP 2026-10-23：默认就只是一颗放大镜按钮，点了才长成搜索条。
                searchIconButton
                // LP 2026-10-24：同步在搜索右边，两颗一起靠右。
                syncButton
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    categoryMenu
                    sortMenu
                }
                HStack(spacing: 8) {
                    categoryCount
                    Spacer(minLength: 0)
                    searchIconButton
                    syncButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("分类", selection: categoryBinding) {
                ForEach(Array(Self.categories.enumerated()), id: \.offset) { index, type in
                    Text(type?.title ?? "全部").tag(index)
                }
            }
        } label: {
            menuCapsule(title: categoryTitle)
        }
        .accessibilityLabel(Text(String(localized: "筛选，\(String(describing: categoryTitle))")))
        .accessibilityHint(Text("选择追番状态"))
    }

    /// 「更新时间」只对「在看」有意义：其它分类里菜单照常可点，只有这一项
    /// 灰掉；用户改选的另外四档都照常生效。灰掉的那一项用禁用的菜单项
    /// 单独排在最前，其余四项仍交给 Picker 打勾（不自己画对勾）。
    private var sortMenu: some View {
        Menu {
            if selectedType != .watching {
                Button {} label: {
                    Text(CollectSort.updateTime.label)
                }
                .disabled(true)
                .accessibilityHint(Text("只有「在看」里能按放送时间排"))
            }

            Picker("排序", selection: sortBinding) {
                ForEach(availableSorts) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            menuCapsule(title: effectiveSort.label)
        }
        .accessibilityLabel(Text(String(localized: "排序，\(String(describing: effectiveSort.label))")))
        .accessibilityHint(Text("选择排序方式"))
    }

    /// 「在看」里五档全给；其它分类只给可选的四档（更新时间单独灰在最前）。
    private var availableSorts: [CollectSort] {
        selectedType == .watching
            ? CollectSort.allCases
            : CollectSort.allCases.filter { $0 != .updateTime }
    }

    /// 玻璃菜单底：视觉高度 36、命中区 44（外面撑出来，不加高亮）。
    /// LP 2026-10-23：原来写死 70/100 宽，「在看」两个字被挤成三个点；
    /// 现在按字撑开，多出来的宽度让给部数。
    ///
    /// 颜色用 `Color.primary` / `Color.secondary`，**不能用层级写法 `.primary`**：
    /// 菜单和按钮的标签会按 App 的全局 tint（KazumiApp 的 `.tint(accent)`）上色，
    /// 层级写法跟着 tint 走，字就变成主题色。LP 2026-10-24 报的就是这个。
    private func menuCapsule(title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        // 12 → 10（Colo 3429 的省宽顺序第一条）：两颗胶囊各省 4 点。
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .kazumiGlassCapsule(interactive: true)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 当前筛选结果的部数；搜索时跟着筛后条数走。
    private var categoryCount: some View {
        let total = filteredEntries.count
        return Text(String(localized: "\(String(describing: total)) 部"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // 1024 部也不许被搜索条挤压。
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(Text(String(localized: "当前分类，\(String(describing: total)) 部")))
    }

    private var categoryBinding: Binding<Int> {
        Binding(
            get: { Self.categories.firstIndex(of: selectedType) ?? 0 },
            set: { index in
                let newType = Self.categories[index]
                // 切到其它分类时，**只有当前排的是「更新时间」才降级**成「最近变更」；
                // 其余四档在任何分类都能用，用户选的那档跟着走，不许切个分类就丢掉。
                // 切回「在看」时 `sort` 原样保留。
                if newType != selectedType, newType != .watching {
                    let current = effectiveSort
                    otherSort = current == .updateTime ? .recentlyChanged : current
                }
                selectedType = newType
            }
        )
    }

    private var sortBinding: Binding<CollectSort> {
        Binding(
            get: { effectiveSort },
            set: { newValue in
                // 「更新时间」只属于「在看」；灰掉的那一项即使被触发也不改状态。
                guard newValue != .updateTime || selectedType == .watching else { return }
                if selectedType == .watching {
                    sort = newValue
                    // 只记「在看」里选的排序；切分类不写这个键。
                    settings.librarySort = newValue.rawValue
                } else {
                    otherSort = newValue
                }
            }
        )
    }

    private var searchHint: String {
        String(localized: "在「\(String(describing: categoryTitle))」里搜索")
    }

    // MARK: - 搜索

    /// 常驻的 36 高搜索条。视觉 36，外面补到 44 的命中区。
    private var searchEntryButton: some View {
        Button {
            isSearching = true
            searchFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.secondary)
                Text("搜索追番")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .frame(maxWidth: .infinity)
            .kazumiGlassCapsule(interactive: true)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("搜索追番"))
        .accessibilityHint(Text(searchHint))
    }

    /// 最大字号装不下整条搜索时的 44 放大镜。
    /// 进「账号与备份」。LP 2026-10-24：放在搜索按钮左边、和搜索一起靠右，
    /// 并且**不要主题色**——所以字和图标都用 `Color.primary`／`.secondary`，
    /// 不用 tint（层级写法会跟着 App 的 tint 上色，那是同一个坑）。
    private var syncButton: some View {
        Button {
            router.push(.syncBackup)
        } label: {
            // 尺寸和搜索那颗同一套（Colo 2026-10-24）：图标 16 regular、和放大镜同号，
            // 字 subheadline semibold，图标与字间距 6，横内边距 12。
            // 颜色：不用主题色，图标和字都是默认标签色——两颗都靠右时靠字区分。
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.primary)
                Text("同步")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .kazumiGlassCapsule(interactive: true)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("同步"))
    }

    private var searchIconButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.32)) { isSearching = true }
            searchFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                // LP 2026-10-24：放大镜跟左右几颗的字同色（默认标签色），不再用次要色。
                // 删掉这行就回到默认，胶囊上的字是 Color.primary，正好一致。
                // LP 2026-10-23：视觉 36，跟左边两个菜单胶囊一样高；命中区仍是 44。
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
                .kazumiGlassCapsule(interactive: true)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("搜索追番"))
        .accessibilityHint(Text(searchHint))
    }

    /// 展开态：搜索条占满整行，整行仍是 44 高。
    /// LP 2026-10-24：右边的「取消」删了，点列表空白处退出搜索（见 content 里的 onTapGesture）。
    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("搜索追番", text: $query)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(Text("搜索追番"))
                    .accessibilityHint(Text(searchHint))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("清空搜索"))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .frame(maxWidth: .infinity)
            .kazumiGlassCapsule()
            .frame(minHeight: 44)
            .contentShape(Rectangle())

            // Colo 3439：搜索条右边隔 8 点一颗「取消」，subheadline、默认色。
            // 搜索条是弹性的，让它占掉剩下的宽度（402 屏还剩 328）。
            Button {
                cancelSearch()
            } label: {
                Text("取消")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("取消搜索"))
        }
        .frame(minHeight: 44)
    }

    private func cancelSearch() {
        query = ""
        searchFocused = false
        withAnimation(.smooth(duration: 0.32)) { isSearching = false }
    }

    // MARK: - 时刻表

    /// 进页 / 「在看」条目变化时补齐季度时刻表，然后一次性重排。
    /// 拉不到数据就保持空表 —— 调用方已经先用「最近变更」排好了，不转圈。
    private func loadUpdateTimes() async {
        let entries = library.watchingEntries
        for entry in entries {
            await BangumiAirTimeService.shared.ensureLoaded(
                subjectID: entry.id,
                airDate: entry.airDate
            )
            if Task.isCancelled { return }
        }
        let times = makeUpdateTimes(for: entries)
        updateTimes = times
        // 一部时刻都没拿到（季度 JSON 没到 / 没有匹配项）时继续按最近变更排，
        // 不要切成一堆 nil 的 id 序，那对用户没有意义。
        updateTimesLoaded = !times.isEmpty
    }

    /// 把「星期 + HH:mm」拼成本周这一集的时刻；较早于首播的由查询层丢成 nil。
    private func makeUpdateTimes(for entries: [LibraryEntry]) -> [Int: Date] {
        let service = BangumiAirTimeService.shared
        let weekdays = resolvedWeekdays(for: entries)
        let now = Date()
        var result: [Int: Date] = [:]

        for entry in entries {
            guard let weekday = weekdays[entry.id],
                  let text = service.airTime(for: entry.id),
                  let time = Self.hourMinute(text),
                  let schedule = service.schedules[entry.id],
                  let epoch = CollectLibraryQuery.updateTimeForWeekday(
                      hour: time.hour,
                      minute: time.minute,
                      weekday: weekday,
                      now: now,
                      firstAir: schedule.first
                  )
            else { continue }
            result[entry.id] = epoch
        }
        return result
    }

    /// 放送星期：用户手改 → 时间表分组 → bangumi 日历 airWeekday
    /// （iOS 收藏条目没有该字段，用同源的 `DateTimeHelper` 从开播日算）。
    ///
    /// 收藏条目都在「时间表日历」里，所以把它们的 id 全交给 `resolveWeekdays`，
    /// 用户手动点过的星期才会全部生效；没点过的落到开播日星期。
    private func resolvedWeekdays(for entries: [LibraryEntry]) -> [Int: Int] {
        let store = BangumiTimelineStore.shared
        let collectTypes = library.entries.reduce(into: [Int: CollectType]()) { result, entry in
            result[entry.id] = entry.collectType
        }
        let custom = store.resolveWeekdays(
            inCalendar: Set(entries.map(\.id)),
            collectTypes: collectTypes
        )

        var weekdays: [Int: Int] = [:]
        for entry in entries {
            if let custom = custom[entry.id] {
                weekdays[entry.id] = custom
                continue
            }
            // 和时间表同一列：优先用日历里的分组（已含凌晨 0–5 点换到第二天），
            // 日历里没有才退回开播日过一遍同一条规则。
            if let column = TimelineWeekdayCache.weekday(of: entry.id) {
                weekdays[entry.id] = column
                continue
            }
            let airWeekday = DateTimeHelper.dateStringToWeekday(
                entry.airDate.isEmpty ? "2000-11-11" : entry.airDate
            )
            weekdays[entry.id] = TimelineColumn.weekday(
                bangumiWeekday: airWeekday,
                airTimeOf: entry.id
            )
        }
        return weekdays
    }

    private static func hourMinute(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    // MARK: - 列表

    private var content: some View {
        contentBody
            // LP 3462／Colo 3463：两处并存——标题区那块是主要的，列表里的空白和
            // 行间隙碰到也关。卡片自己的 onTapGesture 更具体，照旧进详情。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isSearching else { return }
                cancelSearch()
            }
    }

    @ViewBuilder
    private var contentBody: some View {
        if filteredEntries.isEmpty {
            if !trimmedQuery.isEmpty {
                searchEmptyState
            } else {
                libraryEmptyState
            }
        } else {
            ScrollView {
                // 海报网格（规格 §四）：列间距 10、行间距 14、左右 16、底部 24。
                // 列宽必须自己算出来给 `.fixed`：`.flexible()` 会被卡片内容的
                // 固有宽度撑开（实测卡宽 127、卡间 0.4、第三张越界 5）。
                // 量宽度的那颗探针在 body 上、ScrollView 外面——**不能**放在这里：
                // 放在这里量到的是内容宽，而内容宽又按这个数撑出来，自己咬自己，
                // 大字号时被顶到 504 就再也降不回来（Colo 2026-10-24 实测）。
                if libraryContainerSize.width > 0 {
                    LazyVGrid(
                        columns: gridColumns(width: libraryContentWidth),
                        spacing: 14
                    ) {
                        ForEach(filteredEntries) { entry in
                            LibraryPosterCard(
                                entry: entry,
                                isPending: pendingID == entry.id,
                                coverReloadToken: coverLoadRevision,
                                zoomNamespace: zoomNamespace,
                                onOpen: { router.push(.bangumiInfo(bangumiID: entry.id)) },
                                onChangeType: { type in changeType(entry, to: type) }
                            )
                            // 取消追番时这张卡淡出并缩到 0.92，其余卡片靠同一次动画补位。
                            .transition(cardRemovalTransition)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            // 点空白处取消搜索的手势挪到 content 外层了（三个分支一起接）。
            .scrollIndicators(.hidden)
            // 顶部滚动边缘：内容从吸附的头部下方滚过，模糊盖住那一行。
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private var libraryEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(library.entries.isEmpty ? "还没有追番" : "这个分类还没有番剧")
                .font(.headline)
            // 两种空要说两套话：整个库为空时告诉用户怎么加；
            // 只是这个分类为空时，库里明明有番，再劝他去详情页点「追番」会让人以为记错了。
            Text(library.entries.isEmpty
                 ? "在番剧详情页点「追番」即可加入这里。"
                 : "换一个分类，或者去推荐页找番剧。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if library.entries.isEmpty {
                Button("去推荐看看") {
                    router.selectedDestination = .popular
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 搜索无命中：不沿用「这个分类还没有番剧」，直接给清空搜索的出口。
    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Text("没有匹配的番剧")
                .font(.headline)
            Button("清空搜索") {
                query = ""
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 改收藏状态，两条路分开走：
    /// * `type == .none` 是「取消追番」——这部从列表里消失，包一层动画让它淡出缩小，
    ///   其余卡片在同一次动画里归位（Ato 2026-10-24：不许手写定时器，也不许删完重排）；
    /// * 其余是改状态——卡片不动，只有角上那颗符号换掉，**不能包动画**，
    ///   否则整页会跟着动一下。
    private func changeType(_ entry: LibraryEntry, to type: CollectType) {
        guard pendingID == nil else { return }
        // 「自动同步追番」开着时先把改动推给 Bangumi，推不成功就整次作废
        // （collect_controller.dart: _syncBangumiCollectIfEnabled）。
        // 没开就是纯本地改动，和以前一模一样。
        guard settings.bangumiSyncEnable else {
            commitType(entry, to: type)
            return
        }
        pendingID = entry.id
        Task {
            let pushed = await environment.bangumiSync.pushCollectible(
                bangumiID: entry.id,
                type: type
            )
            pendingID = nil
            guard pushed else {
                toastMessage = String(localized: "同步到 Bangumi 失败，已取消本次状态修改")
                return
            }
            commitType(entry, to: type)
            if settings.bangumiImmediateSyncToastEnable { toastMessage = String(localized: "已同步到 Bangumi") }
        }
    }

    /// 真正落本地的那一半：动画与补位规则只在这里。
    private func commitType(_ entry: LibraryEntry, to type: CollectType) {
        pendingID = entry.id
        if type == .none {
            withAnimation(removalAnimation) {
                library.remove(bangumiID: entry.id)
            }
        } else {
            var updated = entry
            updated.type = type.rawValue
            updated.updatedAt = Date()
            library.upsert(updated)
        }
        // 删掉的那一条已经不在列表里，别把 pendingID 留在它身上。
        pendingID = nil
    }

    /// 出门那一下的曲线：Colo 2026-10-24 定的 `.snappy(0.3)`。
    /// `easeOut` 是前快后慢，卡片 0.12 秒就几乎看不见了，后面那截缩小是空转，
    /// 而补位要到后半段才动，看着像两件事。
    /// 开了「减少动态效果」的人只淡出（0.2 秒）、不缩小；其余卡片在这 0.2 秒里
    /// 一起归位，不瞬移——瞬移要把删除拆成两帧、中间插手写延迟，Ato 2026-10-24 已否，
    /// 代价就是那十几点位移跟着走 0.2 秒（Colo 同日收进规格）。
    private var removalAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3)
    }

    /// 一句提示，2 秒后自己消失；连点只留最新那句（同详情页的实现）。
    @ViewBuilder
    private var toastView: some View {
        if let message = toastMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .padding(.bottom, 16)
                .transition(.opacity)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    toastMessage = nil
                }
        }
    }

    private var cardRemovalTransition: AnyTransition {
        reduceMotion
            ? .asymmetric(insertion: .opacity, removal: .opacity)
            : .asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .scale(scale: 0.92))
            )
    }

    /// 追番页的网络封面严格按当前网格顺序一张一张取；本地缓存仍由各卡片并行读取。
    private func loadLibraryCovers() async {
        guard libraryContainerSize.width > 0 else { return }
        let pixelSize = libraryCoverPixelSize
        coverLoadRevision &+= 1
        for url in filteredEntries.map(\.imageURL) {
            guard !Task.isCancelled else { return }
            if KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixelSize) == nil {
                _ = await KazumiImageLoader.shared.loadSequentially(url, pixelSize: pixelSize)
            }
            guard !Task.isCancelled else { return }
            coverLoadRevision &+= 1
        }
    }

    private var coverLoadKey: [String] {
        ["px:\(libraryCoverPixelSize)"] + filteredEntries.map { "\($0.id)|\($0.imageURL)" }
    }

    private var libraryCoverPixelSize: Int {
        let count = CGFloat(columnCount)
        let available = libraryContentWidth - Self.columnSpacing * max(0, count - 1)
        let width = available > 0 ? min(200, available / count) : 200
        return KazumiImageLoader.pixelSize(
            for: CGSize(width: width, height: width / BangumiPosterCard.coverAspectRatio)
        )
    }
}

/// 收藏卡片：沿用时间表卡片的外观，右侧菜单可改收藏状态。
private struct LibraryEntryCard: View {
    let entry: LibraryEntry
    let isPending: Bool
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?
    var onOpen: () -> Void
    var onChangeType: (CollectType) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 封面宽度与时间表卡片保持一致（88pt），整页的封面尺寸就统一了。
    private static let coverWidth: CGFloat = 88

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    BangumiRemoteImage(url: entry.imageURL)
                        .frame(
                            width: Self.coverWidth,
                            height: Self.coverWidth / BangumiPosterCard.coverAspectRatio
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.displayName)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if entry.rating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(String(format: "%.1f", entry.rating))
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        }

                        Text(entry.collectType.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous).fill(KazumiPalette.accent(for: colorScheme).opacity(0.14)))

                        // 这里原本有一行「看到第 X / Y 话」：原版列表条目没有这一项，
                        // 且 currentEpisode 今天没有一处会写（恒为 0），印出来是假进度。
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            // 只有「封面 + 文字」这块可点区域参与缩放转场，
            // 右侧的收藏状态菜单不跟着放大。
            .kazumiZoomSource(id: entry.id, namespace: zoomNamespace)

            // 这一份也走共用组件：列表布局今天还没接上（没有调用处），
            // 但留着一份自己写的菜单，就是留着一份将来会分叉的。
            CollectStatusMenu(
                current: entry.collectType,
                onChange: onChangeType
            ) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .hitTarget44()
                    .opacity(isPending ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("修改追番状态")
        }
        .padding(12)
        .background(
            KazumiPalette.cardShape(cornerRadius: 28, scheme: colorScheme)
        )
        // LP 2026-10-23：整张卡片都能点开，不再只有封面那一小块。
        // 右侧那颗「修改状态」是自己的按钮，会先吃掉它范围内的点击。
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture { onOpen() }
    }
}


/// 量网格可用容器尺寸用的一次性 preference（追番页列宽与限宽按它算）。
private struct LibraryContentWidthKey: PreferenceKey {
    // 必须是 `let`：`var` 在严格并发下是非隔离的全局可变状态，编译不过
    // （仓库里 InfoTabPanels.swift 的 IntroHeightKey 就是这个写法）。
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = CGSize(
            width: max(value.width, nextValue().width),
            height: max(value.height, nextValue().height)
        )
    }
}
