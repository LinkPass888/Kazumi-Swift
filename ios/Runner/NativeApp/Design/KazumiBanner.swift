//
//  KazumiBanner.swift
//  Kazumi
//
//  顶部胶囊 banner：测试结果和「开关被拦下来」这类瞬时确认都走它，几秒自收、
//  右上角有叉能提前关。三页共用同一份。
//
//  形状照 LP 6404 那篇，Colo 6406 §十二 定稿、Ato 6432 改回自收：
//  底用 `.regularMaterial` + 0.5 点 separator 描边把边勾出来（LP 6394
//  「连个背景都没有」就是材料给的），再看不清才退不透明底色。
//  三种变体：success（绿、checkmark）、failure（红、感叹号＋怎么办）、
//  info（「开关被拦」这类瞬时确认）。
//

import SwiftUI

/// 页面里驱动 banner 的那份状态：一条标题、一句可空的说明、变体、怎么收。
struct KazumiBannerState {
    var title: String
    var detail: String? = nil
    var variant: KazumiBanner.Variant = .failure
    var mode: KazumiBanner.DismissMode = .automatic
}

struct KazumiBanner: View {
    enum DismissMode {
        case automatic
        case manual
    }

    enum Variant {
        case success
        case failure
        case info
    }

    let title: String
    var detail: String? = nil
    var variant: Variant = .failure
    var mode: DismissMode = .automatic
    let onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedIcon: String {
        switch variant {
        case .success: return "checkmark.circle.fill"
        case .failure, .info: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch variant {
        case .success: return KazumiPalette.successText(for: colorScheme)
        case .failure, .info: return .red
        }
    }

    private var feedback: SensoryFeedback {
        switch variant {
        case .success: return .success
        case .failure, .info: return .error
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: resolvedIcon)
                .foregroundStyle(tint)
                .font(.title3)
                .symbolEffect(.bounce, value: appeared)

            VStack(alignment: .leading, spacing: 2) {
                // 标题和说明按目录查一次：固定的那几句能翻成繁体，
                // 网络错误原文这类动态文本查不到就原样显示。
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let detail, !detail.isEmpty {
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .sensoryFeedback(feedback, trigger: appeared)
        .onAppear {
            appeared = true
            // 浮层不是控件，读屏不会自己念（Colo 6401 §十二）。
            let announcement = detail.map { "\(title)，\($0)" } ?? title
            AccessibilityNotification.Announcement(announcement).post()
            if mode == .automatic {
                Task {
                    try? await Task.sleep(for: .seconds(3.5))
                    withAnimation(.snappy) { onDismiss() }
                }
            }
        }
    }
}
