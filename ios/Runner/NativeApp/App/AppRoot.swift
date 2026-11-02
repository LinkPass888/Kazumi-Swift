//
//  AppRoot.swift
//  Kazumi
//
//  根视图：存储失败时展示错误页；否则进入自适应液态玻璃 TabView。
//  启动后先检查应用更新（有新版就弹更新日志），再检查规则更新。
//

import AppIntents
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
        .onAppIntentExecution(OpenAnimeIntent.self) { intent in
            guard intent.anime.id > 0,
                  environment.library.entry(for: intent.anime.id) != nil
                    || environment.library.record(for: intent.anime.id) != nil else { return }
            environment.router.open(.bangumi(intent.anime.id))
        }
        .onAppIntentExecution(SearchAnimeIntent.self) { intent in
            let query = intent.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            environment.router.open(.search(query))
        }
        .onAppIntentExecution(OpenLibraryIntent.self) { _ in
            environment.router.open(.library)
        }
        .onAppIntentExecution(OpenHistoryIntent.self) { _ in
            environment.router.open(.history)
        }
        .onAppIntentExecution(OpenDownloadsIntent.self) { _ in
            environment.router.open(.downloads)
        }
        .onAppear {
            environment.router.isRootMounted = failure == nil
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
        .alert(
            "发现新版本 \(environment.updates.appUpdate?.version ?? "")",
            isPresented: $isShowingAppUpdate
        ) {
            Button("查看更新日志") {
                openURL(KazumiAppInfo.releasesURL)
                environment.updates.appUpdate = nil
            }
            Button("稍后", role: .cancel) {
                environment.updates.appUpdate = nil
            }
        } message: {
            Text(updateMessage)
        }
    }

    /// 更新日志：release body 可能很长，这里截断成几行提示。
    private var updateMessage: String {
        let notes = environment.updates.appUpdate?.notes ?? ""
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(localized: "当前版本 \(String(describing: KazumiAppInfo.fullVersion))，可以到项目主页下载新版本。")
        }
        return String(trimmed.prefix(400))
    }
}
