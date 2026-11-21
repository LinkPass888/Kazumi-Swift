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
    /// 标题两行的高度（对齐 LibraryPosterCard：默认 34，随动态字体缩放）。
    @ScaledMetric(relativeTo: .footnote) private var titleBlockHeight: CGFloat = 34

    /// 与 constants.dart 的 StyleString.imgRadius 一致。
    private static let cornerRadius: CGFloat = 12
    /// 与 bangumi_card.dart 的 aspectRatio: 0.65 一致。
    static let coverAspectRatio: CGFloat = 0.65

    var body: some View {
        Group {
            if canTap, onTap == nil {
                NavigationLink(value: AppRoute.bangumiInfo(bangumiID: item.id)) {
                    posterContent
                }
            } else {
                Button {
                    guard canTap else { return }
                    if let onTap {
                        onTap(item)
                    } else {
                        router.push(.bangumiInfo(bangumiID: item.id))
                    }
                } label: {
                    posterContent
                }
            }
        }
        .buttonStyle(.plain)
        .kazumiZoomSource(id: item.id, namespace: zoomNamespace, cornerRadius: Self.cornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
    }

    private var posterContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            // 对齐追番页 LibraryPosterCard：12pt 常规、两行、行距 3.6、顶距 6、左对齐与海报齐平。
            Text(item.displayName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .lineSpacing(1.3 * 12 - 12)
                .multilineTextAlignment(.leading)
                .frame(height: titleAreaHeight ?? titleBlockHeight, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 6)
        }
        .frame(width: width)
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
