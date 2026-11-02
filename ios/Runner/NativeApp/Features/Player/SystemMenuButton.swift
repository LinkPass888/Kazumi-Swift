//
//  SystemMenuButton.swift
//  Kazumi
//
//  一颗「点了弹菜单」的按钮。
//
//  2026-10-28 换回 SwiftUI 的 `Menu`（LP：播放时可以点了，那就所有菜单都换成
//  SwiftUI，但不要主题色、跟系统黑白）。以前换 UIKit 的 `UIMenu`，是因为
//  播放中画面每秒重建、`Menu` 弹出来那份和手上的视图对不上，点了不执行；
//  现在这颗按钮是纯 SwiftUI，菜单内容直接来自手上的 `items`，不吃那个毛病。
//
//  一行菜单的结构：图标 ＋ 名字 ＋ 同一行靠右的当前值（`subtitle`）。
//  值必须看得见，又不能换行排到名字下面（LP 2026-10-28）。
//

import SwiftUI
import UIKit

struct SystemMenuButton: View {
    /// 一组「选一项」的选项（倍速、比例、线路……）：勾由系统 Picker 画在行首
    /// （LP 4733 / 4734），不再自己塞 `checkmark` 符号。
    struct Selection {
        struct Option {
            var title: String
            var isSelected: Bool
            var action: () -> Void
        }
        var options: [Option]
    }

    struct Item {
        /// 菜单项的标题。
        var title: String
        var symbol: String
        /// 图标是两颗符号叠出来的时候给这张合成图（比如弹幕设置：
        /// `captions.bubble` 打底 + 右下角小齿轮）。给了就用它，`symbol` 只当凭据。
        var symbolImage: UIImage? = nil
        /// 这一项图标单独的字号：默认跟菜单里其它项一样 17，个别项要小一点就自己给。
        var symbolPointSize: CGFloat? = nil
        var isDestructive: Bool = false
        /// 二级菜单那一行右边的小字，写当前值。
        var subtitle: String? = nil
        /// 这一项打勾。
        var isChecked: Bool = false
        /// 有二级菜单就展开成子菜单，`action` 不生效。
        var submenu: [Item]? = nil
        /// 一组「选一项」的选项：给了就展开成二级菜单，里面是系统 Picker，
        /// 当前项的那颗勾由系统画（LP 4734「要统一」）。
        var selection: Selection? = nil
        var action: () -> Void
    }

    var items: [Item] = []
    /// 整张菜单就是一组「选一项」（顶栏那颗比例 / 底栏那颗倍速）：给了就不看 `items`，
    /// 菜单里直接排开这几项，当前项系统打勾。
    var selection: Selection? = nil
    /// 按钮上画什么：给了 `title` 就写字，否则画 `symbol` 那个符号。
    var title: String?
    var symbol: String
    var accessibilityLabel: String
    /// 按钮用什么颜色：播放器里是白的，选集那块跟页面一样是正文色。
    /// 菜单内部一律跟系统黑白走，不受它影响（LP 2026-10-28）。
    var tint: Color = .white
    /// 标题右边要不要带一个小三角，表示「点开有菜单」。
    var showsChevron: Bool = false
    /// 菜单**里面**用什么颜色。默认 `.primary`：播放器的菜单一律跟系统黑白，
    /// 不受 AppRoot 那句全局 `.tint(accentColor)` 影响（LP 2026-10-28）。
    /// 剧集 / 评论区那几颗菜单是例外，传 `.accentColor`。
    var menuTint: Color = .primary
    /// 图标钮上符号的字号／字重。
    var symbolSize: CGFloat = 20
    var symbolWeight: Font.Weight = .regular
    /// 菜单被点开时回调：控制栏要靠它知道「先别收」。
    var onOpen: () -> Void = {}
    /// 带字的「选一项」钮套一颗胶囊（Colo 5439）：
    /// 选集/评论顶行那四颗（线路、页码、第几集、排序）现在是没底的一行字，
    /// 看不出是按钮。灰底、视觉高 32、命中 44，跟下载入口那颗同一套。
    var capsule: Bool = false

