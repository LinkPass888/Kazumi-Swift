//
//  SyncBackupScreen.swift
//  Kazumi
//
//  设置 → 账号与备份（主页）。
//
//  这一层只做两件事：
//    * 两路同步各一行，点进去才是配置页；主页只陈述当前状态，不在这里改配置；
//    * 设置备份直接在本页摊开（LP 690：不再开二级页），因为它不经过服务器，
//      和上面两路同步不是同一件事。
//
//  副标题不是装饰：只写服务名时，用户看不出这一行到底管什么，所以两行都带。
//  状态只从真实配置算，不写死；「连接异常」需要持久化上次检查结果（现在没有），
//  所以 Bangumi 账号这一行只有「未填写令牌 / 已保存令牌」两态。
//
//  ── 名字对照表（改一处必须同时看这张表）─────────────────────────────────────
//  这五处名字和它们下面三处说明是同一个事实的五个说法，翻一个就得翻全部：
//    1. 本页标题、本页在「我的」和「设置」列表里的行           现在：同步设置
//       LP 清单第八项就叫「同步设置」，Ato 2026-10-24 定：只改名，内容不动。
//       下面那组三件的条件针对的是「同步备份」与「多设备同步」这两个说法，
//       不是这一处——入口名随清单，行内还叫备份。
//    2. WebDAV 那一行的标题                                  现在：WebDAV 备份
//       1 与 2 改回「同步备份」「多设备同步」的条件是同一组三件齐：
//       WebDAV 按类型分件落地 + 全局总闸 + 自动推送。缺一件就不改，名字先停在备份。
//    3. WebDAV 页里的分组标题                                现在：服务器
//       这一处本来就是原版叫法，不跟着改回。
//    4. Bangumi 这一行与那一页的标题                          现在：Bangumi 账号
//    5. 追番页右上角那颗玻璃药丸                                现在：备份
//       4 与 5 必须同一版翻成「追番同步」「同步」，条件是「立即同步追番」真能跑。
//       只翻一个会出现「页名叫账号、里面却有同步按钮」那种错位。
//  随之要一起重写的三处说明（都在别处的文件里，不在这张页）：
//    * 本页第一行副标题（Bangumi 那一行小字）
//    * 「设置」列表里本页那行的说明
//    * 「我的」页里本页那行的副标题
//  它们现在都只提令牌和备份，页一改名就变成「站在门口读不到门里有什么」。
//  ─────────────────────────────────────────────────────────────────────
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SyncBackupScreen: View {
    /// 设置备份的两段动作：剪贴板、文件。结果横幅按它就近出现。
    private enum BackupScope {
        case clipboard
        case file
    }

    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme

    @State private var backupMessage: String?
    /// 结果那行是不是失败：失败用系统橙，成功用应用色。
    @State private var backupMessageIsError = false
    /// 结果是哪一段动作出来的：横幅就贴在那一段动作下面（LP 5072）。
    @State private var backupMessageScope: BackupScope?
    /// 横幅自己收掉的定时器。连点几次时只管最后一次。
    @State private var backupMessageDismissTask: Task<Void, Never>?
    @State private var pendingPayload: SettingsBackup.Payload?
    @State private var isShowingRestoreConfirm = false
    /// 导出/导入文件用的状态。面板本身由 DocumentPickerBridge 呈现，
    /// 这里只管回来的结果。
    @State private var isPickingBackupFile = false

    var body: some View {
        Form {
            Section {
                Group {
                    NavigationLink {
                        BangumiSyncScreen()
                    } label: {
                        serviceRow(
                            title: "追番同步",
                            subtitle: String(localized: "与 Bangumi 保持相同的追番状态"),
                            status: bangumiStatusText
                        )
                    }

                    // 标题与说明照原版那张卡（webdav_sync_page.dart:92-105）：
                    // 「多设备同步」/「通过自己的云盘，在其他设备接着看。」
                    // 状态按总闸与内容开关分四档，跟原版一致。
                    NavigationLink {
                        WebDAVScreen()
                    } label: {
                        serviceRow(
                            title: "多设备同步",
                            subtitle: String(localized: "通过自己的云盘，在其他设备接着看"),
                            status: webDAVStatusText
                        )
                    }
                }
                // Colo 3532：Form 行底色显式取 groupedRow，不依赖系统动态色。
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }

            Section {
                Group {
                    Toggle("不含账号与密码", isOn: backupOmitCredentialsBinding)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("设置备份")
            } footer: {
                // 开关那句会变字数，放段里会把下面的行推上推下；挪进脚注就稳了。
                VStack(alignment: .leading, spacing: 4) {
                    Text(omitExplanation)
                    // 只说备份了什么：不写「云端也有一份」，否则会以为收藏也备了。
                    Text("备份包含应用设置、已安装的规则和添加的规则仓库。追番、观看历史、下载与播放器日志不在备份里。")
                }
            }

            // LP 定：按介质分组——剪贴板一段、文件一段，段与段的间隔自己分开。
            // 行名只写动作，段标题已经说了是哪条路；读屏报全名。
            Section {
                Group {
                    actionRow(String(localized: "导出到剪贴板"), icon: "arrow.up.doc", accessibility: String(localized: "导出到剪贴板")) { exportBackup() }
                    actionRow(String(localized: "从剪贴板恢复"), icon: "square.and.arrow.down", accessibility: String(localized: "从剪贴板恢复")) {
                        importBackupFromClipboard()
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("剪贴板")
            }

            Section {
                Group {
                    actionRow(String(localized: "导出到文件"), icon: "folder", accessibility: String(localized: "导出到文件")) { exportBackupToFile() }
                    actionRow(String(localized: "从文件恢复"), icon: "doc.badge.plus", accessibility: String(localized: "从文件恢复")) {
                        pickBackupFile()
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("文件")
            }
        }
        // 这一页今天确实只做账号、WebDAV 备份与设置备份，没有任何自动同步，
        // 所以叫「账号与备份」而不是「同步备份」。只有等分件版同步、
        // 「启用 WebDAV」总闸与自动推送三件事都落地后，才改回「同步备份」。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("同步设置")
        .navigationBarTitleDisplayMode(.large)
        // 导出/恢复的结果不占表单位置（LP 5135/5137/5151）：它浮在页面上层，
        // 既不进 Form 的行，也不把下面的内容推上推下，自己几秒后收走。
        .overlay(alignment: .bottom) {
            if let backupMessage {
                backupBanner(backupMessage, isError: backupMessageIsError)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .scrollContentBackground(.hidden)
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        // 恢复确认用居中的对话框，跟原版 AlertDialog 一样落在屏幕正中
        //（LP 2517：之前用 confirmationDialog，iOS 26 会从表单某个位置弹出，位置不对）。
        .alert("恢复这些设置？", isPresented: $isShowingRestoreConfirm) {
            Button("恢复设置") { applyPendingBackup() }
            Button("取消", role: .cancel) { pendingPayload = nil }
        } message: {
            Text(restoreConfirmMessage)
        }
    }

    // MARK: - 文件面板（导出、导入共用一条）

    // MARK: - 服务行

    /// 一行服务：标题 + 副标题 +（可选）右侧状态。
    /// 箭头由 NavigationLink 自己给，再画一个会变成两个 chevron。
    private func serviceRow(title: String, subtitle: String, status: String? = nil) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let status {
                // 状态只陈述事实，不点也不变色；整行才是点击目标。
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .hitTarget44(alignment: .leading)
    }

    /// 与 Bangumi 账号页同一口径：令牌为空就是未填写，否则已保存。
    /// 状态口径照 sync_settings_page.dart 那张卡：没令牌是「未连接」，
    /// 有令牌看自动同步开没开，验证失败时是「连接异常」。
    private var bangumiStatusText: String {
        let engine = environment.bangumiSync
        if engine.isConnecting { return String(localized: "正在连接") }
        if engine.lastError != nil { return String(localized: "连接异常") }
        if settings.bangumiAccessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty { return String(localized: "未连接") }
        return settings.bangumiSyncEnable ? String(localized: "已开启") : "已关闭"
    }

    /// 与 Bangumi 账号行同一口径：去掉首尾空白后为空就是未配置。
    /// 「已开启 / 已关闭」「未选择内容」依赖总闸与内容开关，
    /// 这一轮 WebDAV 备份页还没有它们，等分件版落地再补。
    private var webDAVStatusText: String {
        guard !settings.webDAVURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else { return String(localized: "未配置") }
        guard settings.webDavEnable else { return "已关闭" }
        guard !WebDAVSync.enabledContents(settings).isEmpty else { return String(localized: "未选择内容") }
        return String(localized: "已开启")
    }

    private var omitExplanation: String {
        settings.settingsBackupOmitCredentials
            ? String(localized: "跳过追番同步、WebDAV、代理和自定义弹幕接口的账号密钥，其余设置照常恢复")
            : String(localized: "把同步账号、WebDAV、代理与自定义弹幕接口密钥一起导出，请只存放在自己可信的地方")
    }

    private var backupOmitCredentialsBinding: Binding<Bool> {
        Binding(
            get: { settings.settingsBackupOmitCredentials },
            set: { settings.settingsBackupOmitCredentials = $0 }
        )
    }

    // MARK: - 设置备份

    /// 一行动作：左边动作名（正常字色），行尾一颗次要色小图标。
    /// 整行可点，图标不单独被读屏念出来。
    private func actionRow(
        _ title: String,
        icon: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        // 四行按同步那两页的 52 点行高走：Form 默认上下留白会把 44 撑到 74，
        // 压回 4/4 正好合上那两页的单行高。
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    /// 一次导入/导出的结果条（LP 5072 / 5135 / 5151）。
    ///
    /// 以前落在段末脚注：小字、灰色、离刚才点的那一行隔一段，真的容易划过去。
    /// 现在它是浮在页面上层的一条提示（不参与排版，不挤任何一行）：
    /// 实底卡片加阴影，压在内容上也不会跟下面的字绞在一起，几秒后自己收掉。
    private func backupBanner(_ text: String, isError: Bool) -> some View {
        let tint = isError ? Color.orange : KazumiPalette.accent(for: colorScheme)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KazumiPalette.groupedRow(for: colorScheme))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.14), radius: 12, y: 4)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// 结果统一从这里落：成功清掉橙字，失败才染成橙。
    private func setBackupResult(_ text: String, isError: Bool) {
        // 结果行一律不带句号（Camo）：解码器给的失败句末尾那个也去掉。
        let cleaned = text.hasSuffix("。") ? String(text.dropLast()) : text
        // 连点几次就只管最后一次：旧的定时器先拆掉，不然先来的会把后来的提前收走。
        backupMessageDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            backupMessage = cleaned.isEmpty ? nil : cleaned
            backupMessageIsError = isError
        }
        guard !cleaned.isEmpty else { return }
        backupMessageDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { backupMessage = nil }
        }
    }

    /// 备份正文：设置 + 已安装的规则（整份定义）+ 添加的规则仓库。
    /// 返回 nil 表示一条设置都没有，与原来的空备份判定一致。
    private func backupText() -> String? {
        let snapshot = settings.backupSnapshot(omitCredentials: settings.settingsBackupOmitCredentials)
        guard !snapshot.isEmpty else { return nil }
        return SettingsBackup.encode(
            snapshot,
            rules: environment.plugins.pluginList.map { $0.toJSON() },
            ruleSources: RulesRepositoryStore.backupJSON()
        )
    }

    private func exportBackup() {
        backupMessageScope = .clipboard
        guard let text = backupText() else {
            setBackupResult(String(localized: "没有可导出的设置"), isError: true)
            return
        }
        UIPasteboard.general.string = text
        // 提示是一闪而过的浮条：只说结果，不塞建议。长句子会把条子撑成两行、盖住下面的行。
        setBackupResult(String(localized: "已复制到剪贴板"), isError: false)
    }

    private func importBackupFromClipboard() {
        backupMessageScope = .clipboard
        setBackupResult("", isError: false)
        // 直接读 `.string`：真机上这一步会由系统弹出粘贴授权，允许之后这次读取
        // 就拿到内容。以前这里借 `detectValues` 走同一套授权，但那个调用本身
        // 会把 App 打死——模拟器上点一次就原地回主屏，连空回调、不改任何状态
        // 都死（探针己验过），所以不再碰它。
        //
        // 下面三行日志是为了“点一下就退”这类崩溃：它们走 os.Logger，进系统
        // 日志，App 死了也还在。屏上的日志页是内存里的，崩了就没了。
        KazumiLogBuffer.network("剪贴板恢复：已按下，准备读剪贴板")
        guard let raw = UIPasteboard.general.string else {
            KazumiLogBuffer.network("剪贴板恢复：读到空（无内容或未授权）")
            setBackupResult(Self.clipboardEmptyMessage, isError: true)
            return
        }
        KazumiLogBuffer.network("剪贴板恢复：读到 \(raw.count) 字")
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setBackupResult(Self.clipboardEmptyMessage, isError: true)
            return
        }
        acceptClipboardBackup(text)
    }

    /// 剪贴板和文件两条路共用同一套解码说法（Camo 的规则：同一样东西用同一个词）。
    /// 失败的措辞一律来自 SettingsBackup.BackupError，不在这里另造。
    private func acceptClipboardBackup(_ raw: String) {
        do {
            let payload = try SettingsBackup.decode(raw)
            guard payload.count > 0 else {
                setBackupResult(Self.emptyBackupMessage, isError: true)
                return
            }
            pendingPayload = payload
            // 文件面板刚关掉时立刻挂弹窗，SwiftUI 会把弹窗吞掉（选完文件像什么都没发生）。
            // 等面板真正退干净的下一拍再挂，两条路共用这个口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard pendingPayload != nil else { return }
                isShowingRestoreConfirm = true
            }
        } catch {
            setBackupResult(error.localizedDescription, isError: true)
        }
    }

    private static let clipboardEmptyMessage = String(localized: "剪贴板里没有设置备份。先复制一段备份文本，或者改用从文件恢复。")
    private static let emptyBackupMessage = String(localized: "备份里没有设置内容")

    private func applyPendingBackup() {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        let count = settings.applyBackup(payload.settings)
        // 规则按整份定义还原：同名覆盖、没有的新增（走导入规则同一个入口，
        // 于是落盘、内存列表、排序三件事都由它负责）。
        let rules = payload.rules
            .map { Plugin(json: $0) }
            .filter { !$0.name.isEmpty && !$0.requiresNewerClient }
        let sources = payload.ruleSources
        Task { @MainActor in
            var restoredRules = 0
            var ruleFailure: String?
            if !rules.isEmpty {
                do {
                    try await environment.plugins.updatePlugins(rules)
                    restoredRules = rules.count
                } catch {
                    ruleFailure = error.localizedDescription
                }
            }
            // 仓库恢复是合并：本机已有的按地址跳过，不删任何一条。
            let addedSources = sources.isEmpty ? 0 : RulesRepositoryStore().restoreBackup(sources)
            if let ruleFailure {
                setBackupResult(ruleFailure, isError: true)
                return
            }
            let message = Self.restoreResultMessage(settings: count, rules: restoredRules, sources: addedSources)
            setBackupResult(message, isError: false)
        }
    }

    /// 恢复结果：备份里带了规则/仓库才提它们；只有设置时保持原来那句话。
    private static func restoreResultMessage(settings count: Int, rules: Int, sources: Int) -> String {
        if rules > 0, sources > 0 {
            return String(localized: "已恢复 \(count) 项设置、\(rules) 条规则、\(sources) 个规则仓库")
        }
        if rules > 0 {
            return String(localized: "已恢复 \(count) 项设置、\(rules) 条规则")
        }
        if sources > 0 {
            return String(localized: "已恢复 \(count) 项设置、\(sources) 个规则仓库")
        }
        return String(localized: "已恢复 \(count) 项设置")
    }

    /// 导出到文件：内容与剪贴板那份完全一样，只是走文件系统。
    func exportBackupToFile() {
        backupMessageScope = .file
        guard let text = backupText() else {
            setBackupResult(String(localized: "没有可导出的设置"), isError: true)
            return
        }
        guard !isPickingBackupFile else { return }
        // 先写成一份临时文件，再让用户挑存到哪儿。面板拿到的是本机上一个真实
        // 存在的文件，不经过 SwiftUI 的 FileDocument 那条路。
        let name = "kazumi-settings-\(Self.fileStampText()).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try Data(text.utf8).write(to: tempURL, options: .atomic)
        } catch {
            setBackupResult(String(localized: "存不到这个位置，可能是空间不够，或者没有写入权限"), isError: true)
            return
        }
        isPickingBackupFile = true
        DocumentPickerBridge.export(url: tempURL) { result in
            isPickingBackupFile = false
            switch result {
            case .success:
                // 面板刚退场：等它走完这一拍再改页面，否则结果行会被退场动画吃掉。
                afterPickerDismissed { setBackupResult(String(localized: "已导出到文件"), isError: false) }
            case .failure(let error):
                guard !Self.isCancelled(error) else { return }
                afterPickerDismissed {
                    setBackupResult(String(localized: "存不到这个位置，可能是空间不够，或者没有写入权限"), isError: true)
                }
            }
        }
    }

    /// 从文件恢复：先开面板，选回来再走读取。
    private func pickBackupFile() {
        backupMessageScope = .file
        guard !isPickingBackupFile else { return }
        isPickingBackupFile = true
        // 备份文件是从别的设备、别的工具拿过来的，扩展名不可控：只认 JSON 与文本
        // 会把侧载环境里那一份直接筛掉、在文件面板里根本看不见。
        DocumentPickerBridge.open(types: [.json, .plainText, .data]) { result in
            isPickingBackupFile = false
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // 面板还在退场，这一刻读文件会读到一半被杀；等它退干净。
                afterPickerDismissed { importBackupFromFile(url) }
            case .failure(let error):
                guard !Self.isCancelled(error) else { return }
                afterPickerDismissed {
                    setBackupResult(String(localized: "读不到这个文件，可能已被移动，或者没有访问权限"), isError: true)
                }
            }
        }
    }

    /// 面板退场之后再做下一件事：弹窗、改结果行都在这一拍之后。
    private func afterPickerDismissed(_ work: @escaping () -> Void) {
        // asyncAfter 的闭包要 @Sendable，而 work 里改的是本页状态。
        // 装进一个显式的 unchecked 盒子再递进去：这些调用本来就在主队列上，不存在并发。
        let box = MainQueueWork(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { box.run() }
    }

    private static func isCancelled(_ error: Error) -> Bool {
        if let picker = error as? DocumentPickerBridge.PickerError {
            if case .cancelled = picker { return true }
        }
        return (error as NSError).code == NSUserCancelledError
    }

    private func importBackupFromFile(_ url: URL) {
        // 文件里选来的 URL 在沙箱外，iOS 只给这一小段时间的访问权，读完立刻放。
        // 先走 NSFileCoordinator：iCloud 盘与第三方文件 App 提供的是占位文件，
        // 不经过协调直接 Data(contentsOf:) 常常读到空或报没权限（侧载包里尤其常见）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinated: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            coordinated = try? Data(contentsOf: readURL)
        }
        if let coordinated {
            acceptBackup(Self.text(from: coordinated))
            return
        }
        // 协调失败时退回直接读：本地文件、以及不响应协调的提供器走这条。
        do {
            let data = try Data(contentsOf: url)
            acceptBackup(Self.text(from: data))
        } catch {
            setBackupResult(String(localized: "读不到这个文件，可能已被移动，或者没有访问权限"), isError: true)
        }
    }

    /// 剪贴板与文件两条路共用：解码 → 计数 → 弹确认框。
    private func acceptBackup(_ raw: String) {
        do {
            let payload = try SettingsBackup.decode(raw)
            guard payload.count > 0 else {
                setBackupResult(Self.emptyBackupMessage, isError: true)
                return
            }
            pendingPayload = payload
            // 文件面板刚关掉时立刻挂弹窗，SwiftUI 会把弹窗吞掉（选完文件像什么都没发生）。
            // 等面板真正退干净的下一拍再挂，两条路共用这个口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard pendingPayload != nil else { return }
                isShowingRestoreConfirm = true
            }
        } catch {
            setBackupResult(error.localizedDescription, isError: true)
        }
    }

    /// 文件不一定是这边写出去的：Windows 备忘录、旧版工具会给 UTF-16 或带 BOM 的文本。
    /// UTF-8 读不通就按 UTF-16 再读一次，都读不通才当坏文件。
    private static func text(from data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fileStampText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private var restoreConfirmMessage: String {
        guard let payload = pendingPayload else { return "" }
        var blocks = [
            String(localized: "备份时间：\(Self.timestampText(payload.exportedAt))\n")
                + String(localized: "共 \(payload.count) 项设置，将覆盖当前设置。"),
        ]
        // 规则与仓库只说会怎么合并，不说会删什么：恢复这两样都是合并，不覆盖。
        if payload.ruleCount > 0 {
            blocks.append(String(localized: "备份里还有 \(payload.ruleCount) 条规则，会一起合并进来，同名规则以备份为准。"))
        }
        if payload.ruleSourceCount > 0 {
            blocks.append(String(localized: "备份里还有 \(payload.ruleSourceCount) 个规则仓库，会一起加进来。"))
        }
        if payload.settings.keys.contains(where: SettingsBackup.credentialKeys.contains) {
            blocks.append(String(localized: "恢复后请检查追番同步、多设备同步和自定义弹幕接口的凭据。"))
        }
        blocks.append(String(localized: "引导步骤、通知权限、设备同步状态不会被改动。"))
        return blocks.joined(separator: "\n\n")
    }

    private static func timestampText(_ date: Date?) -> String {
        guard let date else { return String(localized: "时间未知") }
        // 日期跟手机格式走，时刻写死 24 小时（LP 6109 / 6118）。
        return "\(SystemDateText.date(date, includeYear: true)) \(KazumiTimeText.clock(date))"
    }
}

/// 把主队列闭包塞进 @Sendable 的 dispatch 闭包用：调用点都在主队列上，不存在并发。
private struct MainQueueWork: @unchecked Sendable {
    private let work: () -> Void

    init(_ work: @escaping () -> Void) {
        self.work = work
    }

    func run() {
        work()
    }
}
