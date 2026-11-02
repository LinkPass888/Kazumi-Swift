//
//  PluginEditorView.swift
//  Kazumi
//
//  规则编辑器（对应 lib/pages/plugin_editor/plugin_editor_page.dart）。
//
//  分三段编辑（基本信息 / 搜索规则 / 选集规则）+ 一项高级设置：
//  * XPath 与 API 两种模式各自的字段；
//  * 保存前按原实现校验：API 模式下 URL 必填、请求可渲染、JSONPath 合法、
//    表单模式请求体必须是 JSON 对象；
//  * 使用 API 模式时会把规则 api 级别提升为当前客户端的级别。
//

import SwiftUI

struct PluginEditorView: View {
    enum Section: Int, CaseIterable, Identifiable {
        case basic
        case search
        case chapter
        case advanced

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .basic: String(localized: "基本信息")
            case .search: String(localized: "搜索规则")
            case .chapter: String(localized: "选集规则")
            case .advanced: String(localized: "高级设置")
            }
        }

        var subtitle: String {
            switch self {
            case .basic: String(localized: "规则的名称、版本与站点地址")
            case .search: String(localized: "定义如何在站点内检索条目")
            case .chapter: String(localized: "定义如何获取播放线路与剧集列表")
            case .advanced: String(localized: "行为、网络与反反爬虫")
            }
        }

        var symbolName: String {
            switch self {
            case .basic: "info.circle"
            case .search: "magnifyingglass"
            case .chapter: "list.bullet.rectangle"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    @Environment(PluginsController.self) private var plugins
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let original: Plugin

    @State private var draft = PluginDraft()
    @State private var section: Section = .basic
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var testResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("编辑分区", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Label(item.title, systemImage: item.symbolName).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.title3.bold())
                    Text(section.subtitle)
                        .font(.footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                }

                switch section {
                case .basic:
                    basicSection
                case .search:
                    searchSection
                case .chapter:
                    chapterSection
                case .advanced:
                    advancedSection
                }

                if let testResult {
                    Label(testResult, systemImage: "checkmark.seal")
                        .font(.footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                }
            }
            .padding(20)
        }
        // 顶部滚动边缘：渐进模糊（.soft），不另外加材质或底色。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle(original.name.isEmpty ? "新建规则" : original.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await save() }
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isSaving)
                    Button {
                        if let plugin = try? draft.build(apiLevel: KazumiAppInfo.ruleAPILevel), !plugin.name.isEmpty {
                            UIPasteboard.general.string = PluginImportExport.ruleLink(for: plugin)
                            testResult = "已复制 kazumi:// 链接"
                        } else {
                            errorMessage = String(localized: "请先完善规则名称与必填字段")
                        }
                    } label: {
                        Label("复制分享链接", systemImage: "link")
                    }
                    .disabled(original.name.isEmpty)
                    if !original.name.isEmpty {
                        Divider()
                        // 原版编辑器底部的「测试规则」：先保存再跳测试页，
                        // 否则测的是改动前那份规则。
                        Button {
                            Task { await saveAndTest() }
                        } label: {
                            Label("保存并测试规则", systemImage: "testtube.2")
                        }
                        .disabled(isSaving)
                    }
                } label: {
                    if isSaving { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .alert("无法保存", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            draft = PluginDraft(plugin: original)
        }
    }
    // MARK: - 基本信息

    @ViewBuilder
    private var basicSection: some View {
        EditorCard {
            EditorTextField(title: String(localized: "规则名称"), text: $draft.name, prompt: String(localized: "例如 示例站点"))
            EditorTextField(title: String(localized: "版本"), text: $draft.version, prompt: String(localized: "例如 1.0.0"))
            EditorTextField(title: String(localized: "站点地址 (baseURL)"), text: $draft.baseUrl, prompt: "https://example.com", keyboard: .URL)
            EditorTextField(title: String(localized: "搜索地址"), text: $draft.searchURL, prompt: "https://example.com/search?q=@keyword", keyboard: .URL)
            EditorTextField(title: String(localized: "类型"), text: $draft.type, prompt: "anime")
            Toggle("多源模式", isOn: $draft.muliSources)
            Toggle("使用 WebView", isOn: $draft.useWebview)
            Toggle("使用内建播放器", isOn: $draft.useNativePlayer)
        }
    }

    // MARK: - 搜索规则

    @ViewBuilder
    private var searchSection: some View {
        EditorCard {
            Picker("搜索模式", selection: $draft.searchMode) {
                Text("XPath").tag(RuleMode.xpath)
                Text("API").tag(RuleMode.api)
            }
            .pickerStyle(.segmented)

            if draft.searchMode == .xpath {
                Toggle("使用 POST 搜索", isOn: $draft.usePost)
                EditorTextField(title: String(localized: "搜索结果列表"), text: $draft.searchList, prompt: "//div[@class='item']", monospaced: true)
                EditorTextField(title: String(localized: "条目名称"), text: $draft.searchName, prompt: ".//h3/text()", monospaced: true)
                EditorTextField(title: String(localized: "条目链接"), text: $draft.searchResult, prompt: ".//a", monospaced: true)
            } else {
                EditorTextField(title: String(localized: "请求方法"), text: $draft.searchMethod, prompt: "GET")
                EditorTextField(title: String(localized: "请求地址"), text: $draft.searchURL, prompt: "https://api.example.com/search?q=@keyword", keyboard: .URL)
                EditorTextField(title: String(localized: "请求头 (JSON)"), text: $draft.searchHeaders, multiline: true, monospaced: true)
                EditorTextField(title: String(localized: "查询参数 (JSON)"), text: $draft.searchQuery, multiline: true, monospaced: true)
                Picker("请求体类型", selection: $draft.searchBodyType) {
                    Text("无").tag(ApiBodyType.none)
                    Text("JSON").tag(ApiBodyType.json)
                    Text("表单").tag(ApiBodyType.form)
                }
                if draft.searchBodyType != .none {
                    EditorTextField(title: String(localized: "请求体"), text: $draft.searchBody, multiline: true, monospaced: true)
                }
                EditorTextField(title: String(localized: "结果列表路径"), text: $draft.searchListPath, prompt: "$.data[*]", monospaced: true)
                EditorTextField(title: String(localized: "名称路径"), text: $draft.searchNamePath, prompt: "$.name", monospaced: true)
                EditorTextField(title: String(localized: "来源路径"), text: $draft.searchSourcePath, prompt: "$.url", monospaced: true)
                EditorTextField(title: String(localized: "详情页模板"), text: $draft.searchSourceTemplate, prompt: "https://example.com/detail/@source", monospaced: true)
            }
        }
    }

    // MARK: - 选集规则

    @ViewBuilder
    private var chapterSection: some View {
        EditorCard {
            Picker("选集模式", selection: $draft.chapterMode) {
                Text("XPath").tag(RuleMode.xpath)
                Text("API").tag(RuleMode.api)
            }
            .pickerStyle(.segmented)

            if draft.chapterMode == .xpath {
                EditorTextField(title: String(localized: "播放线路列表"), text: $draft.chapterRoads, prompt: "//div[@class='play-list']", monospaced: true)
                EditorTextField(title: String(localized: "剧集列表"), text: $draft.chapterResult, prompt: ".//a", monospaced: true)
            } else {
                EditorTextField(title: String(localized: "请求方法"), text: $draft.chapterMethod, prompt: "GET")
                EditorTextField(title: String(localized: "请求地址"), text: $draft.chapterURL, prompt: "https://api.example.com/detail?id=@source", keyboard: .URL)
                EditorTextField(title: String(localized: "请求头 (JSON)"), text: $draft.chapterHeaders, multiline: true, monospaced: true)
                EditorTextField(title: String(localized: "查询参数 (JSON)"), text: $draft.chapterQuery, multiline: true, monospaced: true)
                Picker("请求体类型", selection: $draft.chapterBodyType) {
                    Text("无").tag(ApiBodyType.none)
                    Text("JSON").tag(ApiBodyType.json)
                    Text("表单").tag(ApiBodyType.form)
                }
                if draft.chapterBodyType != .none {
                    EditorTextField(title: String(localized: "请求体"), text: $draft.chapterBody, multiline: true, monospaced: true)
                }
                Picker("响应格式", selection: $draft.chapterFormat) {
                    Text("嵌套").tag(ApiChapterFormat.nested)
                    Text("分隔符").tag(ApiChapterFormat.delimited)
                }
                if draft.chapterFormat == .nested {
                    EditorTextField(title: String(localized: "线路列表路径"), text: $draft.chapterRoadsPath, prompt: "$.data.roads[*]", monospaced: true)
                    EditorTextField(title: String(localized: "线路名称路径"), text: $draft.chapterRoadNamePath, prompt: "$.name", monospaced: true)
                    EditorTextField(title: String(localized: "剧集列表路径"), text: $draft.chapterEpisodesPath, prompt: "$.episodes[*]", monospaced: true)
                    EditorTextField(title: String(localized: "剧集名称路径"), text: $draft.chapterEpisodeNamePath, prompt: "$.name", monospaced: true)
                    EditorTextField(title: String(localized: "剧集地址路径"), text: $draft.chapterEpisodeURLPath, prompt: "$.url", monospaced: true)
                } else {
                    EditorTextField(title: String(localized: "线路名称路径"), text: $draft.chapterRoadNamesPath, monospaced: true)
                    EditorTextField(title: String(localized: "剧集字符串路径"), text: $draft.chapterRoadEpisodesPath, monospaced: true)
                    EditorTextField(title: String(localized: "线路分隔符"), text: $draft.chapterRoadSeparator)
                    EditorTextField(title: String(localized: "剧集分隔符"), text: $draft.chapterEpisodeSeparator)
                    EditorTextField(title: String(localized: "字段分隔符"), text: $draft.chapterFieldSeparator)
                }
                EditorTextField(title: String(localized: "选集响应变量 (JSON)"), text: $draft.chapterVariables, multiline: true, monospaced: true)
                EditorTextField(title: String(localized: "播放页地址模板"), text: $draft.chapterPageURL, prompt: "https://example.com/play/@episodeUrl")
                EditorTextField(title: String(localized: "播放页查询参数 (JSON)"), text: $draft.chapterPageQuery, multiline: true, monospaced: true)
            }
        }
    }
    // MARK: - 高级设置

    @ViewBuilder
    private var advancedSection: some View {
        EditorCard {
            Text("行为设置").font(.subheadline.weight(.semibold))
            Toggle("旧版解析器", isOn: $draft.useLegacyParser)
            Toggle(isOn: $draft.adBlocker) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("广告过滤")
                    Text("启用 HLS 广告过滤")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        EditorCard {
            Text("网络设置").font(.subheadline.weight(.semibold))
            EditorTextField(title: "User-Agent", text: $draft.userAgent, multiline: true)
            EditorTextField(title: "Referer", text: $draft.referer, keyboard: .URL)
        }
        EditorCard {
            Text("反反爬虫").font(.subheadline.weight(.semibold))
            Toggle("启用验证页处理", isOn: $draft.antiCrawlerEnabled)
            if draft.antiCrawlerEnabled {
                Picker("验证类型", selection: $draft.captchaType) {
                    Text("图片验证码").tag(CaptchaType.imageCaptcha)
                    Text("自动点击按钮").tag(CaptchaType.autoClickButton)
                    Text("自定义脚本").tag(CaptchaType.customJavaScript)
                }
                if draft.captchaType == .imageCaptcha {
                    EditorTextField(title: String(localized: "验证码图片"), text: $draft.captchaImage, monospaced: true)
                    EditorTextField(title: String(localized: "验证码输入框"), text: $draft.captchaInput, monospaced: true)
                }
                if draft.captchaType != .customJavaScript {
                    EditorTextField(title: String(localized: "验证按钮"), text: $draft.captchaButton, monospaced: true)
                }
                if draft.captchaType == .customJavaScript {
                    EditorTextField(title: String(localized: "验证脚本"), text: $draft.captchaScript, multiline: true, monospaced: true)
                }
                Picker("验证页检测方式", selection: $draft.captchaDetectType) {
                    Text("XPath").tag(CaptchaDetectType.xpath)
                    Text("文本").tag(CaptchaDetectType.text)
                    Text("正则").tag(CaptchaDetectType.regex)
                }
                EditorTextField(title: String(localized: "检测值"), text: $draft.captchaDetectValue, monospaced: true)
            }
        }
    }

    // MARK: - 保存

    private func save() async {
        do {
            let plugin = try draft.build(apiLevel: KazumiAppInfo.ruleAPILevel)
            guard !plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError.emptyName
            }
            if plugin.requiresNewerClient {
                throw EditorError.requiresNewerClient
            }
            isSaving = true
            defer { isSaving = false }
            try await plugins.updatePlugin(plugin)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 保存当前改动，然后跳到规则测试页。
    ///
    /// 原版在编辑器里点「测试规则」也是先落到已保存的规则上（测试页按名字取规则），
    /// 这里同理：先保存再推入，测试的就是刚改完的这份。
    private func saveAndTest() async {
        do {
            let plugin = try draft.build(apiLevel: KazumiAppInfo.ruleAPILevel)
            guard !plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError.emptyName
            }
            if plugin.requiresNewerClient {
                throw EditorError.requiresNewerClient
            }
            isSaving = true
            defer { isSaving = false }
            try await plugins.updatePlugin(plugin)
            router.push(.pluginTest(ruleID: plugin.name))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

enum EditorError: Error, LocalizedError, Sendable {
    case emptyName
    case requiresNewerClient
    case headersNotObject(String)
    case bodyNotJSON(String, String)
    case bodyNotObject(String)
    case emptyRequestURL(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "规则名称不能为空")
        case .requiresNewerClient: String(localized: "规则需要更高版本客户端")
        case .headersNotObject(let label): String(localized: "\(label) 必须是 JSON 对象")
        case .bodyNotJSON(let label, let message): String(localized: "\(label) 不是有效 JSON：\(message)")
        case .bodyNotObject(let label): String(localized: "\(label) 在表单模式下必须是 JSON 对象")
        case .emptyRequestURL(let label): String(localized: "\(label) 不能为空")
        }
    }
}
