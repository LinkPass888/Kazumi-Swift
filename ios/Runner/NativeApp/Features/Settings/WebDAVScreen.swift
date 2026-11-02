//
//  WebDAVScreen.swift
//  Kazumi
//
//  设置 →「同步设置」→「多设备同步」。
//
//  版面按 Colo 2026-10-25 的重排落，四段从上到下：
//  连接你的云盘 / 要同步什么 / 立即同步 / 同步结果，一屏之内。
//  账密默认折起来（LP 同日：账密能默认折叠最好），折着也看得到主机名；
//  「保存并测试」和结果行留在折区外面，不展开也能连、也能看见结果。
//  没连通时下面两段整块灰掉 —— 灰的开关不能点，也不能假装能同步。
//
//  LP 2026-10-25：三个内容开关只管记住「同步哪几类」，拨一下不许当场跑一次同步。
//  自动同步的时机跟原版一致（lib/pages/init_page.dart、player_item.dart）：
//  启动时、退出播放器时各并一轮，改动开关本身不触发。
//

import SwiftUI

struct WebDAVScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(\.colorScheme) private var colorScheme

    @State private var isBusy = false
    /// 「保存并测试」进行中。单独一个，不拿 isBusy——同步也占着它，
    /// 共用会让同步时那颗按钮写着「正在测试…」（Ato 6376）。
    @State private var isTesting = false
    @State private var isSyncing = false
    @State private var progress: SyncProgress?
    /// 同步失败留在弹窗里说。
    @State private var syncDialogFailure: String?
    /// 顶部 banner（失败不自动收、开关被拦自动收）。
    @State private var banner: KazumiBannerState?
    @State private var isCredentialsExpanded = false

    @AppStorage("webDavLastSyncAt") private var lastSyncAt: Double = 0
    @AppStorage("webDavLastSyncSummary") private var lastSyncSummary = ""
    @AppStorage("webDavLastSyncError") private var lastSyncError = ""

    /// 同步中那一条进度：没有总数就不画进度条。
    private struct SyncProgress {
        var text: String
        var value: Double?
    }

    var body: some View {
        Form {
            connectionSection
            enableSection
            contentSection
            runSection
            resultSection
        }
        .overlay {
            if isSyncing || syncDialogFailure != nil {
                SyncProgressDialog(
                    stage: progress?.text ?? String(localized: "正在连接云盘…"),
                    value: progress?.value,
                    failure: syncDialogFailure,
                    onClose: { syncDialogFailure = nil }
                )
            }
        }
        .overlay(alignment: .top) {
            if let banner {
                KazumiBanner(
                    title: banner.title,
                    detail: banner.detail,
                    mode: banner.mode,
                    onDismiss: { withAnimation(.snappy) { self.banner = nil } }
                )
            }
        }
        .animation(.snappy, value: banner != nil)
        .navigationTitle("多设备同步")
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .onAppear {
            // 地址空着就没有可折的东西：直接摊开，第一次用的人少点一下。
            if settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isCredentialsExpanded = true
            }
        }
    }

    // MARK: - 段一 连接你的云盘

    private var connectionSection: some View {
        Section {
            // 每一行都单独成行：字段挤在一个 VStack 里当一行，Form 的分隔线只画到
            // 那一行的内容宽，右边就少一截（LP 2026-10-28「灰色细线少一截」）。
            credentialsRow

            // 存过了就整组收起来：账密、输入框、按钮全在折区里（LP 2026-10-28）。
            if isCredentialsExpanded {
                // LP 5375/5377：每行左边有标题，框里同义的灰字删掉。
                HStack(spacing: 8) {
                    Text("服务器地址")
                        .frame(width: 88, alignment: .leading)
                    Spacer(minLength: 8)
                    TextField("", text: webDAVURLBinding)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("用户名")
                        .frame(width: 88, alignment: .leading)
                    Spacer(minLength: 8)
                    TextField("", text: webDAVUserBinding)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("密码")
                        .frame(width: 88, alignment: .leading)
                    Spacer(minLength: 8)
                    Group {
                        if isPasswordVisible {
                            TextField("", text: webDAVPasswordBinding)
                        } else {
                            SecureField("", text: webDAVPasswordBinding)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .frame(width: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPasswordVisible ? "隐藏密码" : "显示密码")
                }

                // 按钮回原版：满宽居中，行里什么都不放（Ato 6432 §十一）。
                // 进行中在按钮里转圈＋「正在测试…」＋禁用（Ato 6398 二）。
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack(spacing: 6) {
                        // 圈一直占着位，只换透明——三种状态下按钮宽度一格不动。
                        ProgressView()
                            .controlSize(.small)
                            .opacity(isTesting ? 1 : 0)
                        Text(isTesting ? "正在测试…" : "保存并测试")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !hasCredentials)
            }
        } header: {
            Text("连接你的云盘")
        } footer: {
            Text("地址、账号和密码只存在这台设备上，同步时直连你自己的云盘。")
        }
        // 折起来、摊开只换高度，别给高度加隐式动画——那一行位置没动，抖是动画抖的。
        .animation(nil, value: isCredentialsExpanded)
    }

    /// 总开关自己一段：不跟账密挤在一组（LP 2026-10-28）。
    private var enableSection: some View {
        Section {
            Toggle("启用 WebDAV", isOn: enableBinding)
                .disabled(!hasCredentials)
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } footer: {
            Text("关掉之后不再自动同步，手动同步也停用。")
        }
    }

    /// 折叠行本身：左边「服务器」，右边主机名，一颗会转的箭头。
    private var credentialsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isCredentialsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("WebDAV")
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    // 展开时也显示摘要（LP「展开时也显示」）。
                    Text(serverSummary)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(isCredentialsExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("WebDAV")
            .accessibilityValue(serverSummary)
            .accessibilityHint(isCredentialsExpanded ? "收起地址与账号" : "展开地址与账号")

        }
    }

    @State private var isPasswordVisible = false

    /// 折起来的那一行：账号 @ 主机名，没填过写「未填写」。
    private var serverSummary: String {
        let raw = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "未填写" }
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        let host = URL(string: withScheme)?.host ?? raw
        let user = settings.webDAVUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return host }
        return "\(user)@\(host)"
    }

    // MARK: - 段二 要同步什么

    private var contentSection: some View {
        Section {
            Group {
                Toggle("观看记录", isOn: historyBinding)
                Toggle("收藏", isOn: collectBinding)
                Toggle("弹幕屏蔽词", isOn: shieldBinding)
            }
            .disabled(!canSync)
            .opacity(canSync ? 1 : 0.45)
            .accessibilityValue(canSync ? "" : "需要先连接")
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("要同步什么")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("启动 App、退出全屏时自动同步播放进度和历史记录。")
                Text("屏蔽词：修改规则后自动同步。")
                Text("进收藏页时同步一次。原版 Kazumi 的收藏能读进来，这边新加的写不回原版。")
            }
        }
    }

    // MARK: - 段三 立即同步

    private var runSection: some View {
        Section {
            Group {
                Button {
                    Task { await runSync(WebDAVSync.enabledContents(settings)) }
                } label: {
                    Text(isSyncing ? "正在同步…" : "立即同步")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canSync || isBusy || WebDAVSync.enabledContents(settings).isEmpty)

            }
            .disabled(!canSync)
            .opacity(canSync ? 1 : 0.45)
            .accessibilityValue(canSync ? "" : "需要先连接")
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("立即同步")
        }
    }

    // MARK: - 段四 同步结果

    private var resultSection: some View {
        Section {
            Group {
                // Colo 6401 §十一：那两行条件性的成功摘要／失败原因并进一直在的
                // 「上次同步」里——一个 VStack 就是一行，分组里不多顶一行出来。
                VStack(alignment: .leading, spacing: 4) {
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
            }
            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
        } header: {
            Text("同步结果")
        } footer: {
            if !lastSyncError.isEmpty {
                Text("下一次同步成功后会换回正常字样。")
            }
        }
    }

    private var lastSyncLine: String {
        guard lastSyncAt > 0 else { return String(localized: "还没同步过") }
        let date = Date(timeIntervalSince1970: lastSyncAt)
        let calendar = Calendar.current
        // 语言固定中文（Camo 4914：跟着手机语言走会漏出「6:00 PM」）。
        let time = KazumiTimeText.clock(date)
        if calendar.isDateInToday(date) { return String(localized: "上次同步 今天 \(String(describing: time))") }
        if calendar.isDateInYesterday(date) { return String(localized: "上次同步 昨天 \(String(describing: time))") }
        return String(localized: "上次同步 \(String(describing: SystemDateText.date(date, includeYear: false))) \(String(describing: time))")
    }

    // MARK: - 绑定

    private var webDAVURLBinding: Binding<String> {
        Binding(get: { settings.webDAVURL }, set: { settings.webDAVURL = $0 })
    }

    private var webDAVUserBinding: Binding<String> {
        Binding(get: { settings.webDAVUser }, set: { settings.webDAVUser = $0 })
    }

    private var webDAVPasswordBinding: Binding<String> {
        Binding(get: { settings.webDAVPassword }, set: { settings.webDAVPassword = $0 })
    }

    /// 总开关只存值；打开的那一刻顺手并一轮（LP 2026-10-25：开启后要自动同步）。
    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.webDavEnable },
            set: { newValue in
                settings.webDavEnable = newValue
                guard newValue else { return }
                Task { await syncOnEnable() }
            }
        )
    }

    /// 「同步哪几类」的三个开关同样只存值：要同步就按下面的「立即同步」。
    private var historyBinding: Binding<Bool> {
        Binding(
            get: { settings.webDavEnableHistory },
            set: { settings.webDavEnableHistory = $0 }
        )
    }

    private var collectBinding: Binding<Bool> {
        Binding(
            get: { settings.webDavEnableCollect },
            set: { settings.webDavEnableCollect = $0 }
        )
    }

    private var shieldBinding: Binding<Bool> {
        Binding(
            get: { settings.webDavEnableDanmakuShield },
            set: { settings.webDavEnableDanmakuShield = $0 }
        )
    }

    /// 三格齐了才算配置过：只有地址，等于替一个没账号的服务器担保。
    private var hasCredentials: Bool {
        !settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.webDAVUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.webDAVPassword.isEmpty
    }

    private var canSync: Bool {
        hasCredentials && settings.webDavEnable
    }

    // MARK: - 同步

    private func runSync(_ contents: [WebDAVSync.Content]) async {
        guard !isBusy else { return }
        isBusy = true
        isSyncing = true
        progress = nil
        syncDialogFailure = nil
        defer {
            isBusy = false
            isSyncing = false
            progress = nil
        }
        let outcome = await WebDAVSync.sync(
            contents,
            settings: settings,
            library: library
        ) { event in
            progress = SyncProgress(
                text: event.text,
                value: event.total > 0 ? min(max(Double(event.current) / Double(event.total), 0), 1) : nil
            )
        }

        // 结果只落进段四：段一那行管的是「连得上吗」，不重复同一句话。
        let now = Date().timeIntervalSince1970
        lastSyncAt = now
        if outcome.ok {
            lastSyncError = ""
            lastSyncSummary = outcome.summary
            // 进度条拉满，停 0.5 秒再收（Colo 2026-10-28）。
            progress = SyncProgress(text: outcome.summary, value: 1)
            try? await Task.sleep(nanoseconds: 500_000_000)
        } else {
            lastSyncError = outcome.message
            lastSyncSummary = ""
            syncDialogFailure = outcome.message
        }
        KazumiLogBuffer.network(outcome.log)
    }

    /// 打开总开关后自己跑的那一轮：选过内容就按选的那几类并，
    /// 一类都没选就只连一下，至少让「已开启」这句话是真的。
    private func syncOnEnable() async {
        let contents = WebDAVSync.enabledContents(settings)
        guard !contents.isEmpty else {
            await saveAndTest()
            return
        }
        await runSync(contents)
    }

    // MARK: - 连接

    /// 账密就在上面几格，改完这一颗把地址落盘，顺手 ping 一次。
    private func saveAndTest() async {
        settings.webDAVURL = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        isTesting = true
        defer {
            isBusy = false
            isTesting = false
        }
        do {
            try await WebDAVClient(settings: settings).ping()
            withAnimation(.snappy) {
                banner = KazumiBannerState(title: "连接正常", variant: .success, mode: .automatic)
            }
            KazumiLogBuffer.network("WebDAV 保存并测试：连接通过")
        } catch {
            // 失败走顶部 banner：一行说结论，一行说怎么办（Ato 6432 §十一/十二）。
            let reason = WebDAVSync.friendlyText(error)
            withAnimation(.snappy) {
                banner = KazumiBannerState(
                    title: String(localized: "无法连接 WebDAV"),
                    detail: reason,
                    variant: .failure,
                    mode: .automatic
                )
            }
            KazumiLogBuffer.network("WebDAV 保存并测试失败：\(WebDAVSync.technicalText(error))")
        }
    }
}
