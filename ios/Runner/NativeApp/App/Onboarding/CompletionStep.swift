//
//  CompletionStep.swift
//  Kazumi
//
//  引导最后一屏。装了规则说「可以开始追番了」，没装说「进去后随时可以添加」。
//

import SwiftUI

struct CompletionStep: View {
    let onStart: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var iconScale: CGFloat = 0.86

    private var installedCount: Int { plugins.pluginList.count }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 76, height: 76)
                .background(
                    KazumiPalette.accent(for: colorScheme).opacity(0.16),
                    in: Circle()
                )
                .scaleEffect(iconScale)
                .accessibilityHidden(true)

            Text("设置完成")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .safeAreaInset(edge: .bottom) {
            OnboardingBottomBar {
                OnboardingPrimaryButton(title: "开始使用", action: onStart)
            }
        }
        .onAppear {
            // 完成页一出现就算引导走完：这一屏被杀掉，下次也直接进主界面。
            settings.onboardingCompleted = true
            guard !reduceMotion else {
                iconScale = 1
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { iconScale = 1 }
        }
    }

    private var detail: LocalizedStringKey {
        installedCount > 0
            ? "已安装 \(installedCount) 条规则，可以开始追番了。"
            : "还没安装规则，进去后随时可以添加。"
    }
}
