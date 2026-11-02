//
//  PluginTestScreen.swift
//  Kazumi
//
//  规则测试，1:1 对应 lib/pages/plugin_editor/plugin_test_page.dart：
//   1. 搜索请求 —— 原始响应（API 规则格式化成 JSON）；
//   2. 结果解析 —— 解析出的条目，点开可看命中的片段；
//   3. 播放线路 —— 用第一条搜索结果的地址去取线路与剧集。
//
//  与原版一致，用第一条搜索结果做选集测试；任何一步失败都停下来，
//  把错误原文原样展示（规则出错时这句话就是唯一的线索）。
//

import SwiftUI

struct PluginTestScreen: View {
    let ruleID: String

    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme

    @State private var keyword = ""
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = 0
    @State private var errorMessage: String?

    @State private var searchRaw = ""
    @State private var searchResponse: PluginSearchResponse?
    @State private var searchDiagnostics: [String] = []
    @State private var matchedFragments: [String] = []

    @State private var chapterRaw = ""
    @State private var chapters: [Road] = []
    @State private var chapterDiagnostics: [String] = []

    /// 展开状态：三段各自独立，与原版的 ExpansionTile 一致。
    @State private var expanded: Set<String> = ["parse"]

    /// 引擎是值类型、只持有 Sendable 依赖，页面可以直接持有。
    private let engine = RuleEngine()

    private var plugin: Plugin? {
        // 与控制器的查找规则保持一致（规则名忽略大小写）。
        plugins.plugin(named: ruleID)
    }

    private var hasSearchData: Bool {
        !(searchResponse?.data.isEmpty ?? true)
    }

