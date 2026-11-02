//
//  PopularPosterTile.swift
//  Kazumi
//
//  推荐页货架里的一张海报（Colo 规格 §3）：96×144、圆角 12、无遮罩无角标，
//  下面两行 12pt 居中标题。
//
//  为什么带名字：Bangumi 的封面是日文原版图，用户认的是中文译名，两样对不上
//  不是个别现象；两行 12pt 在 96 宽里装 16 个字，正好接上追番页 15 字的标准。
//

import SwiftUI

struct PopularPosterTile: View {
    let poster: PopularPoster
    var zoomNamespace: Namespace.ID?

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 辅助功能字号下：卡片宽取屏宽四成，海报跟着按比例长（不缩，Colo 6540 第二条），
    /// 标题区不再写死 34 高。默认字号仍然是 96×144 两行，规格不动。
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }
    private var tileWidth: CGFloat {
        guard isAccessibilitySize else { return Self.width }
        let screenWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        return screenWidth * 0.4
    }
    private var posterHeight: CGFloat {
        tileWidth / (Self.width / Self.height)
    }

    /// 规格 §3 的固定尺寸：宽屏也不放大，货架靠「露出更多张」传达还有内容。
    static let width: CGFloat = 96
    static let height: CGFloat = 144
    static let cornerRadius: CGFloat = 12
    /// 标题两行的高度（12pt / 行高 1.3 × 2）。
    ///
    /// 31 会裁掉第二行：两行实高 ≈ 12×1.2 + 3.6 + 12×1.2 ≈ 31.8，比 31 高，
    /// 于是第二行被切、只剩一个省略号（Colo 2781 看到的现象）。留 34 给两行腾地方。
    static let titleHeight: CGFloat = 34
    /// 一行总高：144 + 6 + 34。
    static let totalHeight: CGFloat = height + 6 + titleHeight

    var body: some View {
        Button {
            router.push(.bangumiInfo(bangumiID: poster.id))
        } label: {
            VStack(spacing: 6) {
                BangumiRemoteImage(url: poster.imageURL)
                    .frame(width: tileWidth, height: posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))

                Text(poster.displayName)
                    .font(.caption)
                    .lineSpacing(1.3 * 12 - 12)
                    // Colo 3501 §三：海报下面那行是**名字**，不是说明——用户靠它认片。
                    // 原来用次要色，等于把名字降成了附注；改主色（深色下自动变白）。
                    .foregroundStyle(.primary)
                    // Ato 6539：最大字号下只剩一个字、或者出省略号，都是缺陷。
                    // 辅助功能字号下不限行数，名字有多长就多高。
                    .lineLimit(isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: tileWidth, alignment: .top)
                    .frame(minHeight: Self.titleHeight, alignment: .top)
            }
            .frame(width: tileWidth)
        }
        .buttonStyle(.plain)
        .kazumiZoomSource(id: poster.id, namespace: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(poster.displayName)
        .accessibilityHint("打开详情")
    }
}
