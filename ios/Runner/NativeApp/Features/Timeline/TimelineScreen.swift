//
//  TimelineScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/timeline/timeline_page.dart：
//  * 顶栏左边是**放送季度**（点开切换季度），右边是「排序与筛选」玻璃药丸
//    （图标 + 当前排序名，有筛选时带角标）——与原版窄屏顶栏一致；
//  * 下面是一排 7 天的选择器：今天显示「今天」，其余显示「周X」，各带当日数量；
//  * 主体是所选那天的卡片列表（BangumiTimelineCard），
//    带「HH:mm 更新」「第 N 话」两个胶囊和正在追的书签。
//

import SwiftUI

struct TimelineScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @Environment(SettingsStore.self) private var settings
    @State private var controller = TimelineController()
    @State private var selectedWeekday = TimelineScreen.todayIndex
    @State private var isShowingSeasonPicker = false
    @State private var weekdayDragX: CGFloat?
    @State private var pageOffsetX: CGFloat = 0
    @State private var pageViewportWidth: CGFloat = 1

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 量到的页面尺寸（§6.0：列数与限宽都按容器算，不按整屏）。
    @State private var containerSize: CGSize = .zero

    /// B 档：宽且不矮。
    private var isWideTier: Bool {
        containerSize.width >= 700 && containerSize.height >= 600
    }

    /// C 档：宽但矮（§六之二）。
    private var isShortTier: Bool {
        containerSize.width >= 700 && containerSize.height < 600
    }

    /// 当前打开着详情的番剧 id（从导航栈里读）。
    @State private var detailItemID: Int?
    /// 返回后要做淡入的卡片：改了放送星期、卡片换了那一天时用。
    @State private var flashItemID: Int?
    /// 淡入的当前状态：false 是起始帧（透明、低 8 点），true 是落位。
    @State private var flashVisible = true
    /// 这些卡片返回时不登记缩放转场源：卡片已经换了位置，硬套放大接不上。
    @State private var zoomSuppressedIDs: Set<Int> = []

    private static let weekdayTitles = [String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六"), String(localized: "日")]

    /// ISO 星期是 1...7（周一...周日），这里换成 0 基下标。
    private static var todayIndex: Int {
        max(0, min(6, DateTimeHelper.isoWeekday(Date()) - 1))
    }

    private static let seasonColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 4
    )

    /// 派生数据：追番状态表，供合并手动条目与筛选共用。
    private var collectTypes: [Int: CollectType] {
        library.entries.reduce(into: [Int: CollectType]()) { result, entry in
            result[entry.id] = entry.collectType
        }
    }

    // MARK: - 派生数据

    private var watchingIDs: Set<Int> {
        Set(library.entries.filter { $0.collectType == .watching }.map(\.id))
    }

    private var watchedIDs: Set<Int> {
        Set(library.entries.filter { $0.collectType == .watched }.map(\.id))
    }

    private var droppedIDs: Set<Int> {
        Set(library.entries.filter { $0.collectType == .dropped }.map(\.id))
    }

    private var filteredCalendar: [[BangumiItem]] {
        controller.filterCalendar(
            watchingIDs: watchingIDs,
            watchedIDs: watchedIDs,
            droppedIDs: droppedIDs
        )
    }

    var body: some View {
        content
            // 量容器尺寸：宽档日列表的列数、C 档标题都按它算。
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                guard size.width > 0 else { return }
                containerSize = size
            }
            // 头部与星期条合成一块吸附在顶部：两块都是固定块，
            // 只提 header 的话内容仍会从星期条下面硬切过去。
            // LP 2026-10-24（后一条）：顶栏不要毛玻璃了，改纯色底。
            // 这块（标题＋星期条）铺页面的底色，一直铺进状态栏，上滑时内容不从缝里透出来。
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    weekdaySelector
                }
                // `ignoresSafeAreaEdges: .top` 是关键（Colo 2026-10-24）：不加只从状态栏
                // 下面那 62 点开始铺，最上面一条还是光的，内容照样从时钟后面穿过去。
                .background(
                    KazumiPalette.background(for: colorScheme),
                    ignoresSafeAreaEdges: .top
                )
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingSeasonPicker) {
            seasonSheet
        }
        .task {
            await loadInitialSeason()
        }
        // 详情页改完放送星期 / 点亮「在时间表展示」后，回到这里立刻重排。
        .onChange(of: BangumiTimelineStore.shared.revision) { _, _ in
            Task {
                await controller.refreshCustomEntries(collectTypes: collectTypes)
                prepareWeekdayMove()
            }
        }
        // 详情页开合：记下是哪部番，返回时按需播淡入。
        .onChange(of: openedDetailID) { _, new in
            if let new {
                detailItemID = new
            } else {
                detailItemID = nil
                startFlashIfNeeded()
            }
        }
    }

    // MARK: - 详情开合

    /// 导航栈顶如果就是详情页，返回它打开的是哪部番；否则 nil。
    private var openedDetailID: Int? {
        if case .bangumiInfo(let bangumiID, _) = router.timelinePath.last { return bangumiID }
        return nil
    }

    /// 详情页里改了放送星期、这部番换了列：把页面直接切到新那一天，
    /// 并让它在返回时淡入。
    ///
    /// 不切页的话，返回时缩放转场要找的卡片在另一天那一页上，
    /// 放大回缩接不上；切过去之后用户看到的是「它搬到了周三」。
    private func prepareWeekdayMove() {
        guard let detailItemID else { return }
        let newDay = filteredCalendar.firstIndex { day in
            day.contains { $0.id == detailItemID }
        }
        guard let newDay, newDay != selectedWeekday else { return }
        // 卡片已经换位置：这一次返回不登记缩放转场源，交给下面的淡入。
        zoomSuppressedIDs.insert(detailItemID)
        flashItemID = detailItemID
        flashVisible = false
        // 不带动画：详情还盖在上面，用户看不到这一下硬切。
        selectedWeekday = newDay
    }

    /// 详情收起之后播淡入：透明度 0→1、位置从下 8 点回到原位，180 毫秒。
    private func startFlashIfNeeded() {
        guard let flashItemID else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            flashVisible = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            // 动画结束后恢复常态，卡片以后照旧走缩放转场。
            if self.flashItemID == flashItemID {
                self.flashItemID = nil
                self.zoomSuppressedIDs.remove(flashItemID)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            seasonTitleButton(expands: !isWideTier)
            // 宽档把标题与选项钮之间的空档限制在 700 以内（§6.1），整体左对齐。
            Spacer(minLength: 8)
                .frame(maxWidth: isWideTier ? 700 : nil)
            optionsButton
            if isWideTier {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// 顶栏标题就是当前季度，和原版 `_buildSeasonPicker(inAppBar: true)` 一致。
    /// 点击区域覆盖整块标题，当前季度 + 箭头即可。
    private func seasonTitleButton(expands: Bool) -> some View {
        Button {
            isShowingSeasonPicker = true
        } label: {
            // LP 3058 定了名字「新番」（Camo 3055 推的）：两字、切到哪季都成立。
            // 标题不再写季度，季度就落在下面一行小字里——页面上得看得见自己在看哪一季。
            // 字号字重回大标题那档（34 半粗），菜单不变，点它还是弹放送季度。
            // 季度小字放在标题右边、同一行（LP 3081）：放到标题下面会把标题顶上去，
            // 而右上那颗按钮不会跟着动，两下就错位了。
            // Ato 6550：但最大字号下「新番」自己就占掉大半行，季度被挤成「2026 …」，
            // 那比顶上去难看得多——辅助功能字号下改成上下排，季度独占一行。
            let label = Group {
                HStack(spacing: 4) {
                    Text("新番")
                        // C 档大标题改 inline（§六之二）：34 半粗 → 20 半粗。
                        .font(isShortTier ? Font.title3.weight(.semibold) : Font.largeTitle.weight(.semibold))
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    // 尖角跟着标题一档走：34 配 17（Colo 3035 定的是 28 配 15）。
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(controller.seasonLabel)
                    // 13 号、次要色（Colo 3061）。
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) { label }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) { label }
                }
            }
            // 宽档标题按内容宽排，空档由 header 的 Spacer 控制（§6.1）。
            .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "新番，切换放送季度，当前 \(controller.seasonLabel)"))
    }

    /// 右上角：排序与筛选。LP 2631/2632/2637：去掉排序名，只留符号，玻璃底留着。
    /// LP 2643 / Colo 2644：点开改成从这颗按钮弹出的菜单 —— 排序用 Picker（天然带 ✓），
    /// 筛选用 Menu 里的 Toggle（选中就带 ✓）；有筛选生效时这颗胶囊换成实心主题色、
    /// 图标换 onAccent，且不再叠玻璃（玻璃会和实心色搅在一起）。
    private var optionsButton: some View {
        let filterCount = controller.activeFilterCount
        let hasFilters = filterCount > 0
        return Menu {
            Picker("排序", selection: sortBinding) {
                ForEach(TimelineSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Section {
                Toggle("隐藏看过的番剧", isOn: notShowWatchedBinding)
                Toggle("隐藏抛弃的番剧", isOn: notShowAbandonedBinding)
                Toggle("只看正在追的番剧", isOn: onlyShowWatchingBinding)
            }
        } label: {
            iconCapsule(hasFilters: hasFilters)
        }
        .accessibilityLabel("排序与筛选")
        .accessibilityValue(
            hasFilters
                ? String(localized: "\(controller.sort.title)，已启用 \(filterCount) 项筛选")
                : String(localized: "\(controller.sort.title)，未启用筛选")
        )
    }

    /// 排序一改，controller 要重排整张时间表（异步），所以 setter 里起个任务。
    private var sortBinding: Binding<TimelineSort> {
        Binding(
            get: { controller.sort },
            set: { newValue in
                guard newValue != controller.sort else { return }
                Task { await controller.changeSort(newValue) }
            }
        )
    }

    /// 那颗按钮本体。LP 2652 / Colo 2653：36×36 正圆，图标 18 居中，命中区 44；
    /// 有筛选时填实心主题色 + onAccent 图标，形状不跟着变，还是正圆。
    /// 40 见方的胶囊由 `kazumiGlassShapeModifier` 渲染出来就是正圆，36 同理。
    @ViewBuilder
    private func iconCapsule(hasFilters: Bool) -> some View {
        let circle = Circle()
        // 标题回到大标题那档，这颗也跟着长一档：40 正圆、图标 20（LP 3050）。
        let icon = Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 20, weight: .bold))
        if hasFilters {
            icon
                .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                .frame(width: 40, height: 40)
                .background(circle.fill(KazumiPalette.accent(for: colorScheme)))
                .contentShape(circle)
                .frame(width: 44, height: 44)
        } else {
            icon
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .kazumiGlassCapsule(interactive: true)
                .contentShape(circle)
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - 星期选择器

    // 外框是纯色胶囊，选中格垫一块 primary 8% 的实心滑块（LP 2519：液态玻璃那套切换效果删掉，
    // 太花且不像原生，只留实心填充；滑块仍跟手/跟翻页走，只是不再液化和回凝）。
    /// 轨道可见高。
    private static let weekdayTrackHeight: CGFloat = 44
    /// 实心滑块相对轨道的内缩。
    private static let weekdayGlassInset: CGFloat = 3

    private var weekdaySelector: some View {
        Group {
            if settings.timelineShowCount {
                // 开着计数：原来的玻璃滑块（每天带番剧数量）。
                sliderWeekdaySelector
            } else {
                // 关掉计数（LP 5039，默认）：换成规则编辑页顶部那种分段 tab，
                // 名字只留「周一…周日/今天」，不再写数量。
                segmentedWeekdaySelector
            }
        }
    }

    /// 分段 tab（对应 `PluginEditorView` 顶部的 `Picker(...).pickerStyle(.segmented)`）。
    private var segmentedWeekdaySelector: some View {
        Picker("星期", selection: Binding(
            get: { selectedWeekday },
            set: { selectWeekday($0) }
        )) {
            ForEach(Array(Self.weekdayTitles.indices), id: \.self) { day in
                Text(dayTitle(day)).tag(day)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var sliderWeekdaySelector: some View {
        GeometryReader { proxy in
            let cellWidth = max(proxy.size.width, 1) / 7
            // 跟手：翻页滚动时玻璃直接按滚动偏移算，手指到哪它到哪；
            // 只有在拖星期条时才用 weekdayDragX 覆盖。
            let pageFloat = pageViewportWidth > 1 ? pageOffsetX / max(pageViewportWidth, 1) : CGFloat(selectedWeekday)
            let trackingX = cellWidth * (pageFloat + 0.5)
            let restX = cellWidth * (CGFloat(selectedWeekday) + 0.5)
            // 正在滚就跟滚动走，静止时回到选中格中心；拖条时以手指为准。
            let isPaging = abs(pageFloat - CGFloat(selectedWeekday)) > 0.01
            let baseX: CGFloat = isPaging ? trackingX : restX
            let centerX: CGFloat = {
                guard let x = weekdayDragX else { return baseX }
                return min(max(x, cellWidth / 2), max(proxy.size.width - cellWidth / 2, cellWidth / 2))
            }()

            ZStack(alignment: .topLeading) {
                // 外框：纯色胶囊托住玻璃，黑 6%、半径 6、y 2 的浅阴影让它离开页面，
                // 再加 1 点内描边，玻璃膨胀越出上下边时会被框沿折出一道亮弧。
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)

                weekdaySlider(centerX: centerX, cellWidth: cellWidth)

                weekdayLabels
            }
            .frame(height: Self.weekdayTrackHeight)
            .contentShape(Capsule(style: .continuous))
            // Colo 3460：七格之间的空隙也得能点，按 x 落在哪格就选哪格。
            // 轻点走这条（空格子也接得住）；拖拽另走 weekdayDragGesture 跟手。
            .onTapGesture { location in
                selectWeekday(weekdayIndex(at: location.x, cellWidth: cellWidth))
            }
            .gesture(weekdayDragGesture(width: proxy.size.width))
        }
        .frame(height: Self.weekdayTrackHeight)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // LP 2535 / Colo 2537：顶栏底色下沿贴着星期条下沿，不加空白底边；
        // 原来那 12 点搬到列表顶上，滚动时跟着内容走掉。
    }

    /// 选中格的实心滑块：浅色填充、字不变色（LP 2645 / Ato 2646 作废了主题色那版——
    /// 底色太深，左右翻页时格子的字换色会闪一下）。
    private func weekdaySlider(centerX: CGFloat, cellWidth: CGFloat) -> some View {
        let inset = Self.weekdayGlassInset
        let width = max(cellWidth - inset * 2, 1)
        return Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: Self.weekdayTrackHeight - inset * 2)
            .offset(x: centerX - width / 2, y: inset)
    }

    private var weekdayLabels: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { day in
                weekdayCell(day)
            }
        }
        .frame(height: Self.weekdayTrackHeight)
        .sensoryFeedback(.selection, trigger: selectedWeekday)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("放送星期")
    }

    private func weekdayCell(_ day: Int) -> some View {
        let isSelected = day == selectedWeekday
        return VStack(spacing: 1) {
            Text(dayTitle(day))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(countText(day))
                .font(.caption2.weight(.medium))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.weekdayTrackHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(spokenDayTitle(day))，\(countText(day)) 部"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectWeekday(day) }
    }

    private func dayTitle(_ day: Int) -> String {
        isTodayColumn(day) ? String(localized: "今天") : String(localized: "周\(Self.weekdayTitles[day])")
    }

    /// 读屏念全称：「星期三」「今天」。
    private func spokenDayTitle(_ day: Int) -> String {
        isTodayColumn(day) ? String(localized: "今天") : String(localized: "星期\(Self.weekdayTitles[day])")
    }

    private func isTodayColumn(_ day: Int) -> Bool {
        controller.isCurrentSeason && day == Self.todayIndex
    }

    private func countText(_ day: Int) -> String {
        if controller.isLoading && controller.bangumiCalendar.allSatisfy({ $0.isEmpty }) {
            return "—"
        }
        return "\(filteredCalendar.indices.contains(day) ? filteredCalendar[day].count : 0)"
    }

    private func selectWeekday(_ day: Int) {
        guard day != selectedWeekday else { return }
        // 点选星期：让页面滑过去慢一点，玻璃跟着滚动走，不再用固定时长硬切。
        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
            selectedWeekday = day
        }
    }

    /// 一碰实心滑块就跟手；横移超过 4 点滑块跟着手指走，指到第几格就选第几格。
    private func weekdayDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cellWidth = max(width, 1) / 7
                if abs(value.translation.width) > 4 || weekdayDragX != nil {
                    let x = min(max(value.location.x, cellWidth / 2),
                                max(width - cellWidth / 2, cellWidth / 2))
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) {
                        weekdayDragX = x
                    }
                    let day = weekdayIndex(at: value.location.x, cellWidth: cellWidth)
                    if day != selectedWeekday {
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                            selectedWeekday = day
                        }
                    }
                }
            }
            .onEnded { value in
                let cellWidth = max(width, 1) / 7
                // 夹进轨道内再判格：落在最后一格右边缘外也不能算成不存在的第 8 格。
                let x = min(max(value.location.x, 0), max(width, 1) - 0.001)
                let day = weekdayIndex(at: x, cellWidth: cellWidth)
                withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                    selectedWeekday = day
                    weekdayDragX = nil
                }
            }
    }

    private func weekdayIndex(at x: CGFloat, cellWidth: CGFloat) -> Int {
        min(max(Int((x / cellWidth).rounded(.down)), 0), 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && controller.bangumiCalendar.allSatisfy({ $0.isEmpty }) {
            // 没有缓存可铺时（第一次装、或缓存被清）才走这里。
            // 不再是灰底一个转圈（LP 5051）：画几条卡片占位，让页面一出来就有形状。
            TimelineSkeletonList()
        } else if controller.isTimeOut {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("本季时间表加载失败")
                    .font(.headline)
                Button("重试") {
                    Task {
                        await controller.loadSeason(controller.selectedDate, collectTypes: collectTypes)
                        prefetchCovers()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 一页一天：用横向分页 ScrollView，滚动偏移直接驱动星期条玻璃，
            // 手指到哪玻璃到哪；松手弹到最近页，真换天那一刻才开始凝固计时。
            GeometryReader { pageProxy in
                // 页宽 = 安全区内宽 + 左右安全区：横屏 750 + 62 + 62 = 874，正好一屏。
                // 之前页宽取安全区内宽 750，视口却铺到屏幕边，右边 62 点就永远露着下一天，
                // 翻页步长和页宽也不一致，每换一天攒 31 点。
                let pageW = max(pageProxy.size.width
                    + pageProxy.safeAreaInsets.leading
                    + pageProxy.safeAreaInsets.trailing, 1)
                ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { day in
                            dayPage(day)
                                .frame(width: pageW)
                                .id(day)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding<Int?>(get: { selectedWeekday }, set: { if let v = $0 { selectedWeekday = v } }))
                // LP 3457/3460：冷启动必须落在「今天」。光靠 scrollPosition 的初始 id 在
                // .paging 下不一定生效（实测滑块停在周一、内容也是周一，而「今天」标在周二），
                // 所以首帧布局完再显式滚一次。
                .onAppear {
                    let target = selectedWeekday
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        withAnimation(nil) { scrollProxy.scrollTo(target, anchor: .leading) }
                    }
                }
                .scrollIndicators(.hidden)
                // 视口也铺到整屏宽：视口比页宽窄一点，下一天就会从右边露出来。
                .frame(width: pageW)
                .ignoresSafeArea(.container, edges: .horizontal)
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    geo.contentOffset.x
                }, action: { _, new in
                    pageOffsetX = new
                })
                .onAppear { pageViewportWidth = pageW }
                .onChange(of: pageW) { _, new in
                    pageViewportWidth = max(new, 1)
                    // 转屏会换页宽（402 → 874），旧偏移按旧页宽算，必须重新落到选中的那天，
                    // 否则一转过屏就停在半页上。
                    withAnimation(nil) { scrollProxy.scrollTo(selectedWeekday, anchor: .leading) }
                }
                }
            }
            // 轻触感反馈：滑切与点选星期都会触发；LP 清单「触感反馈」关掉后不再震。
            .sensoryFeedback(.selection, trigger: hapticTrigger)
        }
    }

    /// 触感反馈关闭时传 nil：`.sensoryFeedback` 不比较到新值就不触发。
    private var hapticTrigger: Int? {
        settings.hapticFeedbackEnabled ? selectedWeekday : nil
    }

    @ViewBuilder
    private func dayPage(_ day: Int) -> some View {
        let items = filteredCalendar.indices.contains(day) ? filteredCalendar[day] : []
        if items.isEmpty {
            emptyState(day: day)
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                // 宽档：日列表改成网格（§6.1），卡片不再被拉成 1342×160。
                if containerSize.width > 0 {
                    Group {
                        if containerSize.width >= 700 {
                            LazyVGrid(columns: wideDayColumns, spacing: 10) {
                                dayCards(items)
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                dayCards(items)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            // 顶部渐进模糊边（.soft）：只作用于顶部一条，不叠材质、不加底色。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .refreshable {
                await controller.loadSeason(controller.selectedDate, collectTypes: collectTypes)
                prefetchCovers()
            }
            // 卡片换了列之后，把它滚进可见范围，否则淡入发生在屏幕外等于没发生。
            .onChange(of: flashItemID) { _, new in
                guard let new, items.contains(where: { $0.id == new }) else { return }
                proxy.scrollTo(new, anchor: .center)
            }
            }
        }
    }

    /// 宽档日列表的列数：n = clamp(floor((容器宽 − 24 + 12) / 360), 1, 3)（§6.1）。
    /// 门槛 430 → 360（Colo 6808）：430 是按竖屏卡宽定的，iPhone 横屏 750 会算出 1 列、
    /// 一张 726 宽的卡，402 高的屏上只放得下两行；360 后 750 出 2 列，iPad 各档不变。
    private var wideDayColumns: [GridItem] {
        let width = containerSize.width
        let count = min(max(Int(floor((width - 24 + 12) / 360)), 1), 3)
        let spacing: CGFloat = 12
        let each = max(1, (width - 24 - spacing * CGFloat(count - 1)) / CGFloat(count))
        return Array(repeating: GridItem(.fixed(each), spacing: spacing), count: count)
    }

    @ViewBuilder
    private func dayCards(_ items: [BangumiItem]) -> some View {
        ForEach(items) { item in
            BangumiTimelineCard(
                item: item,
                showRating: settings.showRating,
                isWatching: watchingIDs.contains(item.id),
                updateText: controller.updateText(for: item),
                currentEpisode: controller.currentEpisode(for: item),
                // 宽档卡片高 176，给两行标题留地方（§6.1）。
                cardMinHeight: containerSize.width >= 700 ? 176 : nil,
                zoomNamespace: zoomSuppressedIDs.contains(item.id) ? nil : zoomNamespace
            )
            .opacity(isFlashing(item.id) ? 0 : 1)
            .offset(y: isFlashing(item.id) ? 8 : 0)
        }
    }

    /// 这张卡片是否还在淡入的起始帧。
    private func isFlashing(_ id: Int) -> Bool {
        flashItemID == id && !flashVisible
    }

    private func emptyState(day: Int) -> some View {
        let filteredOut = controller.bangumiCalendar.indices.contains(day)
            && !controller.bangumiCalendar[day].isEmpty
        return VStack(spacing: 10) {
            Image(
                systemName: filteredOut
                    ? "line.3.horizontal.decrease.circle"
                    : "calendar.badge.exclamationmark"
            )
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.secondary)
            Text(filteredOut ? "没有符合筛选的番剧" : "这一天没有播出番剧")
                .font(.headline)
            if filteredOut {
                Button("清除筛选") {
                    controller.clearFilters()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 季度

    private var seasonSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(String(localized: "正在查看 \(controller.seasonLabel)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    // 与原版一致：最近 20 年，每年四个季度**横向**排列。
                    ForEach(Self.seasonYears, id: \.self) { year in
                        yearSection(year)
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("放送季度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isShowingSeasonPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func yearSection(_ year: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 年份不走本地化插值，否则会被渲染成「2,026」。
            Text(year, format: .number.grouping(.never))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.seasonColumns, spacing: 8) {
                ForEach([1, 4, 7, 10], id: \.self) { month in
                    seasonChip(year: year, month: month)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func seasonChip(year: Int, month: Int) -> some View {
        let date = Self.seasonStart(year: year, month: month)
        let selected = AnimeSeason.isSameSeason(controller.selectedDate, date)
        let disabled = date > Date()
        let foreground: Color = selected ? KazumiPalette.onAccent(for: colorScheme) : .primary
        let background: Color = selected
            ? KazumiPalette.accent(for: colorScheme)
            : KazumiPalette.cardSurface(for: colorScheme)

        return Button {
            selectSeason(date)
        } label: {
            Text(String(localized: "\(AnimeSeason.seasonString(month: month))季"))
                .font(.subheadline.weight(selected ? .bold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    // MARK: - 筛选绑定

    private var notShowWatchedBinding: Binding<Bool> {
        Binding(
            get: { controller.notShowWatchedBangumis },
            set: { controller.setNotShowWatchedBangumis($0) }
        )
    }

    private var notShowAbandonedBinding: Binding<Bool> {
        Binding(
            get: { controller.notShowAbandonedBangumis },
            set: { controller.setNotShowAbandonedBangumis($0) }
        )
    }

    private var onlyShowWatchingBinding: Binding<Bool> {
        Binding(
            get: { controller.onlyShowWatchingBangumis },
            set: { controller.setOnlyShowWatchingBangumis($0) }
        )
    }

    // MARK: - 动作

    private func loadInitialSeason() async {
        guard controller.bangumiCalendar.isEmpty else { return }
        selectedWeekday = Self.todayIndex
        await controller.loadSeason(Date(), collectTypes: collectTypes)
        prefetchCovers()
    }

    private func selectSeason(_ date: Date) {
        isShowingSeasonPicker = false
        Task {
            await controller.loadSeason(date, collectTypes: collectTypes)
            prefetchCovers()
        }
    }

    /// 季初那一个月的 1 号（与原版 `DateTime(year, month)` 一致）。
    private static func seasonStart(year: Int, month: Int) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    private static var seasonYears: [Int] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (0..<20).map { year - $0 }
    }

    /// 列表出现前先预热封面，滚动时不再一张张从网络取。
    ///
    /// 档位按卡片封面的真实尺寸给（88 宽、0.65 比例 → 约 135 高 → 300 档），
    /// 不是默认的 600 档。一天一百多张封面，按 600 档解完要 150MB 以上，
    /// 超过内存缓存的 128MB 上限，NSCache 只能反复淘汰——「缓存过的封面
    /// 一会儿又没了」就是这么来的（LP 3457）。
    private func prefetchCovers() {
        // 当前这天排最前：预取是按顺序一张张取的，屏幕上先看到的就是这一天。
        let others = (0..<7).filter { $0 != selectedWeekday }
        let urls = ([selectedWeekday] + others).flatMap { day -> [String] in
            guard day < controller.bangumiCalendar.count else { return [] }
            return controller.bangumiCalendar[day].map(\.largeImage)
        }
        let cover = CGSize(width: 88, height: 88 / BangumiPosterCard.coverAspectRatio)
        KazumiImageLoader.shared.prefetch(urls, pixelSize: KazumiImageLoader.pixelSize(for: cover))
    }
}

