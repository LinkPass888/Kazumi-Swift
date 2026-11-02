//
//  SearchFilterSheet.swift
//  Kazumi
//
//  对应 lib/pages/search/search_filter_sheet.dart 的「按条件查找」面板。
//  规格按 main 逐条复刻（Colo 3029 / kazumi-search-filter-panel-spec.md）：
//  标题「筛选番剧」＋右上关闭 → 编号定位行（仅按编号搜索时）→ 排序方式下拉
//  → 四组可折叠分组（题材标签 / 放送时间 / 评分与排名 / 收藏状态），组间一条
//  1pt 分隔线 → 底部「重置」＋固定 130 宽的「查看结果」。
//
//  面板里不出现任何搜索语法：条件串只在内部拼，用户看到的是人话摘要。
//

import SwiftUI

/// 面板关掉时带回来的东西：条件本身，加上两颗「隐藏」开关。
/// 对应 main 的 _SearchFilterResult——那两个开关不在条件串里，是搜索页自己的设置。
struct SearchFilterResult {
    var state: SearchFilterState
    var notShowWatched: Bool
    var notShowAbandoned: Bool
}

struct SearchFilterSheet: View {
    var onApply: (SearchFilterResult) -> Void

    @State private var state: SearchFilterState
    @State private var notShowWatched: Bool
    @State private var notShowAbandoned: Bool
    @State private var customTag = ""
    @State private var isShowingDatePicker = false

    // 四组各自独立折叠；初值跟着当前条件走（有内容就展开），之后由用户点组头改。
    @State private var tagsExpanded: Bool
    @State private var timeExpanded: Bool
    @State private var scoreExpanded: Bool
    @State private var collectExpanded: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTagFieldFocused: Bool

    /// 与 main 的 defaultAnimeTags 一致，逐字照抄，一个都不加。
    private static let tags: [String] = [
        "日常", "原创", "校园", "搞笑", "奇幻", "百合", "恋爱", "悬疑",
        "热血", "后宫", "机战", "轻改", "偶像", "治愈", "异世界",
    ]

    /// 排序项与 main 的 _searchSortLabels 一致。
    private static let sorts: [String] = ["heat", "rank", "score", "match"]

    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    init(
        initial: SearchFilterState,
        notShowWatched: Bool = false,
        notShowAbandoned: Bool = false,
        onApply: @escaping (SearchFilterResult) -> Void
    ) {
        self.onApply = onApply
        _state = State(initialValue: initial)
        _notShowWatched = State(initialValue: notShowWatched)
        _notShowAbandoned = State(initialValue: notShowAbandoned)
        _tagsExpanded = State(initialValue: !initial.tags.isEmpty)
        _timeExpanded = State(
            initialValue: !initial.season.isEmpty
                || initial.dateRange != nil
                || !initial.weekdays.isEmpty
        )
        _scoreExpanded = State(
            initialValue: initial.scoreRange?.isValid == true || initial.rankRange?.isValid == true
        )
        _collectExpanded = State(initialValue: notShowWatched || notShowAbandoned)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if state.isIdSearch {
                            idNoticeRow
                        }

                        sortField

                        Spacer().frame(height: 16)

                        tagsGroup

                        groupDivider

                        timeGroup

                        groupDivider

                        scoreGroup

                        groupDivider

                        collectGroup
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)

