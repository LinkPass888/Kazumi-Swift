//
//  SourceSheet.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/source_sheet.dart + source_sheet_view.dart：
//  * 打开时用中文名（缺失时用原名）对所有已装规则并发检索；
//  * 每条规则一行：规则名 + 状态（检索中 / N 个结果 / 无结果 / 检索失败 / 需要验证）；
//  * 有结果时可展开全部条目，点条目回调给详情页进入播放；
//  * 失败或需要验证时提供重试；
//  * 别名在原版里不是详情页的独立区块，而是这一层的检索手段：
//    「使用别名」按钮 + 规则菜单里的「使用别名检索此来源」。
//

import SwiftUI

/// 别名选择器的载体，供 sheet(item:) 使用。
struct AliasPickerTarget: Identifiable, Hashable {
    let sourceName: String
    var id: String { sourceName }

    init(sourceName: String) {
        self.sourceName = sourceName
    }
}

struct CaptchaFlowBox: Identifiable {
    let name: String
    let flow: CaptchaFlow
    var id: String { name }
}

/// 选源面板的耗时只写日志，不上屏（Colo 2026-10-28）。
///
/// 白屏那次是拿它量的：点下去 → 面板开始画 → 列表画出来。
/// 现在留着当常态观测：真慢了能从「设置 → 日志」里翻到，界面上不显示。
@MainActor
enum SheetTiming {
    nonisolated(unsafe) static var tap: Double = 0
    nonisolated(unsafe) static var bodyFirst: Double = 0
    nonisolated(unsafe) static var listFirst: Double = 0
    nonisolated(unsafe) static var appear: Double = 0
    /// 控制器建好、开始弹面板那一刻。
    nonisolated(unsafe) static var ready: Double = 0
    static var now: Double { CFAbsoluteTimeGetCurrent() }

    /// 三段都记下来，一次写一行。
    static func logIfNeeded() {
        guard tap > 0, listFirst > 0 else { return }
        func ms(_ t: Double) -> Int { t > 0 ? Int(((t - tap) * 1000).rounded()) : -1 }
        KazumiLogBuffer.network(
            String(localized: "选源面板耗时 准备 \(String(describing: ms(ready)))ms / 开始画 \(String(describing: ms(bodyFirst)))ms / 上屏 \(String(describing: ms(appear)))ms / 列表 \(String(describing: ms(listFirst)))ms")
        )
        tap = 0
    }
}

