//
//  CollectStatusMenu.swift
//  Kazumi
//
//  追番状态的菜单，详情页（`BangumiInfoScreen`）和追番页卡片
//  （`LibraryPosterCard`）共用这一份。
//
//  为什么是一份而不是两处写成一样：写两处，下次谁改一处，另一处就又分叉，
//  而且没人会立刻发现（LP 2026-10-24 说「两处菜单应该完全一样」，
//  Ato 同日定：合成一份代码，两处都用它）。
//
//  菜单里外那颗按钮不共用：详情页那颗是「符号＋字＋箭头」，卡片只有 116.7 宽，
//  只放得下一个符号。LP 说的是点开里面那份。
//

import SwiftUI

/// 追番状态菜单。
///
/// 里面是：五项状态（各带 `statusSymbol` 的图标，字用 `buttonTitle`，
/// 当前那一档带勾）→ 一条分隔线 → 红色的「取消追番」带垃圾桶，排在最后。
/// 五项是**状态名**，最后一项是**动作名**——读屏会把它们连成一张操作表念出来，
/// 最后那一项必须说清它做的是动作，不能被听成第六个状态。
struct CollectStatusMenu<LabelContent: View>: View {
    /// 当前是哪一档：菜单里那一项要带勾（Ato 2026-10-24：
    /// 原版 kazumi_glass.dart:609 当前档有记号，我们点开不能只看到六个平等选项）。
    let current: CollectType
    /// 红项是否出现。详情页传「当前已追」——没追的番没有可取消的；
    /// 卡片上的番本来就是已追，不传＝恒显示。
    var showsCancelItem: Bool = true
    /// 选了一项（`.none` 即「取消追番」）。
    let onChange: (CollectType) -> Void
    /// 外面那颗按钮，由两处各自给。
    @ViewBuilder var label: () -> LabelContent

    init(
        current: CollectType,
        showsCancelItem: Bool = true,
        onChange: @escaping (CollectType) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.current = current
        self.showsCancelItem = showsCancelItem
        self.onChange = onChange
        self.label = label
    }

    var body: some View {
        Menu {
            // 用 Picker 而不是五个 Button：Picker 会自己把当前那一档打上勾，
            // 而且这一行的图标照样画出来——「当前是哪一档」就看得见了。
            Picker(
                "追番状态",
                selection: Binding(
                    get: { current },
                    set: { onChange($0) }
                )
            ) {
                ForEach(CollectType.enabledCases) { type in
                    Label(type.buttonTitle, systemImage: type.statusSymbol)
                        .tag(type)
                }
            }
            .pickerStyle(.inline)

            if showsCancelItem {
                Divider()
                // 用词与详情页那句一样：动作是「取消追番」（把这部番移出追番列表），
                // 不是把状态改成「未追」。图标照详情页那颗垃圾桶。
                Button(role: .destructive) {
                    onChange(.none)
                } label: {
                    Label("取消追番", systemImage: "trash")
                }
            }
        } label: {
            label()
        }
        // 顺序固定：五项按 enabledCases 的次序，红项永远在最后。
        .menuOrder(.fixed)
    }
}
