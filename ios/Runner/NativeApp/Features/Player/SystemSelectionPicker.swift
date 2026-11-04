import SwiftUI

/// 「选一项」菜单的内容：交给系统 `Picker` 画。
///
/// 当前那一档的勾由系统画在**行首**，跟番剧详情页的追番菜单（`CollectStatusMenu`）
/// 一模一样（LP 4733 / 4734「其它菜单也用系统打勾」「要统一」）。
///
/// 自己拿 `Button` + `Label` 拼的话两头都堵：勾放行尾系统不画，放行首又占掉那一行
/// 唯一的图标槽（原来就是这么写的，`symbol: "checkmark"`）。所以凡是「选一项」的
/// 菜单——倍速、超分辨率、画面比例、定时关闭、选集线路、评论排序、评论集数——都走这里。
struct SystemSelectionPicker: View {
    var selection: SystemMenuButton.Selection

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { selection.options.first(where: \.isSelected)?.title ?? "" },
                set: { title in
                    selection.options.first(where: { $0.title == title })?.action()
                }
            )
        ) {
            // 用下标做身份：同一组里标题理论上不重名，但重名时 Picker 也不会把
            // 两个选项合成一个（勾会跟着跑）。
            ForEach(Array(selection.options.enumerated()), id: \.offset) { _, option in
                Text(option.title)
                    .tag(option.title)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
