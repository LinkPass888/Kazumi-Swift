//
//  ThemeColorSheet.swift
//  Kazumi
//
//  设置页「配色方案」（对照 lib/pages/settings/theme_settings_page.dart 的
//  配色对话框与 lib/bean/card/palette_card.dart）。
//  原版卡片把一个圆裁成三块：上半是 primary 色相的浅色调、左下是色相 +50
//  的 tertiary 色调、右下是 primaryContainer 色调；选中时中间再叠一枚
//  勾选圆，圆里画一个 check 图标。这里照搬这个画法。
//

import SwiftUI

struct ThemeColorSheet: View {
    @Binding var selection: KazumiThemeColor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(KazumiThemeColor.all) { color in
                        Button {
                            selection = color
                        } label: {
                            VStack(spacing: 8) {
                                KazumiPaletteCard(color: color, selected: color == selection)
                                Text(color.title)
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(color == selection ? [.isSelected] : [])
                    }
                }
                .padding(20)
            }
            // Colo 3532：sheet 的滚动区也用分组页底，与设置二级页一致。
            .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle("配色方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 配色卡片：一张卡片底 + 中间裁成三块色的圆，选中时叠一枚勾选圆。
///
/// 对照 lib/bean/card/palette_card.dart：
///   * 上半 = `Hct.from(hue, 20.0, 90.0)`
///   * 左下 = `Hct.from(hue + 50, 20.0, 85.0)`
///   * 右下 = `Hct.from(hue, 30.0, 50.0)`
///   * 勾选圆底色 = `Hct.from(hue, 30.0, 40.0)`
///
/// 原版是先画一张 Card（底色 = 主题 surface），再在里面留 10 点边距、
/// 把内容裁成圆；勾选图标用的是当时主题的 surface 色，这里对应
/// `KazumiPalette.cardSurface`。
private struct KazumiPaletteCard: View {
    let color: KazumiThemeColor
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 卡片底。
            // Colo 3532：灰底上的卡片只留 groupedRow 实面，不描边。
            KazumiPalette.cardShape(
                cornerRadius: KazumiPalette.cardCornerRadius,
                scheme: colorScheme,
                bordered: false
            )
            .frame(width: 62, height: 62)

            // 三块色拼成的圆：上半 / 左下 / 右下。
            VStack(spacing: 0) {
                KazumiThemeColor.swiftUIColor(color.cardPrimary)
                    .frame(height: 21)
                HStack(spacing: 0) {
                    KazumiThemeColor.swiftUIColor(color.cardTertiary)
                    KazumiThemeColor.swiftUIColor(color.cardPrimaryContainer)
                }
                .frame(height: 21)
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

            if selected {
                Circle()
                    .fill(KazumiThemeColor.swiftUIColor(color.cardCheckbox))
                    .frame(width: 25, height: 25)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(KazumiPalette.cardSurface(for: colorScheme))
                    }
            }
        }
        .frame(width: 70, height: 70)
    }
}

/// 设置行里的小色块。
struct KazumiThemeColorSwatch: View {
    let color: KazumiThemeColor
    var size: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(KazumiPalette.accent(for: colorScheme, theme: color))
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
