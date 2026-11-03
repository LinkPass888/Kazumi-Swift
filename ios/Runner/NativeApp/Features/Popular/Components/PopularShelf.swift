//
//  PopularShelf.swift
//  Kazumi
//
//  推荐页的一行货架（Colo 规格 §3）：
//  * 行标题 20 semibold，左边距 16，距海报 10，距上一行 24；
//  * 「更多」15 medium 强调色，**同一行里贴右 16**（LP 2743/2746 定的：
//    不贴着分组名，是同行居右），与标题同一条基线；
//  * 它在横向货架外面：页面竖着滚它跟着走，海报横滑它不动；
//  * 横向 ScrollView + LazyHStack，内容左右各 16，一张 96 宽海报 + 12 间距，
//    一屏看得见三张多一点、第四张露 53——这就是「还能往右滑」的唯一提示。
//

import SwiftUI

struct PopularShelf: View {
    let row: PopularRow
    var zoomNamespace: Namespace.ID?
    var onMore: (PopularListSource) -> Void
    /// 行标题上挂的标签菜单：只有第一行「热门番组」有（LP 3044，从封面大标题挪下来）。
    var tagOptions: [String] = []
    var onPickTag: ((String) -> Void)?
    /// 宽屏两栏时一行要露多少张：卡片跟着栏宽长，名字才装得下（Ato 验收第 3 条）。
    /// 不传就是手机那档 96。
    var tileWidth: CGFloat? = nil
    /// iPad 那两档的行标题贴行顶排（Colo 6747：货架首行墨迹落在 182）。
    /// 「更多」那颗 44 的点击区往下挂，不把标题往下挤——手机那七屏有基线锁着，不动。
    var compactHeader: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { poster in
                        PopularPosterTile(poster: poster, zoomNamespace: zoomNamespace, widthOverride: tileWidth)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            titleLabel

            Spacer(minLength: 8)

            // 没有对应列表页的行不放这颗字——点了没地方去比没有更糟。
            if let list = row.list {
                Button {
                    onMore(list)
                } label: {
                    Text("更多")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
                .hitTarget44(alignment: compactHeader ? .top : .center)
                .accessibilityLabel(String(localized: "更多\(String(describing: row.title))"))
            }
        }
        .padding(.horizontal, 16)
    }

    /// 行标题。带菜单的那一行点标题弹出标签清单（原来在封面大标题上，LP 3044 挪下来）：
    /// 第一项是行名本身（进这一类列表页），下面是那排标签。
    @ViewBuilder
    private var titleLabel: some View {
        if let onPickTag, let list = row.list {
            Menu {
                Button(row.title) { onMore(list) }
                ForEach(tagOptions, id: \.self) { tag in
                    Button(tag) { onPickTag(tag) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(row.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(row.title)
            .accessibilityHint("选标签")
        } else {
            Text(row.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
