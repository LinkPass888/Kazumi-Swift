//
//  AppRoot.swift
//  Kazumi
//
//  根视图：存储失败时展示错误页；否则进入自适应液态玻璃 TabView。
//  启动后先检查应用更新（有新版就弹更新日志），再检查规则更新。
//

import SwiftUI

struct AppRoot: View {
    var failure: AppEnvironment.StartupFailure?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var isShowingAppUpdate = false
    /// 首次引导还开着没有。完成页已经写过 `onboardingCompleted`，
    /// 这里多按住一会儿，等用户点「开始使用」再切到主界面。
    @State private var isOnboardingActive = false

    /// 强调色。`KazumiPalette` 是静态取值，这里显式读一下配色设置，
    /// 换配色时 AppRoot 才会重算（视图树不再整体重建，见 `KazumiApp` 那段注释）。
    private var accentColor: Color {
        _ = environment.settings.themeColor
        return KazumiPalette.accent(for: colorScheme)
    }

    var body: some View {
        Group {
            if let failure {
                StorageErrorView(failure: failure)
            } else if !settings.onboardingCompleted || isOnboardingActive {
                OnboardingFlow(isActive: $isOnboardingActive)
            } else {
                KazumiTabShell()
            }
        }
        // 强调色按 SwiftUI 的当前明暗显式取：这里能读到 `colorScheme`（= 设置里的
        // 主题模式），不再走 UIKit 动态色那条路。
        .tint(accentColor)
        .onAppear {
            environment.router.isRootMounted = failure == nil
            // 冷启动时意图可能早于根视图就绪，先把它要去的页面补发出去。
            if let link = AppRouter.pendingFromIntent {
                AppRouter.pendingFromIntent = nil
                environment.router.open(link)
            }
            environment.router.onExternalNavigationRequested?()
        }
        .onChange(of: environment.router.externalNavigationDeferralCount) { _, count in
            if count == 0 { environment.router.onExternalNavigationRequested?() }
        }
        .onChange(of: environment.router.externalNavigationRevision) { _, _ in
            isShowingAppUpdate = false
        }
        .task {
            guard failure == nil else { return }
            await environment.updates.checkOnLaunch(
                settings: environment.settings,
                plugins: environment.plugins
            )
            if environment.updates.appUpdate != nil,
               environment.router.externalNavigationRevision == 0,
               environment.router.pendingExternalLink == nil {
                isShowingAppUpdate = true
            }
        }
        // 选源面板挂在根层弹（Colo 2026-10-28）：推荐页的轮播那一页太重，
        // 从它里面弹面板要先重排整页，量出来面板 3.6 秒才出现。
        .sheet(isPresented: Binding(
            get: { SourceSheetCoordinator.shared.isPresented },
            set: { SourceSheetCoordinator.shared.isPresented = $0 }
        ), onDismiss: {
            SourceSheetCoordinator.shared.dismiss()
            SourceSheetCoordinator.shared.clearIfNeeded()
            environment.router.onExternalNavigationRequested?()
        }) {
            if let controller = SourceSheetCoordinator.shared.controller {
                SourceSheet(
                    controller: controller,
                    onPlay: { name, item in
                        SourceSheetCoordinator.shared.onPlay?(name, item)
                    },
                    onOpenRuleShop: {
                        SourceSheetCoordinator.shared.onOpenRuleShop?()
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingAppUpdate, onDismiss: {
            environment.updates.appUpdate = nil
        }) {
            if let notice = environment.updates.appUpdate {
                AppUpdateSheet(
                    notice: notice,
                    onSkip: {
                        settings.skippedAppUpdateVersion = notice.version
                        isShowingAppUpdate = false
                    },
                    onDownload: {
                        openURL(KazumiAppInfo.releasesURL)
                        isShowingAppUpdate = false
                    },
                    onLater: {
                        isShowingAppUpdate = false
                    }
                )
            }
        }
    }
}

private struct AppUpdateSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    // Colo 8654：符号 20pt，跟文字基线对齐；同写 22 时 SF Symbols 看着大一号。
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var captionFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var notesFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var buttonFontSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var downloadMinHeight: CGFloat = 56
    // Colo 8595：下面一行两颗同规格，等分宽、中间 12、同高 44、纯文字。
    @ScaledMetric(relativeTo: .body) private var rowButtonMinHeight: CGFloat = 44

    let notice: AppUpdateService.AppUpdateNotice
    let onSkip: () -> Void
    let onDownload: () -> Void
    let onLater: () -> Void

    /// 底部三个操作，固定在正文下方。
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button(action: onDownload) {
                Text("前往下载")
                    .font(.system(size: buttonFontSize, weight: .semibold))
                    .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: downloadMinHeight)
                    .background {
                        RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
                            .fill(KazumiPalette.accent(for: colorScheme))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            // LP 8592：跳过此版本与稍后并到同一行，跳过在左、稍后在右。
            HStack(spacing: 12) {
                Button(action: onSkip) {
                    Text("跳过此版本 \(notice.version)")
                        .font(.system(size: buttonFontSize))
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: rowButtonMinHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("跳过此版本 \(notice.version) 的提醒"))

                Button(action: onLater) {
                    Text("稍后")
                        .font(.system(size: buttonFontSize))
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: rowButtonMinHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var trimmedNotes: String {
        notice.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        // 正文区只占按钮以上的高度：滚动内容画不到按钮那一块，底部也不会压半行字。
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // LP 8645：全部一行——符号、「发现新版本」、版本号、当前版本，从左边排过来，不换行。
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: iconSize))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("发现新版本")
                        Text(notice.version)
                            .foregroundStyle(Color.primary)
                    }
                    .font(.title2)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .padding(.leading, 10)

                    Text("当前版本 \(KazumiAppInfo.version)")
                        .font(.system(size: captionFontSize))
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .padding(.leading, 8)

                    Spacer(minLength: 0)
                }
                // Colo 8647：默认字号一行放得下；大字号放不下就折行，不缩字号、不截断。
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("发现新版本 \(notice.version)，当前版本 \(KazumiAppInfo.version)"))

                Group {
                    if trimmedNotes.isEmpty {
                        Text("这个版本没有写更新日志。")
                    } else {
                        Text(verbatim: trimmedNotes)
                    }
                }
                .font(.system(size: notesFontSize))
                .foregroundStyle(trimmedNotes.isEmpty ? KazumiPalette.secondaryText(for: colorScheme) : Color.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        bottomBar
        }
        .presentationDetents([.medium])
    }
}
