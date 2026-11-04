//
//  StorageErrorView.swift
//  Kazumi
//
//  存储初始化失败页（对照 lib/pages/error/storage_error_page.dart）。
//

import SwiftUI

struct StorageErrorView: View {
    var failure: AppEnvironment.StartupFailure

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            KazumiPalette.heroBackground(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))

                Text("存储初始化失败")
                    .font(.title2.bold())

                Text(failure.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .padding(.horizontal, 24)

                Text("请检查设备剩余空间，或卸载后重新安装 Kazumi。")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
            }
            .padding(32)
            .kazumiGlassCard(cornerRadius: 28)
            .padding(24)
        }
    }
}
