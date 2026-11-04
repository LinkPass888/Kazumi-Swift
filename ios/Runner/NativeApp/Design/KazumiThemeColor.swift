//
//  KazumiThemeColor.swift
//  Kazumi
//
//  原版可更换的配色方案（lib/bean/settings/color_type.dart）。
//
//  每套方案的颜色分两组，都取自原版 Flutter：
//
//  1. 强调色 —— `ColorScheme.fromSeed(seedColor:)` 得到的 primary：`lightPrimary`
//     是浅色外观那颗（原版 T40，深的）、`darkPrimary` 是深色外观那颗（原版 T80，
//     浅的），跟名字一致，取用时按外观直接取，没有第二层转换。
//     **强调色是固定色**：不带明暗参数的取色入口已经删掉（任务 3f66494f，LP 1112
//     「动态取色不要恢复，还是固定色」），明暗由调用点显式传进来。
//     （2026-10-23 曾经把两张表的 light/dark 对调过一版，LP 1112 说「是我搞错了，
//     这个颜色改回吧」，已全部退回，`tool/palette_probe` 的期望值也是原值。）
//  2. 配色卡片的三色 —— 原版 `lib/bean/card/palette_card.dart` 直接用
//     `Hct.from(hue, ...)` 从种子色的色相算出来的 primary / tertiary /
//     primaryContainer，外加一枚勾选圆的底色。这三色与 ColorScheme 无关，
//     原版就是这个算法，这里照搬。
//
//  表里的每个数值都由 `tool/palette_probe` 用 Flutter 自己的
//  `ColorScheme.fromSeed` 与 `material_color_utilities` 现算现比；升级
//  Flutter 或调整配色方案后跑一次那个校验，就能确认这张表没有走样。
//

import SwiftUI
import UIKit

/// 一套配色：种子色 + 强调色（浅 / 深）+ 配色卡片的三色。
struct KazumiThemeColor: Identifiable, Hashable, Sendable {
    /// 持久化用的标识（不落 UIColor，保证 Codable / 备份可读）。
    let id: String
    /// 设置页显示的名字，与原版 `colorThemeTypes` 的 label 一致。
    let title: String
    /// 原版 `colorThemeTypes` 里的种子色。
    let seed: UInt32
    /// 浅色外观下的强调色（原版 `fromSeed` 的 T40，深的那颗）。
    let lightPrimary: UInt32
    /// 深色外观下的强调色（原版 `fromSeed` 的 T80，浅的那颗）。
    let darkPrimary: UInt32
    /// 配色卡片上半块的色调（HCT：种子色相、彩度 20、明度 90）。
    let cardPrimary: UInt32
    /// 配色卡片左下块的色调（HCT：色相 +50、彩度 20、明度 85）。
    let cardTertiary: UInt32
    /// 配色卡片右下块的色调（HCT：种子色相、彩度 30、明度 50）。
    let cardPrimaryContainer: UInt32
    /// 选中时中间那枚勾选圆的底色（HCT：种子色相、彩度 30、明度 40）。
    let cardCheckbox: UInt32

    /// 默认项：原版 `Colors.green`，label 为「默认」。
    static let standard = KazumiThemeColor(
        id: "default",
        title: String(localized: "默认"),
        seed: 0xFF4CAF50,
        lightPrimary: 0xFF3B6939,
        darkPrimary: 0xFFA1D39A,
        cardPrimary: 0xFFD1E9C9,
        cardTertiary: 0xFFB6DCDA,
        cardPrimaryContainer: 0xFF5B8057,
        cardCheckbox: 0xFF436740
    )

