//
//  BangumiPosterCard.swift
//  Kazumi
//
//  1:1 复刻 lib/bean/card/bangumi_card.dart 的 BangumiCardV：
//  竖版海报（宽高比 0.65）+ 下方中文标题（最多 3 行，12 圆角），
//  点击进入详情页。推荐页与搜索结果共用同一个卡片。
//

import SwiftUI

struct BangumiPosterCard: View {
    let item: BangumiItem
    /// 固定的海报宽度。网格里传列宽，保证每一列等宽、每一行底边对齐；
    /// 搜索结果这类自适应布局传 nil，按容器宽度铺满。
    var width: CGFloat?
    /// 标题区固定高度。网格里传 32（与原版 mainAxisExtent 的加数一致），
    /// 搜索结果这类自适应布局传 nil，按两行文字的自然高度。
    var titleAreaHeight: CGFloat?
    var canTap: Bool = true
    var onTap: ((BangumiItem) -> Void)?
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    /// 传 nil 或开启「减弱动态效果」时不登记转场源，退回系统默认推入。
    var zoomNamespace: Namespace.ID?

    @Environment(AppRouter.self) private var router

    /// 与 constants.dart 的 StyleString.imgRadius 一致。
    private static let cornerRadius: CGFloat = 12
    /// 与 bangumi_card.dart 的 aspectRatio: 0.65 一致。
    static let coverAspectRatio: CGFloat = 0.65
    /// 标题区高度：两行 15pt 文字 + 原版 EdgeInsets.fromLTRB(5, 3, 5, 1) 的上下留白。
    /// 固定住之后，海报底边到下一行海报顶边的高度是恒定的，排版不会因标题长短跳动。
    static let defaultTitleAreaHeight: CGFloat = 40

    var body: some View {
        Button {
            guard canTap else { return }
            if let onTap {
                onTap(item)
            } else {
                router.push(.bangumiInfo(bangumiID: item.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                cover
                Text(item.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .kerning(0.3)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 与 Dart 版 EdgeInsets.fromLTRB(5, 3, 5, 1) 一致。
                    .padding(.init(top: 3, leading: 5, bottom: 1, trailing: 5))
                    .frame(height: titleAreaHeight ?? Self.defaultTitleAreaHeight, alignment: .topLeading)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        // 整张卡片（封面 + 标题）作为缩放转场的源，放大时形变成详情页。
        .kazumiZoomSource(id: item.id, namespace: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
    }

    /// 封面：网格里给了固定宽度时按 2:3 算出确切高度。
    ///
    /// 用 `aspectRatio(_:contentMode: .fill)` 让 SwiftUI 自己推高度时，图片的
    /// 原始尺寸会参与布局，同一行里不同比例的封面会把行高顶得不一致；
    /// 这里在宽度已知时直接给高度，每一行的封面底边就严格对齐了。
    @ViewBuilder
    private var cover: some View {
        let image = BangumiRemoteImage(url: item.largeImage)
        if let width {
            image
                .frame(width: width, height: width / Self.coverAspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        } else {
            image
                .aspectRatio(Self.coverAspectRatio, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
    }
}
