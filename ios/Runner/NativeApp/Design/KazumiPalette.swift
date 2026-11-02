//
//  KazumiPalette.swift
//  Kazumi
//
//  Apple TV App 风格的暗色画布 + iOS 26 液态玻璃质感的语义色。
//  色值与渐变在浅色 / 深色下分别取色，保证海报出血位的文字始终可读。
//

import SwiftUI

enum KazumiPalette {
    /// 强调色。
    ///
    /// 取色方式与原版一致：原项目用 `ColorScheme.fromSeed(seedColor:)` 生成主题，
    /// 界面上的 primary 并不是种子色本身，而是种子色在对应亮度下的 tonal palette
    /// 里取出的一档（Material 3 的 T40 / T80，见 `KazumiThemeColor`）。
    ///
    /// 这里**显式**按 `colorScheme` 取，不走 `UIColor` 的动态解析 ——
    /// 动态色由 UIKit 的 trait collection 决定，自绘顶栏、隐藏导航栏这些场景下
    /// 它和 SwiftUI 的 colorScheme 可能对不上，同一套配色会在不同页面里取到不同的
    /// 档位。亮度档位只由 `colorScheme`（= 设置里的主题模式）决定，没有第二条路。
    ///
    /// `KazumiThemeColor.current` 是主线程隔离的全局状态（由 `SettingsStore` 写入），
    /// 所以这里标 `@MainActor`；所有调用点都在 View 的 body 里，天然满足。
    @MainActor
    static func accent(for scheme: ColorScheme) -> Color {
        accent(for: scheme, theme: KazumiThemeColor.current)
    }

    /// 指定一套配色（不跟随当前设置）的强调色：设置页那排色块用。
    @MainActor
    static func accent(for scheme: ColorScheme, theme: KazumiThemeColor) -> Color {
        KazumiThemeColor.swiftUIColor(scheme == .dark ? theme.darkPrimary : theme.lightPrimary)
    }

    /// 强调色上的前景色（对应 Material 的 onPrimary）。
    ///
    /// 数值同样取自 `ColorScheme.fromSeed` 的 onPrimary（见
    /// `KazumiThemeColor.onPrimary(dark:)`），不用黑白硬编码 ——
    /// 两档的 onPrimary 与强调色那两档是一对，要改一起改 —— 深色档的 onPrimary
    /// 会是该色相很深的一档（默认绿是 0xFF0A390F），并不是纯黑。
    @MainActor
    static func onAccent(for scheme: ColorScheme) -> Color {
        let theme = KazumiThemeColor.current
        return KazumiThemeColor.swiftUIColor(theme.onPrimary(dark: scheme == .dark))
    }

    /// secondaryContainer：时间表胶囊、星期选择器、追番分类标签的底色。
    @MainActor
    static func secondaryContainer(for scheme: ColorScheme) -> Color {
        let tone = KazumiThemeColor.current.secondaryTone(dark: scheme == .dark)
        return KazumiThemeColor.swiftUIColor(tone.container)
    }

    /// onSecondaryContainer：上面那些胶囊里的文字与图标颜色。
    @MainActor
    static func onSecondaryContainer(for scheme: ColorScheme) -> Color {
        let tone = KazumiThemeColor.current.secondaryTone(dark: scheme == .dark)
        return KazumiThemeColor.swiftUIColor(tone.onContainer)
    }

