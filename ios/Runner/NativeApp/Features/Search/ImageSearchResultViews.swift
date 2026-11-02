//
//  ImageSearchResultViews.swift
//  Kazumi
//
//  对应 lib/pages/search/image_search_widgets.dart 的 _BestMatch / _OtherMatch / _TraceFrame。
//

import SwiftUI

/// 16:9 的匹配画面；加载失败或没有地址时显示占位图标。
struct RemoteFrameImage: View {
    let url: URL
    var height: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(KazumiPalette.cardSurface(for: colorScheme))
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                    @unknown default:
                        placeholder
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(.tertiary)
    }
}

/// 对应 _TraceFrame：结果卡片内的 16:9 画面。
struct TraceFrame: View {
    let result: TraceResultItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(KazumiPalette.cardSurface(for: colorScheme))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url = result.frameURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            placeholder
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel(String(localized: "\(String(describing: result.displayTitle))的匹配画面"))
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(.tertiary)
    }
}

/// 对应 _BestMatch：相似度最高的一条，带两个操作按钮。
struct BestMatchCard: View {
    let result: TraceResultItem
    let onSelect: () -> Void
    let onPreview: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// 卡片自己的宽度：够 600 才左右分栏（照 main），不够就上下排。
    @State private var cardWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("相似度最高")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "\(String(describing: result.similarityText)) 相似"))
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 0)
                }
                Text(result.displayTitle)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            // 按卡片自己的宽度分支，照 main 的 600 阈值（Colo 3112）：
            // 原来用 ViewThatFits，画面那侧是弹性宽度、永远「装得下」，
            // 于是手机上也被判成左右两栏——画面挤在左边、文字挤在右边，就是那个错位。
            if cardWidth >= 600 {
                HStack(alignment: .top, spacing: 0) {
                    // 并排时画面给死宽度（卡宽的 45%，Colo 3119）：不给的话它按理想尺寸缩，
                    // 又会被压成左边一条，跟手机那次是同一个毛病。
                    TraceFrame(result: result)
                        .frame(width: max(200, cardWidth * 0.45))
                        .padding(.leading, 12)
                        .padding(.bottom, 12)
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // 画面跟下面的文字同一条左边（Colo 3102）。
                    TraceFrame(result: result)
                        .padding(.horizontal, 20)
                    details
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(CardWidthKey.self) { cardWidth = $0 }
        // 跟下面「其他相似片段」那几行同一种底：cardSurface、无描边、圆角 16（Colo 3102）。
        .background(
            KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                metadata(icon: "movieclapper", label: result.episodeText)
                metadata(icon: "clock", label: result.timeRangeText)
            }
            .padding(.top, 16)

            if result.isLowSimilarity {
                Text("相似度偏低，建议对照画面，或换一张截图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            HStack(spacing: 10) {
                Button(action: onSelect) {
                    Label("搜索这部番", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(KazumiPalette.accent(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let video = result.previewURL {
                    Button {
                        onPreview(video)
                    } label: {
                        Label("预览片段", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.top, 16)
        }
        .padding(20)
    }

    private func metadata(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(label)
                .font(.footnote)
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

/// 对应 _OtherMatch：其余相似片段，点击即用该番名搜索。
struct OtherMatchRow: View {
    let result: TraceResultItem
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            // 缩略图 120 宽、跟文字列顶部对齐（Colo 3102）：原来 104 且居中，上下各空一截。
            HStack(alignment: .top, spacing: 14) {
                TraceFrame(result: result)
                    .frame(width: 120)

                VStack(alignment: .leading, spacing: 6) {
                    Text(result.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text(String(localized: "\(String(describing: result.episodeText)) · \(String(describing: result.similarityText)) 相似"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(result.timeRangeText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // 撑满行高再居中：行是顶部对齐的，不这样箭头会贴在文字第一行上（Colo 3115）。
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            // 水平 20 跟上面「相似度最高」那张对齐，两种卡的封面左边缘在同一条线上（Colo 3115）。
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "搜索 \(String(describing: result.displayTitle))"))
    }
}

/// 量卡片宽度用。
private struct CardWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
