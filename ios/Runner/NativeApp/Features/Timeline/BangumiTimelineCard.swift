//
//  BangumiTimelineCard.swift
//  Kazumi
//
//  1:1 复刻 lib/bean/card/bangumi_timeline_card.dart：
//  * 左封面（88pt，同心圆角 16，整体外框圆角 28）、右详情；
//  * 标题 2 行，后面是「评分」与「标签 · 标签」；
//  * 底部是「xx 更新」「第 N 话」两个胶囊 + 正在追的书签图标。
//

import SwiftUI

struct BangumiTimelineCard: View {
    let item: BangumiItem
    var showRating: Bool = true
    var isWatching: Bool = false
    var compact: Bool = false
    var updateText: String?
    var currentEpisode: Int?
    var onTap: (() -> Void)?
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    /// 传 nil 或开启「减弱动态效果」时不登记转场源，退回系统默认推入。
    var zoomNamespace: Namespace.ID?

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 与 Dart 版一致的尺寸常量。
    private static let contentPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 28
    /// 与详情页折叠后的 inline 标题同号同重（17pt semibold），放大转场时视觉连续。
    private static let titleFontSize: CGFloat = 17
    private static let labelFontSize: CGFloat = 12

    var body: some View {
        Button {
            if let onTap {
                onTap()
            } else {
                router.push(.bangumiInfo(bangumiID: item.id))
            }
        } label: {
            HStack(alignment: .top, spacing: compact ? 12 : 16) {
                cover
                details
            }
            .padding(Self.contentPadding)
            .frame(maxWidth: .infinity, minHeight: compact ? 144 : 160, alignment: .top)
            // Colo 3501 §一：卡片多、每张里装着海报＋标题＋胶囊，需要「一块面」把它们
            // 框住——给实的浅灰底，不描边（白卡加发丝线看着像个空框）。
            .background(
                KazumiPalette.contentCardShape(cornerRadius: Self.cornerRadius, scheme: colorScheme)
            )
        }
        .buttonStyle(.plain)
        // 整张卡片作为缩放转场的源，放大时形变成详情页。
        .kazumiZoomSource(id: item.id, namespace: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
    }

    // MARK: - 封面

    private var cover: some View {
        let width: CGFloat = compact ? 80 : 88
        return BangumiRemoteImage(url: item.largeImage)
            .frame(width: width, height: width / BangumiPosterCard.coverAspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius - Self.contentPadding, style: .continuous))
    }

    // MARK: - 右侧详情

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.displayName)
                .font(.system(size: Self.titleFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8).frame(height: 8)

            HStack(spacing: 8) {
                if showRating {
                    ratingInline
                }
                let supporting = item.supportingText
                if !supporting.isEmpty {
                    Text(supporting)
                        .font(.system(size: Self.labelFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if let updateText {
                    pill(symbol: "clock", text: updateText)
                }
                if let currentEpisode {
                    pill(symbol: "list.number", text: String(localized: "第 \(String(describing: currentEpisode)) 集"))
                }
                if isWatching {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        .accessibilityLabel("正在追")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 评分在标签行左侧，不带胶囊背景：星标 + 分数。
    private var ratingInline: some View {
        Group {
            if item.ratingScore <= 0 {
                Text("暂无评分")
                    .font(.system(size: Self.labelFontSize))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    Text(String(format: "%.1f", item.ratingScore))
                        .font(.system(size: Self.labelFontSize, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("评分 \(String(format: "%.1f", item.ratingScore))")
            }
        }
    }

    private func pill(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: Self.labelFontSize, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(KazumiPalette.accent(for: colorScheme).opacity(0.14)))
    }
}