    /// 页面背景：LP 3482 要纯白（原来浅色是 #FAFAFC 近白）。
    ///
    /// 我的页与设置页另算，它们用上面的 `groupedBackground`（#F2F2F7）。
    /// 深色下不变：默认近黑（`Color(white: 0.07)`），开启 OLED 优化时纯黑。
    static func background(for scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return KazumiThemeColor.oledEnhance ? .black : Color(white: 0.07)
        }
        return .white
    }

    /// 我的页与设置页的页面底色：LP 3480 要 iOS 原生分组色。
    ///
    /// 显式按 colorScheme 取（不用 `Color(.systemGroupedBackground)` 这类动态色）：
    /// 切主题走 `.preferredColorScheme` 时，动态色由 UIKit 自己解析，跟 SwiftUI 的
    /// colorScheme 可能对不上——同一个底会在不同页面取到不同的值（同上面强调色那条）。
    /// 浅色 #F2F2F7；深色跟其它页同一套深浅规则：默认 #121212，
    /// 开了 OLED 优化才用纯黑——纯黑不是深色模式的默认值（LP 3484）。
    static func groupedBackground(for scheme: ColorScheme) -> Color {
        guard scheme == .dark else {
            return Color(red: 0.949, green: 0.949, blue: 0.969)
        }
        return KazumiThemeColor.oledEnhance ? .black : Color(white: 0.07)
    }

    /// 分组列表里一条的底色：浅色 #FFFFFF、深色 #1C1C1E（系统设置页的条目色）。
    static func groupedRow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.110, green: 0.110, blue: 0.118) : .white
    }

    /// 内容卡的底：白底之上给一块**实的浅灰面**（Colo 3501 §一）。
    ///
    /// 时间表这种「一张卡里装着海报＋标题＋胶囊」的，需要一块面把它们框住；
    /// 白底上再描一道发丝线只会看着像个空框，所以要的是这个实底，不是描边。
    /// 浅色 #F2F2F7、深色 #1C1C1E。
    static func contentCardSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.110, green: 0.110, blue: 0.118) : Color(red: 0.949, green: 0.949, blue: 0.969)
    }

    /// 白底之上卡片的描边（Colo 3483）。
    ///
    /// 页面底改成纯白之后，卡片本身也是白的，不分边就分不出「卡」和「页」。
    /// 取系统分隔线色的六成、0.5 点、不加阴影；圆角和内边距都不动。
    static func cardStroke(for scheme: ColorScheme) -> Color {
        // 系统分隔线色 = #3C3C43 @ 36%（深色下是白色 @ 24%），取它的六成。
        if scheme == .dark {
            return Color.white.opacity(0.14)
        }
        return Color(red: 0.235, green: 0.235, blue: 0.263).opacity(0.22)
    }

    /// 结果里「通了」那句用的绿（Colo 6401 §十一）。
    ///
    /// 系统绿 #34C759 在白底上对比度只有 2.2:1，正文要 4.5:1——「连接正常」会糊
    /// 在白底上。浅色压深一档到 #1B7A3D（约 5.5:1），深色仍用系统绿 #30D158。
    static func successText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.188, green: 0.820, blue: 0.345)
            : Color(red: 0.106, green: 0.478, blue: 0.239)
    }

    /// 一张卡片的底：白底＋0.5 点淡描边（Colo 3483）。
    ///
    /// 页面底改白以后，卡片自己也是白的，靠这一个函数统一分边，免得到处写两份形状。
    ///
    /// `bordered: false` 是给「灰底页面」用的（Colo 3532）：那批页面的页面底已经是
    /// `groupedBackground`，卡片只要一块实面就分得出来，再描一圈是多余的；
    /// 底色同时换成 `groupedRow`（浅白／深 #1C1C1E），跟设置页的名单同一套值。
    /// 白底白卡那批（追番、时间表、搜索、详情、推荐）保持默认的 `true`。
    static func cardShape(
        cornerRadius: CGFloat,
        scheme: ColorScheme,
        bordered: Bool = true
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(bordered ? cardSurface(for: scheme) : groupedRow(for: scheme))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(cardStroke(for: scheme), lineWidth: 0.5)
                }
            }
    }

    /// 内容卡的形状：浅灰实底、不描边（Colo 3501）。时间表的卡片用它。
    static func contentCardShape(cornerRadius: CGFloat, scheme: ColorScheme) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(contentCardSurface(for: scheme))
    }

    /// 卡片底色（对应 Material 的 surfaceContainerLow / 时间表卡片）。
    static func cardSurface(for scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return KazumiThemeColor.oledEnhance ? Color(white: 0.05) : Color(white: 0.12)
        }
        return .white
    }

    static func heroBackground(for scheme: ColorScheme) -> LinearGradient {
        // 浅色的收口色跟着页面底走（LP 3482 起是纯白），否则渐变的尽头
        // 跟页面底差一点点，会在页面下部留一道看得见的接缝。
        let base = scheme == .dark ? Color(white: 0.05) : .white
        let elevated = scheme == .dark ? Color(white: 0.12) : Color(red: 0.96, green: 0.96, blue: 0.97)
        return LinearGradient(
            colors: [elevated, base],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Hero 剧照底部与背景融合的渐隐。
    static func heroFade(for scheme: ColorScheme) -> LinearGradient {
        let base = scheme == .dark ? Color(white: 0.05) : .white
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0),
                .init(color: base.opacity(0.35), location: 0.45),
                .init(color: base.opacity(0.88), location: 0.78),
                .init(color: base, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.68) : .black.opacity(0.58)
    }

    static func tertiaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.45) : .black.opacity(0.38)
    }

    /// 播放进度条轨道。
    static func progressTrack(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.10)
    }

    /// 海报圆角（Apple TV App 的 2:3 竖版海报使用连续圆角）。
    static let posterCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 20
    static let pillCornerRadius: CGFloat = 26
}