                bottomBar
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
            .navigationTitle("筛选番剧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 分工（Colo 3031）：关闭＝不带条件就走，「查看结果」＝带着条件走。
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $isShowingDatePicker) {
            DateRangePickerSheet(initial: state.dateRange) { range in
                // 选了自定义日期就不再叠加季度（对应 main）。
                state.season = ""
                state.dateRange = range
                timeExpanded = true
            }
        }
    }

    // MARK: - 顶部

    /// 按编号搜索时的提示行：编号会顶掉其他条件，先告诉用户怎么退出这种状态。
    private var idNoticeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("当前按编号定位番剧")
                    .font(.subheadline)
                Text("清除编号后，可以组合其他条件查找。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("清除编号") {
                state.id = ""
            }
            .font(.footnote)
        }
        .padding(.vertical, 10)
    }

    /// 排序方式：label 在左、当前值在下拉里（对应 DropdownButtonFormField）。
    private var sortField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("排序方式")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(Self.sorts, id: \.self) { sort in
                    Button {
                        state.sort = sort
                    } label: {
                        if sort == state.sort {
                            Label("按\(Self.sortTitle(sort))排序", systemImage: "checkmark")
                        } else {
                            Text("按\(Self.sortTitle(sort))排序")
                        }
                    }
                }
            } label: {
                HStack {
                    Text("按\(Self.sortTitle(state.sort))排序")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    KazumiPalette.cardShape(cornerRadius: 12, scheme: colorScheme)
                )
            }
        }
    }

    private static func sortTitle(_ value: String) -> String {
        switch value {
        case "heat": String(localized: "热度")
        case "rank": String(localized: "排名")
        case "score": String(localized: "评分")
        default: String(localized: "相关度")
        }
    }

    // MARK: - 四组

    private var tagsGroup: some View {
        FilterGroup(
            title: "题材标签",
            summary: state.tags.isEmpty ? String(localized: "不限题材") : state.tags.joined(separator: "、"),
            isExpanded: $tagsExpanded
        ) {
            VStack(alignment: .leading, spacing: 0) {
                KazumiFlowLayout(spacing: 8, rowSpacing: 4) {
                    // main 的固定标签 + 用户自己加的，去重后按出现顺序排。
                    ForEach(Array(tagChoices.enumerated()), id: \.offset) { _, tag in
                        chip(tag, selected: state.tags.contains(tag)) {
                            toggleTag(tag)
                        }
                    }
                }

                Spacer().frame(height: 12)

                HStack(spacing: 8) {
                    TextField("自定义标签", text: $customTag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isTagFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { addCustomTag() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            KazumiPalette.cardShape(cornerRadius: 12, scheme: colorScheme)
                        )

                    Button {
                        addCustomTag()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .background(
                                KazumiPalette.cardShape(cornerRadius: 12, scheme: colorScheme)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加标签")
                }
            }
        }
    }

    private var timeGroup: some View {
        FilterGroup(
            title: "放送时间",
            summary: timeSummary,
            isExpanded: $timeExpanded
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Menu {
                    Button {
                        state.season = ""
                        state.dateRange = nil
                    } label: {
                        if state.season.isEmpty {
                            Label("不限季度", systemImage: "checkmark")
                        } else {
                            Text("不限季度")
                        }
                    }
                    ForEach(seasonOptions, id: \.value) { option in
                        Button {
                            // 选了季度就清掉自定义日期，避免两个条件同时生效。
                            state.season = option.value
                            state.dateRange = nil
                        } label: {
                            if option.value == state.season {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(seasonDisplayName)
                            .font(.subheadline)
                            .foregroundStyle(state.season.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        KazumiPalette.cardShape(cornerRadius: 12, scheme: colorScheme)
                    )
                }

                Spacer().frame(height: 8)

                HStack(spacing: 8) {
                    Button {
                        isShowingDatePicker = true
                    } label: {
                        Label("自定义日期", systemImage: "calendar")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))

                    if !state.season.isEmpty || state.dateRange != nil {
                        Button("清除日期") {
                            state.season = ""
                            state.dateRange = nil
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Spacer().frame(height: 8)

                KazumiFlowLayout(spacing: 8, rowSpacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        chip(
                            String(localized: "周\(Self.weekdayTitles[day - 1])"),
                            selected: state.weekdays.contains(day)
                        ) {
                            if let index = state.weekdays.firstIndex(of: day) {
                                state.weekdays.remove(at: index)
                            } else {
                                state.weekdays.append(day)
                                state.weekdays.sort()
                            }
                        }
                    }
                }
            }
        }
    }

    private var scoreGroup: some View {
        FilterGroup(
            title: "评分与排名",
            summary: scoreSummary,
            isExpanded: $scoreExpanded
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Toggle("限定评分", isOn: scoreToggleBinding)
                    .font(.subheadline)
                    .padding(.vertical, 4)

                if let scoreRange = state.scoreRange, scoreRange.isValid {
                    DoubleRangeSlider(
                        low: scoreRange.min ?? 0,
                        high: scoreRange.max ?? 10,
                        bounds: 0...10,
                        step: 0.5
                    ) { low, high in
                        state.scoreRange = SearchDoubleRange(min: low, max: high)
                    }
                    .padding(.top, 8)

                    Text("评分 \(scoreText(scoreRange))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                Toggle("限定排名", isOn: rankToggleBinding)
                    .font(.subheadline)
                    .padding(.vertical, 4)
                    .padding(.top, 8)

                if let rankRange = state.rankRange, rankRange.isValid {
                    DoubleRangeSlider(
                        low: Double(rankRange.min ?? 1),
                        high: Double(rankRange.max ?? 5000),
                        bounds: 1...10000,
                        step: 100
                    ) { low, high in
                        state.rankRange = SearchIntRange(min: Int(low), max: Int(high))
                    }
                    .padding(.top, 8)

                    Text("排名 \(rankText(rankRange))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var collectGroup: some View {
        FilterGroup(
            title: "收藏状态",
            summary: collectSummary,
            isExpanded: $collectExpanded
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Toggle("隐藏看过的番剧", isOn: $notShowWatched)
                    .font(.subheadline)
                    .padding(.vertical, 4)
                Toggle("隐藏抛弃的番剧", isOn: $notShowAbandoned)
                    .font(.subheadline)
                    .padding(.vertical, 4)
            }
        }
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        // LP 3048 / Colo 3053：两颗都不占满——重置按内容宽贴左，「查看结果」固定 130
        // 贴右，中间留白（402 屏上两颗之间约 200）。
        HStack(spacing: 16) {
            Button("重置") {
                reset()
            }
            .font(.body)
            .buttonStyle(.plain)
            .foregroundStyle(KazumiPalette.accent(for: colorScheme))

            Spacer(minLength: 16)

            Button {
                onApply(
                    SearchFilterResult(
                        state: state,
                        notShowWatched: notShowWatched,
                        notShowAbandoned: notShowAbandoned
                    )
                )
                dismiss()
            } label: {
                Text("查看结果")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 130, minHeight: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(KazumiPalette.accent(for: colorScheme))
                    )
                    .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(.regularMaterial)
    }

    // MARK: - 小件

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            selected
                                ? KazumiPalette.accent(for: colorScheme)
                                : Color.secondary.opacity(0.14)
                        )
                )
                .foregroundStyle(selected ? KazumiPalette.onAccent(for: colorScheme) : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态推导

    /// 固定标签在前，用户自己加过的（含条件里带进来的）在后。
    private var tagChoices: [String] {
        var result = Self.tags
        for tag in state.tags where !result.contains(tag) {
            result.append(tag)
        }
        return result
    }

    private func toggleTag(_ tag: String) {
        if let index = state.tags.firstIndex(of: tag) {
            state.tags.remove(at: index)
        } else {
            state.tags.append(tag)
        }
        tagsExpanded = true
    }

    /// 加自定义标签：去空格、空的不加、重复的不加，加完清空并收起键盘。
    private func addCustomTag() {
        let tag = customTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !state.tags.contains(tag) else {
            customTag = ""
            return
        }
        state.tags.append(tag)
        customTag = ""
        tagsExpanded = true
        isTagFieldFocused = false
    }

    private var timeSummary: String {
        var text: String
        if !state.season.isEmpty {
            text = state.season
        } else if let range = state.dateRange {
            text = String(localized: "\(range.start) 至 \(range.end)")
        } else {
            text = String(localized: "不限日期")
        }
        if !state.weekdays.isEmpty {
            text += String(localized: " · 已选 \(String(state.weekdays.count)) 天")
        }
        return text
    }

    private var seasonDisplayName: String {
        guard !state.season.isEmpty else { return String(localized: "不限季度") }
        return seasonOptions.first { $0.value == state.season }?.label ?? state.season
    }

    private var scoreSummary: String {
        var parts: [String] = []
        if let range = state.scoreRange, range.isValid {
            parts.append(String(localized: "评分 \(scoreText(range))"))
        }
        if let range = state.rankRange, range.isValid {
            parts.append(String(localized: "排名 \(rankText(range))"))
        }
        return parts.isEmpty ? String(localized: "不限") : parts.joined(separator: " · ")
    }

    private var collectSummary: String {
        var parts: [String] = []
        if notShowWatched { parts.append(String(localized: "隐藏已看")) }
        if notShowAbandoned { parts.append(String(localized: "隐藏已弃")) }
        return parts.isEmpty ? String(localized: "显示全部") : parts.joined(separator: " · ")
    }

    /// 评分那一行的写法：7.0–10.0。格式化在 SearchFilterState 那边一份，
    /// 条件摘要用的是同一处（Camo 3036）。
    private func scoreText(_ range: SearchDoubleRange) -> String { range.displayText }

    /// 排名那一行的写法：1–5000。
    private func rankText(_ range: SearchIntRange) -> String { range.displayText }

    private var scoreToggleBinding: Binding<Bool> {
        Binding(
            get: { state.scoreRange?.isValid == true },
            set: { on in
                state.scoreRange = on ? SearchDoubleRange(min: 7, max: 10) : nil
                if on { scoreExpanded = true }
            }
        )
    }

    private var rankToggleBinding: Binding<Bool> {
        Binding(
            get: { state.rankRange?.isValid == true },
            set: { on in
                state.rankRange = on ? SearchIntRange(min: 1, max: 5000) : nil
                if on { scoreExpanded = true }
            }
        )
    }

    /// 重置：条件全清、两颗隐藏开关也关掉（对应 main 的 _reset）。
    private func reset() {
        state = SearchFilterState(keyword: state.keyword)
        notShowWatched = false
        notShowAbandoned = false
        customTag = ""
        tagsExpanded = false
        timeExpanded = false
        scoreExpanded = false
        collectExpanded = false
    }

    /// 近 20 年、当前季度之后的都不出现；键是 2026Q1，显示是「2026 冬季」。
    private var seasonOptions: [(value: String, label: String)] {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let year = calendar.component(.year, from: now)
        let seasonNames = ["冬季", "春季", "夏季", "秋季"]
        var result: [(String, String)] = []
        for offset in 0..<20 {
            let value = year - offset
            for quarter in stride(from: 4, through: 1, by: -1) {
                let month = (quarter - 1) * 3 + 1
                var components = DateComponents()
                components.year = value
                components.month = month
                components.day = 1
                guard let start = calendar.date(from: components) else { continue }
                // 当前季度还没到的不要。
                if now >= start {
                    result.append(("\(value)Q\(quarter)", "\(value) \(seasonNames[quarter - 1])"))
                }
            }
        }
        return result
    }
}

// MARK: - 可折叠分组

/// 一组：组头（标题＋条件摘要，点它折叠／展开）＋内容。
/// 对应 main 的 _SearchFilterGroup；组头不画边框，组间那条线由外面画。
private struct FilterGroup<Content: View>: View {
    let title: LocalizedStringKey
    let summary: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)

            if isExpanded {
                content()
                    .padding(.horizontal, 4)
                    .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - 双端滑动区间

/// 两个可拖的端点，对应 main 的 RangeSlider（评分 0–10 步长 0.5、排名 1–10000 步长 100）。
private struct DoubleRangeSlider: View {
    var low: Double
    var high: Double
    var bounds: ClosedRange<Double>
    var step: Double
    var onChange: (Double, Double) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragging: Knob?

    private enum Knob { case low, high }

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - knobSize, 1)
            let lowX = position(low, width: width)
            let highX = position(high, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(KazumiPalette.accent(for: colorScheme))
                    .frame(width: max(highX - lowX, 0), height: trackHeight)
                    .offset(x: lowX + knobSize / 2)

                knob(at: lowX)
                knob(at: highX)
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == nil {
                            dragging = lowX == highX
                                ? (value.location.x > value.startLocation.x ? .high : .low)
                                : nearestKnob(at: value.startLocation.x, lowX: lowX, highX: highX)
                        }
                        guard let target = dragging else { return }
                        let x = min(max(value.location.x - knobSize / 2, 0), width)
                        let raw = bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * Double(x / width)
                        let snapped = snap(raw)
                        switch target {
                        case .low:
                            onChange(min(snapped, high), high)
                        case .high:
                            onChange(low, max(snapped, low))
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: knobSize)
    }

    private func knob(at x: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: knobSize, height: knobSize)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .overlay {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            }
            .offset(x: x)
    }

    private func position(_ value: Double, width: CGFloat) -> CGFloat {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        let ratio = (value - bounds.lowerBound) / span
        return CGFloat(min(max(ratio, 0), 1)) * width
    }

    private func snap(_ value: Double) -> Double {
        let steps = ((value - bounds.lowerBound) / step).rounded()
        let snapped = bounds.lowerBound + steps * step
        return min(max(snapped, bounds.lowerBound), bounds.upperBound)
    }

    /// 起手点离哪个端点近就拖哪个，两个端点重叠时也能分开。
    private func nearestKnob(at x: CGFloat, lowX: CGFloat, highX: CGFloat) -> Knob {
        abs(x - (lowX + knobSize / 2)) <= abs(x - (highX + knobSize / 2)) ? .low : .high
    }
}

// MARK: - 自定义日期

/// 自定义日期区间：起止各一个日期选择器。
private struct DateRangePickerSheet: View {
    var initial: SearchDateRange?
    var onApply: (SearchDateRange) -> Void

    @State private var start: Date
    @State private var end: Date
    @Environment(\.dismiss) private var dismiss

    init(initial: SearchDateRange?, onApply: @escaping (SearchDateRange) -> Void) {
        self.initial = initial
        self.onApply = onApply
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let parsedStart = initial.flatMap { formatter.date(from: $0.start) }
        let parsedEnd = initial.flatMap { formatter.date(from: $0.end) }
        _start = State(initialValue: parsedStart ?? Date())
        _end = State(initialValue: parsedEnd ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $start, displayedComponents: .date)
                DatePicker("结束", selection: $end, in: start..., displayedComponents: .date)
            }
            .navigationTitle("自定义日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        onApply(
                            SearchDateRange(
                                start: formatter.string(from: start),
                                end: formatter.string(from: end)
                            )
                        )
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