    /// 与 lib/bean/settings/color_type.dart 的 `colorThemeTypes` 顺序、标签、色值一致。
    static let all: [KazumiThemeColor] = [
        .standard,
        KazumiThemeColor(
            id: "teal",
            title: String(localized: "青色"),
            seed: 0xFF009688,
            lightPrimary: 0xFF006A60,
            darkPrimary: 0xFF82D5C8,
            cardPrimary: 0xFFC5EAE3,
            cardTertiary: 0xFFBDD8EB,
            cardPrimaryContainer: 0xFF428278,
            cardCheckbox: 0xFF276860
        ),
        KazumiThemeColor(
            id: "blue",
            title: String(localized: "蓝色"),
            seed: 0xFF2196F3,
            lightPrimary: 0xFF36618E,
            darkPrimary: 0xFFA0CAFD,
            cardPrimary: 0xFFD2E4FE,
            cardTertiary: 0xFFDDCFEF,
            cardPrimaryContainer: 0xFF5A799F,
            cardCheckbox: 0xFF416084
        ),
        KazumiThemeColor(
            id: "indigo",
            title: String(localized: "靛蓝色"),
            seed: 0xFF3F51B5,
            lightPrimary: 0xFF515B92,
            darkPrimary: 0xFFBAC3FF,
            cardPrimary: 0xFFDEE0FF,
            cardTertiary: 0xFFEACBE7,
            cardPrimaryContainer: 0xFF6D74A2,
            cardCheckbox: 0xFF555C88
        ),
        KazumiThemeColor(
            id: "violet",
            title: String(localized: "紫罗兰色"),
            seed: 0xFF6750A4,
            lightPrimary: 0xFF65558F,
            darkPrimary: 0xFFCFBDFE,
            cardPrimary: 0xFFE9DDFF,
            cardTertiary: 0xFFF4C9DC,
            cardPrimaryContainer: 0xFF7D709F,
            cardCheckbox: 0xFF645785
        ),
        KazumiThemeColor(
            id: "pink",
            title: String(localized: "粉红色"),
            seed: 0xFFE91E63,
            lightPrimary: 0xFF8E4957,
            darkPrimary: 0xFFFFB2BE,
            cardPrimary: 0xFFFFD9DE,
            cardTertiary: 0xFFF8CCAA,
            cardPrimaryContainer: 0xFFA36670,
            cardCheckbox: 0xFF874E58
        ),
        KazumiThemeColor(
            id: "yellow",
            title: String(localized: "黄色"),
            seed: 0xFFFFEB3B,
            lightPrimary: 0xFF685F12,
            darkPrimary: 0xFFD4C871,
            cardPrimary: 0xFFECE4B3,
            cardTertiary: 0xFFBFDCC1,
            cardPrimaryContainer: 0xFF80783A,
            cardCheckbox: 0xFF675F23
        ),
        KazumiThemeColor(
            id: "orange",
            title: String(localized: "橙色"),
            seed: 0xFFFF9800,
            lightPrimary: 0xFF855318,
            darkPrimary: 0xFFFDB975,
            cardPrimary: 0xFFFFDCBE,
            cardTertiary: 0xFFD6D7AA,
            cardPrimaryContainer: 0xFF9C6D3C,
            cardCheckbox: 0xFF805527
        ),
        KazumiThemeColor(
            id: "deepOrange",
            title: String(localized: "深橙色"),
            seed: 0xFFFF5722,
            lightPrimary: 0xFF8F4C38,
            darkPrimary: 0xFFFFB5A0,
            cardPrimary: 0xFFFFDBD1,
            cardTertiary: 0xFFEBD1A3,
            cardPrimaryContainer: 0xFFA56755,
            cardCheckbox: 0xFF894F3E
        ),
    ]

    // MARK: - Material 3 容器色

    /// 一组容器色（容器底色 + 其上的前景色）。
    struct ContainerTone: Hashable, Sendable {
        var container: UInt32
        var onContainer: UInt32
    }

    /// secondaryContainer / onSecondaryContainer。
    ///
    /// 原版时间表的「xx 更新」「第 N 话」胶囊、星期选择器、追番分类标签、
    /// 详情页标签条都用这一组色（见 bangumi_timeline_card.dart 的 `_buildPill`、
    /// timeline_page.dart 的选中态）。色值同样是 `ColorScheme.fromSeed` 的产出，
    /// 由 tool/palette_probe 现算校验，不手填。
    static func secondaryTone(for id: String, dark: Bool) -> ContainerTone {
        secondaryTones[id].map { dark ? $0.dark : $0.light }
            ?? (dark ? ContainerTone(container: 0xFF3B4B38, onContainer: 0xFFD5E8CF)
                     : ContainerTone(container: 0xFFD5E8CF, onContainer: 0xFF3B4B38))
    }

    /// 按实例查 secondaryContainer（供 Palette 之外的调用点使用）。
    func secondaryTone(dark: Bool) -> ContainerTone {
        Self.secondaryTone(for: id, dark: dark)
    }

    /// 按实例查 onPrimary。
    func onPrimary(dark: Bool) -> UInt32 {
        let tones = Self.onPrimaryTones[id] ?? Self.onPrimaryTones[KazumiThemeColor.standard.id]
        guard let tones else { return dark ? 0xFF000000 : 0xFFFFFFFF }
        return dark ? tones.dark : tones.light
    }

    private static let onPrimaryTones: [String: (light: UInt32, dark: UInt32)] = [
        "default": (light: 0xFFFFFFFF, dark: 0xFF0A390F),
        "teal": (light: 0xFFFFFFFF, dark: 0xFF003731),
        "blue": (light: 0xFFFFFFFF, dark: 0xFF003258),
        "indigo": (light: 0xFFFFFFFF, dark: 0xFF222C61),
        "violet": (light: 0xFFFFFFFF, dark: 0xFF36275D),
        "pink": (light: 0xFFFFFFFF, dark: 0xFF561D2A),
        "yellow": (light: 0xFFFFFFFF, dark: 0xFF363100),
        "orange": (light: 0xFFFFFFFF, dark: 0xFF4A2800),
        "deepOrange": (light: 0xFFFFFFFF, dark: 0xFF561F0F),
    ]

