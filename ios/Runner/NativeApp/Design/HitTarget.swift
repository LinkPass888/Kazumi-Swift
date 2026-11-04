//
//  HitTarget.swift
//  Runner
//
//  全库统一的最小可点区域：44×44。
//
//  为什么做成修饰符而不是各改各的：同一个坑已经踩了三次——17×15 的日历按钮、
//  令牌下面两个只有字高的按钮、列表行尾点不动的空白。原因都一样：控件视觉上有
//  多小都行，可点区域必须有手指那么大的下限。
//
//  用法：所有按钮、菜单、可点卡片都挂 `.hitTarget44()`。哪个可点控件没挂，
//  review 时一眼就能看出来——要么它确实不是交互元素，要么就是漏了。
//

import SwiftUI

extension View {
    /// 把可点区域撑到至少 44×44。
    ///
    /// - Parameter alignment: 撑开时内容靠哪边。整行左对齐的按钮传 `.leading`，
    ///   图标这类居中的用默认值。
    func hitTarget44(alignment: Alignment = .center) -> some View {
        frame(minWidth: 44, minHeight: 44, alignment: alignment)
            .contentShape(Rectangle())
    }
}
