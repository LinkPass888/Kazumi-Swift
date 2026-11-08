//
//  WelcomeStep.swift
//  Kazumi
//
//  引导第一屏：图标、标题、三行说明、同意文案，底部「继续」。
//

import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    @State private var agreement: UsageAgreement.LoadState = .loading
    @State private var isShowingAgreement = false

    var body: some View {
        OnboardingPage(centered: true) {
            VStack(spacing: 0) {
                Image("OnboardingIcon")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
                    .accessibilityHidden(true)

                Text("欢迎使用 Kazumi")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                Text("一款开源、可自定义番剧来源的追番客户端。")
                    .font(.subheadline)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    featureRow(
                        symbol: "doc.text",
                        title: "规则决定来源",
                        detail: "添加规则后，才能搜索和播放番剧"
                    )
                    Divider().padding(.leading, 61)
                    featureRow(
                        symbol: "calendar",
                        title: "时间表",
                        detail: "按周几查看当天更新的番剧"
                    )
                    Divider().padding(.leading, 61)
                    featureRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "进度与备份",
                        detail: "Bangumi 同步、WebDAV 备份"
                    )
                }
                .background {
                    KazumiPalette.cardShape(
                        cornerRadius: KazumiPalette.cardCornerRadius,
                        scheme: colorScheme,
                        bordered: false
                    )
                }
                .padding(.top, 30)

                agreementLine
                    .padding(.top, 18)
            }
            .padding(.vertical, 24)
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingBottomBar {
                OnboardingPrimaryButton(title: "继续", isEnabled: agreement.isLoaded) {
                    settings.onboardingAgreementVersion = UsageAgreement.version
                    onContinue()
                }
                .accessibilityLabel("继续设置 Kazumi")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            agreement = await UsageAgreement.load()
        }
        .sheet(isPresented: $isShowingAgreement) {
            UsageAgreementSheet(loadState: agreement)
        }
    }

    /// 同意文案：整行可点，只有「使用约定」四个字用强调色。
    private var agreementLine: some View {
        Button {
            isShowingAgreement = true
        } label: {
            Text(
                "\(Text("继续即表示你已阅读并同意《"))\(Text("使用约定").foregroundStyle(KazumiPalette.accent(for: colorScheme)))\(Text("》"))"
            )
            .font(.footnote)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("继续即表示你已阅读并同意《使用约定》")
        .accessibilityHint("打开使用约定")
    }

    private func featureRow(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 29, height: 29)
                .background(
                    KazumiPalette.accent(for: colorScheme).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
