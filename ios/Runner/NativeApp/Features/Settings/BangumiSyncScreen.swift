//
//  BangumiSyncScreen.swift
//  Kazumi
//
//  设置 → 同步设置 → 追番同步（对应 lib/pages/settings/sync/bangumi_sync_page.dart）。
//
//  版面按 Colo 2026-10-25 的重排落，四段：
//  Bangumi 账号 / 同步 / 同步结果 / 同步偏好。
//  令牌默认折起来，折着也看得出「已保存」还是「已连接 · 用户名」；
//  「保存并测试」和「获取授权码」留在折区外面 —— 后者是没有令牌的人唯一的入口。
//  「冲突时以谁为准」由三行选项改成一行选择器，把高度让给一屏。
//
//  所有开关都由 BangumiSyncEngine 真实消费 —— 拨了会改变行为，不是摆着好看。
//  与 WebDAV 那页的分工：那页管「本机 ⇄ 备份文件」，这页管「本机 ⇄ Bangumi」。
//

import SwiftUI

struct BangumiSyncScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    /// 正在跑的那件事。同一时间只允许一件：验证和同步共用令牌，交叉跑会互相踩。
    private enum Action {
        case verify
        case connect
        case sync
    }

    @State private var tokenText = ""
    @State private var isTokenVisible = false
    @State private var isTokenExpanded = false
    @State private var action: Action?
    @State private var tokenError: String?
    @State private var tokenStatus: String?
    @State private var message: String?
    @State private var failed = false
    @State private var progress: Double?
    /// 同步失败要留在弹窗里说，不能跟着页面滚走。
    @State private var syncDialogFailure: String?

    @AppStorage("bangumiLastSyncAt") private var lastSyncAt: Double = 0
    @AppStorage("bangumiLastSyncSummary") private var lastSyncSummary = ""
    @AppStorage("bangumiLastSyncError") private var lastSyncError = ""

    private var engine: BangumiSyncEngine { environment.bangumiSync }
    private var settings: SettingsStore { environment.settings }

    private var savedToken: String {
        settings.bangumiAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var configured: Bool { !savedToken.isEmpty }

    private var busy: Bool { action != nil || engine.isConnecting }

    var body: some View {
        Form {
            accountSection
            syncSection
            resultSection
            preferenceSection
        }
        .overlay {
            if action == .sync || syncDialogFailure != nil {
                SyncProgressDialog(
                    stage: progressText,
                    value: progress,
                    failure: syncDialogFailure,
                    onClose: { syncDialogFailure = nil }
                )
            }
        }
        .navigationTitle("追番同步")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .toolbar {
            // 同步进行中不给返回：中途退出去，用户不知道那半截到底写没写进 Bangumi。
            if busy {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear {
            if tokenText.isEmpty { tokenText = savedToken }
            // 没存过令牌时才摊开：存过的折起来，眼睛不用再翻一遍那串字符。
            isTokenExpanded = savedToken.isEmpty
        }
    }

    // MARK: - 段一 Bangumi 账号

    private var accountSection: some View {
        Section {
            Group {
                // 折叠钮自己是一行，展开的框和按钮是它下面的兄弟行——跟 WebDAV 一样，
                // Form 才会在行与行之间画那根灰线（LP 5402 / 5407）。
                Button {
                    isTokenExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("Access Token")
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 8)
                        Text(tokenSummary)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .rotationEffect(.degrees(isTokenExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Access Token")
                .accessibilityValue(tokenSummary)
                .accessibilityHint(isTokenExpanded ? "收起令牌" : "展开令牌")

                if isTokenExpanded {
                    // 框自己一行：这一行不加标签，上面那行已经是「Access Token」。
                    HStack(spacing: 8) {
                        // 框里那句照 main 的 labelText: 'Access Token' 带回来（LP「原来有就加回去」）：
                        // 空着的时候框里看得见字，不是只剩右边一只眼睛。
                        Group {
                            if isTokenVisible {
                                TextField("Access Token", text: $tokenText)
                            } else {
                                SecureField("Access Token", text: $tokenText)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(busy)
                        // 空的时候框会被挤成 0 宽，眼睛就掉到下一行去了。
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: tokenText) {
                            tokenError = nil
                            tokenStatus = nil
                        }

                        Button {
                            isTokenVisible.toggle()
                        } label: {
                            Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                                .frame(width: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .accessibilityLabel(isTokenVisible ? "隐藏访问令牌" : "显示访问令牌")
                    }

                    // 两颗按钮同一行、一样大：左「获取授权码」，右「保存并测试」。
                    HStack(spacing: 12) {
                        Button {
                            openTokenPage()
                        } label: {
                            HStack(spacing: 4) {
                                Text("获取授权码")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button {
                            saveToken()
                        } label: {
                            Text(action == .verify ? "正在测试…" : "保存并测试")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(busy)
                }
            }
            // Colo 3532：Form 行底色显式取 groupedRow，不依赖系统动态色。
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("Bangumi 账号")
        } footer: {
            // 三种状态挤在一行：未连接 / 已连接 / 出错。红字留给破坏性操作，这里用橙。
            Text(tokenError ?? tokenStatus ?? accountHint)
                .foregroundStyle(tokenError == nil ? Color.secondary : Color.orange)
        }
    }

    /// 折起来那一行右边写什么：连着就写用户名，存过就写「已保存」，没存过写「未填写」。
    private var tokenSummary: String {
        // 用户名存下来就一直显示（LP 5429），只有真没登录过才说「已保存」。
        if engine.initialized || engine.hasSavedAccount { return engine.username }
        if configured { return "已保存" }
        return "未填写"
    }

    private var accountHint: String {
        if engine.initialized { return "已连接 · \(engine.username)" }
        // 重启后还没验证过，但用户名存着：照账号显示，不说「尚未验证」（LP 5429）。
        if engine.hasSavedAccount { return "已登录 · \(engine.username)" }
        if configured { return "令牌已保存，尚未验证" }
        return "使用 Access Token 授权，令牌只存在本机"
    }

    // MARK: - 段二 同步

    private var syncSection: some View {
        Section {
            Group {
                Toggle("自动同步追番", isOn: Binding(
                    get: { settings.bangumiSyncEnable },
                    set: { toggleAutoSync($0) }
                ))
                .disabled(busy)

                Button {
                    startSync()
                } label: {
                    Text(action == .sync ? "正在同步…" : "立即同步追番")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy || !settings.bangumiSyncEnable || needsVerify)
            }
            .disabled(!configured)
            .opacity(configured ? 1 : 0.45)
            .accessibilityValue(configured ? "" : "需要先连接")
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("同步")
        } footer: {
            Text("改追番状态时同步到 Bangumi；只同步追番状态，不动观看进度。")
        }
    }

    /// 输入框里改了却没验证的令牌不能拿来同步：那一串还没被服务器认过。
    private var needsVerify: Bool {
        savedToken != tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 段三 同步结果

    private var resultSection: some View {
        Section {
            Group {
                Text(lastSyncLine)
                    .frame(minHeight: 24, alignment: .leading)

                if !lastSyncError.isEmpty {
                    Text(lastSyncError)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !lastSyncSummary.isEmpty {
                    Text(lastSyncSummary)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("同步结果")
        }
    }

    private var progressText: String {
        message ?? "正在连接 Bangumi…"
    }

    private var lastSyncLine: String {
        guard lastSyncAt > 0 else { return "还没同步过" }
        let date = Date(timeIntervalSince1970: lastSyncAt)
        // 语言固定中文（Camo 4914：跟着手机语言走会漏出「6:00 PM」）。
        let time = KazumiTimeText.clock(date)
        if Calendar.current.isDateInToday(date) { return "上次同步 今天 \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "上次同步 昨天 \(time)" }
        return "上次同步 \(SystemDateText.date(date, includeYear: false)) \(time)"
    }

    // MARK: - 段四 同步偏好

    private var preferenceSection: some View {
        Section {
            Group {
                Picker("冲突时以谁为准", selection: Binding(
                    get: { settings.bangumiSyncPriority },
                    set: { settings.bangumiSyncPriority = $0 }
                )) {
                    ForEach(BangumiSyncPriority.allCases) { option in
                        Text(option.optionTitle).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(busy)

                Toggle("同步结果提示", isOn: Binding(
                    get: { settings.bangumiImmediateSyncToastEnable },
                    set: { settings.bangumiImmediateSyncToastEnable = $0 }
                ))
                .disabled(busy)

                Toggle("自动标记看过", isOn: Binding(
                    get: { settings.bangumiAutoMarkWatched },
                    set: { settings.bangumiAutoMarkWatched = $0 }
                ))
                .disabled(busy)
            }
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("同步偏好")
        } footer: {
            Text("播放到 90% 时在 Bangumi 标记该集为看过；默认关闭。")
        }
    }

    // MARK: - 动作

    private func saveToken() {
        guard !busy else { return }
        let trimmed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tokenError = "请填写 Access Token"
            return
        }
        action = .verify
        tokenError = nil
        tokenStatus = nil
        syncDialogFailure = nil
        Task {
            defer { action = nil }
            do {
                try await engine.saveToken(trimmed)
                tokenText = trimmed
                isTokenExpanded = false
                tokenStatus = "已连接 · \(engine.username)"
            } catch {
                tokenError = "\(BangumiSyncEngine.describeError(error))。修改未保存"
            }
        }
    }

    private func openTokenPage() {
        guard let url = URL(string: "https://next.bgm.tv/demo/access-token") else { return }
        openURL(url) { accepted in
            if !accepted { tokenError = "无法打开浏览器，请稍后重试" }
        }
    }

    private func toggleAutoSync(_ enabled: Bool) {
        guard !busy else { return }
        action = .connect
        Task {
            defer { action = nil }
            await engine.setEnabled(enabled)
            // 打开时验证不过就保持关着，并把原因说清楚；不假装已经打开。
            if enabled, let lastError = engine.lastError {
                lastSyncError = lastError
                failed = true
            }
        }
    }

    private func startSync() {
        guard !busy else { return }
        // 输入框里改了却没验证的令牌不能拿来同步：那一串还没被服务器认过。
        guard !needsVerify else {
            lastSyncError = "账号信息已修改，请先保存并测试。"
            return
        }
        action = .sync
        failed = false
        progress = nil
        message = "正在连接 Bangumi…"
        Task {
            defer { action = nil }
            do {
                try await engine.syncCollectibles { text, current, total in
                    message = total > 0 ? "\(text) · \(current) / \(total)" : text
                    progress = total > 0 ? min(max(Double(current) / Double(total), 0), 1) : nil
                }
                let summary = "追番状态已同步"
                lastSyncAt = Date().timeIntervalSince1970
                lastSyncError = ""
                lastSyncSummary = summary
                message = nil
                // 成功：进度条拉满，停 0.5 秒再收（Colo 2026-10-28）。
                progress = 1
                try? await Task.sleep(nanoseconds: 500_000_000)
                progress = nil
            } catch {
                lastSyncAt = Date().timeIntervalSince1970
                lastSyncError = BangumiSyncEngine.describeError(error)
                lastSyncSummary = ""
                message = nil
                progress = nil
                failed = true
                syncDialogFailure = BangumiSyncEngine.describeError(error)
            }
        }
    }
}