    private static let secondaryTones: [String: (light: ContainerTone, dark: ContainerTone)] = [
        "default": (
            light: ContainerTone(container: 0xFFD5E8CF, onContainer: 0xFF3B4B38),
            dark: ContainerTone(container: 0xFF3B4B38, onContainer: 0xFFD5E8CF)
        ),
        "teal": (
            light: ContainerTone(container: 0xFFCCE8E2, onContainer: 0xFF334B47),
            dark: ContainerTone(container: 0xFF334B47, onContainer: 0xFFCCE8E2)
        ),
        "blue": (
            light: ContainerTone(container: 0xFFD7E3F7, onContainer: 0xFF3B4858),
            dark: ContainerTone(container: 0xFF3B4858, onContainer: 0xFFD7E3F7)
        ),
        "indigo": (
            light: ContainerTone(container: 0xFFE0E1F9, onContainer: 0xFF434659),
            dark: ContainerTone(container: 0xFF434659, onContainer: 0xFFE0E1F9)
        ),
        "violet": (
            light: ContainerTone(container: 0xFFE8DEF8, onContainer: 0xFF4A4458),
            dark: ContainerTone(container: 0xFF4A4458, onContainer: 0xFFE8DEF8)
        ),
        "pink": (
            light: ContainerTone(container: 0xFFFFD9DE, onContainer: 0xFF5C3F43),
            dark: ContainerTone(container: 0xFF5C3F43, onContainer: 0xFFFFD9DE)
        ),
        "yellow": (
            light: ContainerTone(container: 0xFFEBE3BD, onContainer: 0xFF4B472B),
            dark: ContainerTone(container: 0xFF4B472B, onContainer: 0xFFEBE3BD)
        ),
        "orange": (
            light: ContainerTone(container: 0xFFFFDCBE, onContainer: 0xFF59422C),
            dark: ContainerTone(container: 0xFF59422C, onContainer: 0xFFFFDCBE)
        ),
        "deepOrange": (
            light: ContainerTone(container: 0xFFFFDBD1, onContainer: 0xFF5D4037),
            dark: ContainerTone(container: 0xFF5D4037, onContainer: 0xFFFFDBD1)
        ),
    ]

    // MARK: - ARGB 工具

    /// 0xAARRGGBB -> SwiftUI Color。
    /// 供需要非动态色（例如配色卡片里的三块色）的调用点使用，避免每次手写 UIColor 包装。
    static func swiftUIColor(_ argb: UInt32) -> Color {
        Color(uiColor: color(argb))
    }

    /// 按持久化标识查找；未知标识回落到默认绿色。
    ///
    /// 旧版（Flutter）备份里存的是 ARGB 十六进制（见 app_theme.dart 的
    /// _storedThemeColor：'default' 或 'ff4caf50' 这样的字符串），
    /// 这里按种子色匹配回对应的配色方案。
    static func named(_ id: String) -> KazumiThemeColor {
        if let match = all.first(where: { $0.id == id }) {
            return match
        }
        if let argb = parseARGB(id), let match = all.first(where: { $0.seed == argb }) {
            return match
        }
        return Self.standard
    }

    /// 解析 "0xff4caf50" / "ff4caf50" / "#4caf50" 形式的颜色字符串。
    /// 六位按不透明处理，补上 alpha；解析不出来返回 nil。
    private static func parseARGB(_ text: String) -> UInt32? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { value.removeFirst() }
        if value.hasPrefix("0x") { value.removeFirst(2) }
        guard value.count == 6 || value.count == 8 else { return nil }
        guard let parsed = UInt32(value, radix: 16) else { return nil }
        return value.count == 6 ? 0xFF00_0000 | parsed : parsed
    }

    /// 当前选中的配色。由 `SettingsStore` 在读写设置时同步，
    /// `KazumiPalette.accent(for:)` 据此取色；只允许在主线程访问。
    @MainActor
    static var current: KazumiThemeColor = .standard

    /// 深色模式是否使用纯黑（对应原版 `SettingsKeys.oledEnhance`）。
    /// `KazumiPalette` 的背景色在 `View` 体系之外也可能被求值，因此不做 actor 隔离，
    /// 仅允许主线程写入（设置页与启动装配都在主线程）。
    nonisolated(unsafe) static var oledEnhance = false

    /// 0xAARRGGBB -> UIColor。
    static func color(_ argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }
}
