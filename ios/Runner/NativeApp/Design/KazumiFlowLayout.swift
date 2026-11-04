import SwiftUI

/// 流式布局：子视图按各自的理想宽度依次排开，一行装不下就换行。
///
/// `maxColumns` 是每行颗数上限（默认 `nil`＝不限，只看宽度）。分类条传 3：
/// 默认字号排 3+3，字号大了自己降成 2+2+2，任何字号都不溢出、不横滑、
/// 不截断、不缩字号——所以调用处不需要 `ViewThatFits`，也就没有「第二态
/// 还没落地」这个时刻。
///
/// 与它配套的规矩：放进来的胶囊里不许再写 `frame(maxWidth: .infinity)`——
/// 那句会让每颗拉满整行，流式排法就没有意义（概览页标签当初就是这么坏的）。
/// 行内左对齐；要让某一颗靠到整行末尾，在外面套 `frame(maxWidth: .infinity, alignment:)`。
///
/// 两处在用：追番页分类条、搜索页最近搜索那排胶囊（后者不传 `maxColumns`）。
/// 算法抄自 `InfoTabPanels.swift` 里原先私有的 `TagFlowLayout`（已在跑的同一套），
/// 抽到这里是为了两处共用一份，不再让每一处各写一遍换行。
struct KazumiFlowLayout: Layout {
    /// 每行颗数上限；`nil` 表示只看宽度。
    var maxColumns: Int?
    /// 同一行两颗之间。
    var spacing: CGFloat = 8
    /// 两行之间。
    var rowSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        var itemsInRow = 0
        for sub in subviews {
            let ideal = sub.sizeThatFits(.unspecified)
            // 单颗宽过整行时按整行宽算，交给胶囊内部折行。
            let width = min(ideal.width, maxWidth)
            let columnFull = maxColumns.map { itemsInRow >= $0 } ?? false
            if x > 0, columnFull || x + spacing + width > maxWidth {
                widest = max(widest, x)
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
                itemsInRow = 0
            } else if x > 0 {
                x += spacing
            }
            x += width
            itemsInRow += 1
            rowHeight = max(rowHeight, sub.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }
        widest = max(widest, x)
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var itemsInRow = 0
        for sub in subviews {
            let ideal = sub.sizeThatFits(.unspecified)
            let columnFull = maxColumns.map { itemsInRow >= $0 } ?? false
            if x > bounds.minX, columnFull || x + spacing + ideal.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
                itemsInRow = 0
            } else if x > bounds.minX {
                x += spacing
            }
            // 右边界内收住，不越界。
            let width = min(ideal.width, bounds.maxX - x)
            let proposal = ProposedViewSize(width: width, height: nil)
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: proposal)
            x += width
            itemsInRow += 1
            rowHeight = max(rowHeight, sub.sizeThatFits(proposal).height)
        }
    }
}
