//
//  OnboardingFlow.swift
//  Kazumi
//
//  首次引导四屏：欢迎 → 访问加速 → 添加番剧来源 → 完成。
//  顺序与屏上文案照 Colo 的规格 v1.2 / Camo 的定稿，不再另写一套。
//

import SwiftUI

struct OnboardingFlow: View {
    /// 引导还开着没有。完成页写 `onboardingCompleted` 之后根视图不能立刻把这一屏抽走，
    /// 所以由这里多按住一会儿，直到用户点「开始使用」。
    @Binding var isActive: Bool

    @State private var path: [Step] = []

    enum Step: Hashable {
        case network
        case rules
        case completion
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep { path.append(.network) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .network:
                        NetworkStep { path.append(.rules) }
                    case .rules:
                        RuleSourceStep(
                            onSkip: { path.append(.completion) },
                            onContinue: { path.append(.completion) }
                        )
                    case .completion:
                        CompletionStep { isActive = false }
                    }
                }
        }
        .onAppear { isActive = true }
    }
}

/// 引导页底部那颗主按钮。
struct OnboardingPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    KazumiPalette.accent(for: colorScheme),
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 固定的底部动作区：内容滚动，按钮不动。
struct OnboardingBottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme))
    }
}

/// 引导页的统一底板：iPhone 左右 16，iPad 最宽 620 居中。
struct OnboardingPage<Content: View>: View {
    var centered: Bool = false
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(centered ? .center : .top)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}