    var body: some View {
        Menu {
            if let selection {
                SystemSelectionPicker(selection: selection)
            } else {
                content(items)
            }
        } label: {
            buttonLabel
        }
        // 菜单内部的打勾 / 高亮跟着这颗走：不给就压回系统黑白，
        // 免得 AppRoot 的全局主题色把播放器菜单也染了（LP 2026-10-28 第 3 条）。
        .tint(menuTint)
        // 菜单要开的时候先告诉外面「别收控制栏」；用 simultaneous 手势，
        // 不抢 Menu 自己的点击。
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
        .accessibilityLabel(accessibilityLabel)
    }

    /// 二级菜单要能再套二级，所以这个函数自己调自己；
    /// 返回值写成 `AnyView`，不然 Swift 会把 opaque type 推成「自己定义自己」编不过。
    private func content(_ list: [Item]) -> AnyView {
        AnyView(
            ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                if let selection = item.selection {
                    // 二级菜单里的「选一项」：内容是一张系统 Picker，勾在行首。
                    Menu {
                        SystemSelectionPicker(selection: selection)
                    } label: {
                        rowLabel(item)
                    }
                } else if let submenu = item.submenu {
                    Menu {
                        content(submenu)
                    } label: {
                        rowLabel(item)
                    }
                } else {
                    Button(role: item.isDestructive ? .destructive : nil) {
                        item.action()
                    } label: {
                        rowLabel(item)
                    }
                }
            }
        )
    }

    /// 菜单里一行：图标 ＋ 名字 ＋ 靠右的当前值。
    @ViewBuilder
    private func rowLabel(_ item: Item) -> some View {
        // 菜单里的字和图标是我们自己画的，必须自己上色：不写就继承环境里的
        // tint（AppRoot 的全局主题色），播放器菜单就跟着变主题色了
        // （LP 2026-10-28 三遍：更多 / 收藏 / 线路这些还是主题色）。
        HStack(spacing: 8) {
            icon(item)
            Text(item.title)
            if let value = item.subtitle, !value.isEmpty {
                Spacer(minLength: 8)
                Text(value)
            }
            if item.submenu != nil {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        // 整行（符号 + 文字 + 打勾）都显式上色：菜单这一层拿不到 `Menu` 上的
        // `.tint`，不写就会继承环境里的全局主题色，播放器菜单的符号就变成主题色
        // （LP 2026-10-28：主题色的是符号）。
        .foregroundStyle(menuTint)
    }

    /// 菜单项的图标：合成图优先（弹幕设置那颗是两张符号叠的），
    /// 其次是打勾（当前项），最后才是普通符号。
    @ViewBuilder
    private func icon(_ item: Item) -> some View {
        if item.isChecked {
            Image(systemName: "checkmark")
        } else if let image = item.symbolImage {
            // 合成图（弹幕设置那颗：气泡 + 齿轮）要走 `Image(uiImage:)`，
            // 走 `systemImage:` 的话系统只认单颗符号、叠的那层会丢
            // （LP 2026-10-28「组合的弹幕设置符号没了」，Colo 同条）。
            // 模板渲染，颜色交给菜单去上，免得浅色底上一张白图看不见。
            Image(uiImage: image.withRenderingMode(.alwaysTemplate))
        } else if !item.symbol.isEmpty {
            Image(systemName: item.symbol)
                .font(.system(size: item.symbolPointSize ?? 17, weight: .regular))
        }
    }

    @ViewBuilder
    private var buttonLabel: some View {
        if let title {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, capsule ? 12 : 0)
            .frame(height: capsule ? 32 : nil)
            .background {
                if capsule {
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            // 胶囊只有 32 高，手指该点得中 44（同下载入口那颗）。
            .frame(height: capsule ? 44 : nil)
            .contentShape(Rectangle())
        } else {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: symbolWeight))
                .foregroundStyle(tint)
        }
    }
}