struct SourceSheet: View {
    let controller: InfoController
    /// 点了某条结果：关面板、从详情页往右推进播放页（LP 3273 / Colo 3275）。
    /// 返回时详情页再把面板带着原来那批结果放回来。
    var onPlay: (String, SearchItem) -> Void
    /// 「去规则仓库添加」：面板自己关掉，由弹出它的那一页把人送进规则仓库，
    /// 回来再把面板重新开一次（LP 2026-10-28 / Colo 3974）。为空就只提示。
    var onOpenRuleShop: (() -> Void)? = nil
    /// 打不开外部浏览器时的一句话。
    @State private var browserFailure = false
    /// 正在选别名去检索的来源；为空表示没有打开别名选择器。
    @State private var aliasPickerTarget: AliasPickerTarget?
    @State private var captchaFlow: CaptchaFlowBox?
    /// 正在修改检索词的来源；为空表示没有弹出输入框。
    @State private var keywordTarget: String?
    @State private var keywordDraft = ""
    /// 这一轮检索是不是已经起跑了：起跑点挪到「列表真的画出来之后」，
    /// 见下面 `list` 上的 `.task`。
    @State private var searchStarted = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = recordBody()
        NavigationStack {
            Group {
                if controller.installedRules.isEmpty && controller.isSearchingSources {
                    ProgressView("正在检索所有规则…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.installedRules.isEmpty {
                    emptyRuleView
                } else {
                    list
                }
            }
            .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
            .onAppear {
                if SheetTiming.appear == 0 { SheetTiming.appear = SheetTiming.now }
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 关闭在右上，左上留空。原来右上的「重新检索」（全部刷新）已经删掉：
                // 每条来源的菜单里都有自己的「重新检索此来源」，而全量刷新在失败态
                // 下会把已经出来的结果冲掉。
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        controller.closeSourceSearch()
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $aliasPickerTarget) { target in
            aliasPicker(for: target.sourceName)
        }
        .interactiveDismissDisabled(captchaFlow != nil)
        .overlay {
            if let box = captchaFlow {
                let maxHeight: CGFloat = switch box.flow.phase {
                case .completed: 220
                case .failed, .cancelled: 240
                default: 560
                }
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            Task {
                                switch box.flow.phase {
                                case .completed: return
                                case .failed, .cancelled: break
                                default: await box.flow.cancel()
                                }
                                captchaFlow = nil
                            }
                        }
                    CaptchaSheet(flow: box.flow) { captchaFlow = nil }
                        .frame(maxWidth: 420, maxHeight: maxHeight)
                        .background(KazumiPalette.heroBackground(for: colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(radius: 24)
                        .padding(24)
                }
            }
        }
        // 修改此来源的检索词（main 的 onSourceSearch）：只重检这一个来源。
        .alert(
            "修改检索词",
            isPresented: Binding(
                get: { keywordTarget != nil },
                set: { if !$0 { keywordTarget = nil } }
            )
        ) {
            TextField("检索词", text: $keywordDraft)
            Button("取消", role: .cancel) { keywordTarget = nil }
            Button("检索") {
                guard let name = keywordTarget else { return }
                let keyword = keywordDraft
                keywordTarget = nil
                controller.sourceExpanded.insert(name)
                Task { await controller.retrySource(name, keyword: keyword) }
            }
        } message: {
            Text(keywordTarget.map { String(localized: "仅检索来源：\(String(describing: $0))") } ?? "")
        }
        .alert("无法打开浏览器，请稍后重试", isPresented: $browserFailure) {
            Button("好", role: .cancel) {}
        }
        // 半屏起步，上滑到全屏（LP 2026-10-28「开始观看没必要弹全屏窗口，半屏差不多，
        // 可以上滑顶部全屏」/ Colo 3969）。挂在面板自己身上，两个入口一起生效。
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func recordBody() {
        if SheetTiming.bodyFirst == 0 { SheetTiming.bodyFirst = SheetTiming.now }
    }

    private func recordList() {
        if SheetTiming.listFirst == 0 {
            SheetTiming.listFirst = SheetTiming.now
            SheetTiming.logIfNeeded()
        }
    }

    private var sheetTitle: String { "选择播放源" }

    // MARK: - 动作

    /// 「去规则仓库添加」：先把这一轮检索收掉，再把意图交给弹出面板的那一页。
    private func goToRuleShop() {
        controller.closeSourceSearch()
        if let onOpenRuleShop {
            onOpenRuleShop()
        } else {
            dismiss()
        }
    }

    /// 「在浏览器中打开」，网址照 main 的 _openInBrowser 取：
    /// 走接口的规则开 baseUrl，走网页的规则开 searchURL 并把 @keyword 换成这一条的检索词。
    /// 用外部浏览器，不是应用内。
    private func openInBrowser(_ group: InfoController.SourceGroup) {
        guard let plugin = controller.plugin(named: group.name) else {
            browserFailure = true
            return
        }
        let usesApi = plugin.searchMode == .api || !plugin.searchApiConfig.request.url.isEmpty
        let raw = usesApi
            ? plugin.baseUrl
            : plugin.searchURL.replacingOccurrences(
                of: "@keyword",
                with: group.keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? group.keyword
            )
        guard let url = URL(string: raw), !raw.isEmpty else {
            browserFailure = true
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { browserFailure = true }
        }
    }

    // MARK: - 列表

    private var list: some View {
        let _ = recordList()
        return ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(controller.installedRules) { plugin in
                    // 逐行算：只给看得见的那几行建 SourceGroup（见 InfoController）
                    groupCard(controller.sourceGroup(named: plugin.name))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        // 检索从这里起跑，不从面板出现就起跑（LP 2026-10-28「点开始观看白屏很久」）：
        // 第一条规则开跑时要把规则脚本现编一遍，那几秒是同步占着主线程的。
        // 起跑点放在列表上，就保证了「五行规则 + 检索中」已经画出来之后再占线程；
        // 放在面板上，第一次开面板时它抢在首帧之前，整块面板就白着等它跑完。
        .task {
            await startSearchIfNeeded()
        }
    }

    /// 起一轮检索：先让列表画出来，再起检索；第一个回来的源就地展开，
    /// 最后一批结果可能和检索结束同一帧到，补一次（用户自己收起过就不再替他展开）。
    private func startSearchIfNeeded() async {
        guard !searchStarted else { return }
        searchStarted = true
        // 让出这一帧：列表已经排好、真的上屏了，再开始占主线程。
        await Task.yield()
        let search = Task { await controller.searchAllSources() }
        let expander = Task { @MainActor in
            while !Task.isCancelled {
                if let first = controller.sourceGroups.first(where: \.hasResults) {
                    controller.sourceExpanded.insert(first.name)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await search.value
        expander.cancel()
        if controller.sourceExpanded.isEmpty,
           let first = controller.sourceGroups.first(where: \.hasResults) {
            controller.sourceExpanded.insert(first.name)
        }
    }

    private func groupCard(_ group: InfoController.SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    if controller.sourceExpanded.contains(group.name) {
                        controller.sourceExpanded.remove(group.name)
                    } else {
                        controller.sourceExpanded.insert(group.name)
                    }
                } label: {
                    HStack(spacing: 10) {
                        statusDot(group.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(group.statusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if group.hasResults {
                            Image(systemName: controller.sourceExpanded.contains(group.name) ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 原版每条规则右上角有个「更多」菜单（_buildSourceMenu）。
                sourceMenu(group)
                    .padding(.trailing, 8)
            }

            if group.hasResults, controller.sourceExpanded.contains(group.name) {
                Divider().padding(.leading, 14)
                ForEach(Array(group.results.enumerated()), id: \.offset) { index, result in
                    Button {
                        onPlay(group.name, result)
                    } label: {
                        HStack(spacing: 8) {
                            Text(result.name)
                                .font(.body)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Image(systemName: "play.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(minHeight: 64, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < group.results.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }

            if group.status == .captcha {
                Divider().padding(.leading, 14)
                Button {
                    guard let flow = controller.searchService.makeCaptchaFlow(
                        for: group.name,
                        keyword: group.keyword
                    ) else { return }
                    captchaFlow = CaptchaFlowBox(name: group.name, flow: flow)
                } label: {
                    actionRowLabel(icon: "checkmark.shield", title: String(localized: "进行验证"))
                }
                .buttonStyle(.plain)
            }

            // 一格里最多一行动作：失败只留「重试」，找不到只留「使用别名」。
            // 两个一起给过，看着就是「这一块到底该点哪个」。
            if group.status == .error {
                Divider().padding(.leading, 14)
                Button {
                    Task { await controller.retrySource(group.name) }
                } label: {
                    actionRowLabel(icon: "arrow.clockwise", title: "重试")
                }
                .buttonStyle(.plain)
            }

            // 找不到时只给「使用别名」。字用「使用别名」不用「更换别名」：
            // 这一屏是挑一个别名拿去搜，不是改别名（弹层标题就叫「别名检索」）。
            if group.status == .noResult && !controller.aliases.isEmpty {
                Divider().padding(.leading, 14)
                Button {
                    aliasPickerTarget = AliasPickerTarget(sourceName: group.name)
                } label: {
                    actionRowLabel(icon: nil, title: String(localized: "使用别名"))
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            KazumiPalette.cardShape(cornerRadius: 18, scheme: colorScheme)
        )
    }

    /// 卡片下面那一行动作按钮的样式：整行宽、上下 10、强调色。
    private func actionRowLabel(icon: String?, title: String) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        .contentShape(Rectangle())
    }

    /// 每条规则的「更多」菜单，对应原版 source_sheet_view.dart 的 _buildSourceMenu。
    ///
    /// 四项照 main。第四项「在浏览器中打开」一度没放，理由是「拿不到一个能直接
    /// 打开的网址」——那是错的：main 并不开检索请求本身，走接口的规则开 baseUrl，
    /// 走网页的规则开 searchURL 把关键词填进去，两个我们都有（LP 3260 / Colo）。
    private func sourceMenu(_ group: InfoController.SourceGroup) -> some View {
        Menu {
            Button {
                keywordDraft = group.keyword
                keywordTarget = group.name
            } label: {
                Label("修改此来源的检索词", systemImage: "text.cursor")
            }
            if !controller.aliases.isEmpty {
                Button {
                    aliasPickerTarget = AliasPickerTarget(sourceName: group.name)
                } label: {
                    Label("使用别名检索此来源", systemImage: "textformat.alt")
                }
            }
            Button {
                Task { await controller.retrySource(group.name) }
            } label: {
                Label("重新检索此来源", systemImage: "arrow.clockwise")
            }
            Button {
                openInBrowser(group)
            } label: {
                Label("在浏览器中打开", systemImage: "safari")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .hitTarget44()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(String(describing: group.name)) 的更多操作"))
    }

    /// 别名选择器，对应原版 source_alias_dialog.dart 的 _AliasPickerDialog：
    /// 标题「别名检索」，副标题「仅检索来源：xxx」，点一个别名就用它去检索这个来源。
    private func aliasPicker(for sourceName: String) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(controller.aliases, id: \.self) { alias in
                        Button {
                            // 先展开这一条，检索结果回来后就直接铺在下面。
                            controller.sourceExpanded.insert(sourceName)
                            aliasPickerTarget = nil
                            Task {
                                await controller.searchSourceWithAlias(alias, pluginName: sourceName)
                            }
                        } label: {
                            Text(alias)
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text(String(localized: "仅检索来源：\(String(describing: sourceName))"))
                }
            }
            .navigationTitle("别名检索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { aliasPickerTarget = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func statusDot(_ status: PluginSearchStatus) -> some View {
        Group {
            switch status {
            case .pending:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .noResult:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .error:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            case .captcha:
                Image(systemName: "lock.circle").foregroundStyle(KazumiPalette.accent(for: colorScheme))
            }
        }
        .frame(width: 18, height: 18)
    }

    /// 一条规则都没有：一句话加一颗按钮，把人送去规则仓库（Colo 3974）。
    ///
    /// 「先关面板再推页」的抢动画问题交给弹出它的那一页：按钮只把意图报上去，
    /// 那边等关闭动画收完再推（`.sheet(onDismiss:)`），回来时再把面板开一次。
    private var emptyRuleView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
            Text("还没有可用的播放规则")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Button {
                goToRuleShop()
            } label: {
                Text("去规则仓库添加")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(
                        Capsule().fill(KazumiPalette.accent(for: colorScheme))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