    /// 需要选集测试的条件与原版一致：API 选集模式，或填了线路 XPath。
    private var needsChapterParse: Bool {
        guard let plugin else { return false }
        return plugin.chapterMode == .api || !plugin.chapterRoads.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro

                if plugin == nil {
                    ContentUnavailableView(
                        "规则已不存在",
                        systemImage: "questionmark.folder",
                        description: Text("这条规则可能刚被删除，返回列表刷新一下。")
                    )
                } else {
                    keywordCard
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    searchRequestCard
                    parseCard
                    chapterCard
                }
            }
            .padding(20)
        }
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("重置测试")
            }
        }
    }

    // MARK: - 顶部

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "testtube.2")
                    .font(.title3)
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                Text(plugin?.name ?? "规则测试")
                    .font(.title3.bold())
            }
            Text("一次测试，检查搜索请求、结果解析和播放线路。")
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
        }
    }

    // MARK: - 关键词

    private var keywordCard: some View {
        EditorCard {
            Text("试着搜索一部番剧")
                .font(.subheadline.weight(.semibold))
            Text("选集测试会使用第一条搜索结果。")
                .font(.caption)
                .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
            EditorTextField(title: String(localized: "测试关键词"), text: $keyword, prompt: String(localized: "例如 孤独摇滚"))
            HStack {
                Spacer()
                Button {
                    if isTesting {
                        reset()
                    } else {
                        startTest()
                    }
                } label: {
                    Label(isTesting ? "停止测试" : "开始测试",
                          systemImage: isTesting ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(KazumiPalette.accent(for: colorScheme))
            }
            if isTesting {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("测试没有走通", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kazumiGlassCard(cornerRadius: 16)
    }

    // MARK: - 三段结果

    private var searchRequestCard: some View {
        stepCard(
            id: "search",
            number: 1,
            title: String(localized: "搜索请求"),
            subtitle: searchRequestSubtitle,
            done: !searchRaw.isEmpty
        ) {
            rawPanel(searchRaw, isJSON: plugin?.searchMode == .api)
            diagnostics(searchDiagnostics)
        }
    }

    private var parseCard: some View {
        stepCard(
            id: "parse",
            number: 2,
            title: String(localized: "结果解析"),
            subtitle: hasSearchData
                ? String(localized: "解析出 \(searchResponse?.data.count ?? 0) 个条目")
                : String(localized: "还没有可展示的解析结果"),
            done: hasSearchData
        ) {
            if hasSearchData, let items = searchResponse?.data {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index + 1). \(item.name)")
                                .font(.footnote.weight(.semibold))
                            Text(item.src)
                                .font(.caption2)
                                .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                                .textSelection(.enabled)
                            // 原版把命中片段挂在条目下面，方便对照选择器。
                            if matchedFragments.indices.contains(index) {
                                Text(matchedFragments[index])
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            diagnostics(searchDiagnostics)
        }
    }

    private var chapterCard: some View {
        stepCard(
            id: "chapter",
            number: 3,
            title: String(localized: "播放线路"),
            subtitle: chapterSubtitle,
            done: !chapters.isEmpty
        ) {
            if !needsChapterParse {
                Text("未填写选集规则")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
            } else if !chapters.isEmpty {
                rawPanel(chapterRaw, isJSON: plugin?.chapterMode == .api)
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, road in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "播放线路 \(index + 1)：\(road.name)"))
                            .font(.footnote.weight(.semibold))
                        Text(String(localized: "剧集数量：\(road.data.count)"))
                            .font(.caption2)
                            .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                        ForEach(Array(road.identifier.enumerated()), id: \.offset) { itemIndex, name in
                            Text("\(itemIndex + 1). \(name)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                            if road.data.indices.contains(itemIndex) {
                                Text(road.data[itemIndex])
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                                    .lineLimit(2)
                            }
                        }
                        .padding(.leading, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            diagnostics(chapterDiagnostics)
        }
    }

    private var searchRequestSubtitle: String {
        if isTesting && searchRaw.isEmpty { return String(localized: "正在请求…") }
        if searchRaw.isEmpty { return String(localized: "还没有发出请求") }
        return String(localized: "已收到响应（\(searchRaw.count) 个字符）")
    }

    private var chapterSubtitle: String {
        if !needsChapterParse { return "未填写选集规则" }
        if isTesting && chapters.isEmpty { return String(localized: "正在获取…") }
        if chapters.isEmpty { return String(localized: "还没有取到线路") }
        let skipped = chapterDiagnostics.isEmpty ? "" : String(localized: "，跳过 \(chapterDiagnostics.count) 条")
        return String(localized: "获取到 \(chapters.count) 个播放线路\(skipped)")
    }

    // MARK: - 卡片骨架

    @ViewBuilder
    private func stepCard<Content: View>(
        id: String,
        number: Int,
        title: String,
        subtitle: String,
        done: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // 展开状态直接由 expanded 决定；初始只展开「结果解析」，
        // 与原版 ExpansionTile 的默认展开态一致。
        let isOpen = expanded.contains(id)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded.contains(id) {
                    expanded.remove(id)
                } else {
                    expanded.insert(id)
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(done
                                  ? KazumiPalette.accent(for: colorScheme).opacity(0.18)
                                  : Color.secondary.opacity(0.12))
                            .frame(width: 26, height: 26)
                        if done {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        } else {
                            Text("\(number)")
                                .font(.caption.bold())
                                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kazumiGlassCard(cornerRadius: 18)
    }

    @ViewBuilder
    private func rawPanel(_ raw: String, isJSON: Bool) -> some View {
        if !raw.isEmpty {
            ScrollView(.vertical) {
                Text(isJSON ? Self.prettyJSON(raw) : raw)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(10)
            .background(
                .quaternary.opacity(0.3),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private func diagnostics(_ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "跳过的节点（\(items.count)）"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                }
            }
        }
    }

    // MARK: - 测试流程

    private func reset() {
        testTask?.cancel()
        testTask = nil
        testGeneration &+= 1
        isTesting = false
        errorMessage = nil
        searchRaw = ""
        searchResponse = nil
        searchDiagnostics = []
        matchedFragments = []
        chapterRaw = ""
        chapters = []
        chapterDiagnostics = []
        expanded = ["parse"]
    }

    private func startTest() {
        guard let plugin else { return }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "请输入一个番剧名称作为测试关键词。")
            return
        }
        reset()
        let generation = testGeneration
        isTesting = true
        testTask = Task { @MainActor in
            defer { if generation == testGeneration { isTesting = false } }

            // 与原版一致：搜索成功后再用第一条结果去取线路；中途失败就停在这里，
            // 已经拿到的部分结果留在界面上。
            let config = RuleExecutionConfig(plugin: plugin)
            do {
                let trace = try await engine.search(config, keyword: trimmed)
                guard generation == testGeneration else { return }
                searchRaw = trace.rawResponse
                searchResponse = trace.response
                searchDiagnostics = trace.diagnostics
                matchedFragments = trace.matchedFragments

                guard needsChapterParse, let first = trace.response.data.first,
                      !first.src.isEmpty else { return }
                let chapterTrace = try await engine.queryChapters(config, source: first.src)
                guard generation == testGeneration else { return }
                chapterRaw = chapterTrace.rawResponse
                chapters = chapterTrace.roads
                chapterDiagnostics = chapterTrace.diagnostics
            } catch {
                guard generation == testGeneration else { return }
                errorMessage = error.localizedDescription
                KazumiLog.plugin.warning(
                    "PluginTest: \(plugin.name, privacy: .public) 测试中断：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// 与 Dart 的 `JsonEncoder.withIndent('  ')` 一致；不是 JSON 时原样返回。
    private static func prettyJSON(_ raw: String) -> String {
        guard let value = try? JSONValue.decode(raw) else { return raw }
        return value.serialized(pretty: true)
    }
}
