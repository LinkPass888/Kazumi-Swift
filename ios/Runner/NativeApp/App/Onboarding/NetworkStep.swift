//
//  NetworkStep.swift
//  Kazumi
//
//  引导第二屏：访问加速。初值就是当前设置，改一行写一行；不改直接「继续」也不动任何设置。
//  这一屏不给「稍后再说」：主按钮本身就是跳过。
//

import SwiftUI

struct NetworkStep: View {
    let onContinue: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                Text("访问加速")
                    .font(.largeTitle.bold())

                Text("当前设置可以直接使用，也可以现在调整。")
                    .font(.subheadline)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .padding(.top, 8)

                Text("网络")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                    .padding(.leading, 16)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("番剧条目加速")
                            .font(.body)
                        Spacer(minLength: 8)
                        Picker("番剧条目加速", selection: Binding(
                            get: { settings.enableBangumiProxy },
                            set: { settings.enableBangumiProxy = $0 }
                        )) {
                            Text("直连").tag(false)
                            Text("镜像").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 148)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    Divider().padding(.leading, 16)

                    HStack(spacing: 12) {
                        Text("图片加速")
                            .font(.body)
                        Spacer(minLength: 8)
                        Picker("图片加速", selection: Binding(
                            get: { settings.imageAcceleration },
                            set: { settings.imageAcceleration = $0 }
                        )) {
                            Text("直连").tag(ImageAcceleration.direct.rawValue)
                            Text("镜像").tag(ImageAcceleration.mirror.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 148)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    Divider().padding(.leading, 16)

                    // 规则仓库镜像放本组最后（Colo 规格 2026-11-02），与设置里同顺序。
                    RulesMirrorMenu()
                }
                .background {
                    KazumiPalette.cardShape(
                        cornerRadius: KazumiPalette.cardCornerRadius,
                        scheme: colorScheme,
                        bordered: false
                    )
                }

                Text("访问不畅时用镜像；直连不经过镜像。之后可在「网络设置」中调整。")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                    .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingBottomBar {
                OnboardingPrimaryButton(title: "继续", action: onContinue)
            }
        }
    }
}
