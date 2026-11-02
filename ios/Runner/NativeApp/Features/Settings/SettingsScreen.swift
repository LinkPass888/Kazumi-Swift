//
//  SettingsScreen.swift
//  Kazumi
//
//  设置首页。分组与主分支完全一致（lib/pages/settings/settings_page.dart 的 _settingsGroups）：
//    * 播放 —— 播放设置 / 弹幕设置
//    * 资源 —— 规则管理 / 下载设置
//    * 应用 —— 通知设置 / 外观与界面 / 账号与备份 / 网络设置
//    * 其他 —— 更新设置 / 存储与日志 / 关于
//
//  「账号与备份」现在是一张主页：账号与 WebDAV 各一行，设置备份直接摊开在主页里。
//  原来的「同步设置」整页已撤掉（账号、WebDAV 各回各的二级页），
//  「设置备份」也不再单独成页，因此这里不再有这两个入口。
//
//  每个分类点进去是一张二级设置页（二级页面见 SettingsDetailScreens.swift），
//  已经存在独立页面的分类（规则管理 / 存储与日志 / 关于）直接推入对应页面。
//

import SwiftUI

/// 设置分类（对应原版 _SettingsCategory）。
struct SettingsCategory: Identifiable, Hashable {
    /// 二级页面的去向。
    enum Destination: Hashable {
        case player
        case danmaku
        case pluginList
        case pluginShop
        case download
        case notification
        case theme
        case syncBackup
        case network
        case update
        case logs
        case storage
        case about
    }

    let id: String
    /// 展示用的名字。这里保持 String：SettingsCategory 要 Hashable/Sendable，
    /// LocalizedStringKey 不是，所以字面量自己包一层 String(localized:)
    /// 去查目录（Ato 6442 第一步）。
    let label: String
    let description: String
    let symbol: String
    let destination: Destination
}

/// 设置分组（对应原版 _SettingsGroup）。
struct SettingsGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let categories: [SettingsCategory]
}

extension SettingsGroup {
    /// 与主分支的分类、顺序、图标一致。
    static let all: [SettingsGroup] = [
        SettingsGroup(
            id: "playback",
            title: String(localized: "播放"),
            categories: [
                SettingsCategory(
                    id: "player",
                    label: String(localized: "播放设置"),
                    description: String(localized: "解码、渲染与播放行为"),
                    symbol: "play.rectangle.on.rectangle",
                    destination: .player
                ),
                SettingsCategory(
                    id: "danmaku",
                    label: String(localized: "弹幕设置"),
                    description: String(localized: "弹幕来源与显示效果"),
                    symbol: "captions.bubble",
                    destination: .danmaku
                ),
            ]
        ),
        SettingsGroup(
            id: "resource",
            title: String(localized: "资源"),
            categories: [
                SettingsCategory(
                    id: "plugin",
                    label: String(localized: "规则管理"),
                    description: String(localized: "番剧资源规则"),
                    symbol: "puzzlepiece.extension",
                    destination: .pluginList
                ),
                SettingsCategory(
                    id: "download",
                    label: String(localized: "下载设置"),
                    // LP 清单第四项。并发那几行这一版没有（没有下载器），
                    // 说明就不许再写「并发数」。
                    description: String(localized: "离线下载"),
                    symbol: "arrow.down.circle",
                    destination: .download
                ),
            ]
        ),
        SettingsGroup(
            id: "application",
            title: String(localized: "应用"),
            categories: [
                SettingsCategory(
                    id: "notification",
                    label: String(localized: "通知设置"),
                    description: String(localized: "追番更新提醒"),
                    symbol: "bell",
                    destination: .notification
                ),
                // LP 2594 / Ato 2597 / Colo 2595：外观与界面合成一页（Camo 2599 定名
                // 「外观与界面」），首页两个入口并成一个。
                SettingsCategory(
                    id: "theme",
                    label: String(localized: "外观与界面"),
                    description: String(localized: "主题、显示效果与启动页"),
                    symbol: "paintpalette",
                    destination: .theme
                ),
                SettingsCategory(
                    id: "syncBackup",
                    // LP 清单第八项叫「同步设置」；Ato 2026-10-24 定：只改名字，
                    // 备份那部分先留在里面不动（备份不在清单里）。
                    label: String(localized: "同步设置"),
                    description: String(localized: "追番同步与多设备同步"),
                    symbol: "icloud",
                    destination: .syncBackup
                ),
                SettingsCategory(
                    id: "network",
                    label: String(localized: "网络设置"),
                    description: String(localized: "访问加速"),
                    symbol: "globe",
                    destination: .network
                ),
            ]
        ),
        SettingsGroup(
            id: "other",
            title: String(localized: "其他"),
            categories: [
                SettingsCategory(
                    id: "update",
                    label: String(localized: "更新设置"),
                    description: String(localized: "应用与规则更新"),
                    symbol: "arrow.down.app",
                    destination: .update
                ),
                SettingsCategory(
                    id: "storage",
                    label: String(localized: "存储与日志"),
                    description: String(localized: "图片缓存与错误日志"),
                    symbol: "externaldrive",
                    destination: .storage
                ),
                SettingsCategory(
                    id: "about",
                    label: String(localized: "关于"),
                    description: String(localized: "版本与开源信息"),
                    symbol: "info.circle",
                    destination: .about
                ),
            ]
        ),
    ]
}

struct SettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            ForEach(SettingsGroup.all) { group in
                Section {
                    ForEach(group.categories) { category in
                        categoryRow(category)
                            // Colo 3481：每行显式给底色。上面把
                            // `scrollContentBackground(.hidden)` 关掉了，靠 List 默认
                            // 不一定是白（深色下也不一定是 #1C1C1E）。
                            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                    }
                } header: {
                    Text(group.title)
                }
            }
            #if DEBUG
            Section("开发验证") {
                NavigationLink {
                    KazumiIntentDebugView()
                } label: {
                    // Ato 6591：这行原来用 Label，字换行时行高只按一行算，
                    // 第二行落到卡片外、被圆角切开。改成跟本屏其他行一样的
                    // 「定宽图标＋可伸缩文字」，量出来的高度就跟着换行走。
                    HStack(spacing: 12) {
                        Image(systemName: "command")
                            // 图标字号跟本屏其他行一样钉在 18：不钉的话它跟着字号长，
                            // 撑出 30 点的图标槽，看着跟标题粘在一起。
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            .frame(width: 30)
                        Text("快捷指令验证")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityIdentifier("debug-intents")
            }
            #endif
        }
        // 顶部滚动边缘：列表顶部用渐进模糊（.soft）。
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .kazumiSettingsNavBacking()
    }

    // MARK: - 分类行

    @ViewBuilder
    private func categoryRow(_ category: SettingsCategory) -> some View {
        switch category.destination {
        // 分类行一律走路由表，不用 NavigationLink：
        // 外观页里改配色/OLED 会让整棵视图树按 id 重建一次（静态调色板要重新取值），
        // 栈状态若存在 NavigationLink 本地就会被清掉、退回设置首页；
        // 放进 AppRouter 后重建能把同一个栈原样装回来（LP 2517 的「切开关会返回上一页」）。
        case .player:
            Button { router.push(.playerSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        case .danmaku:
            Button { router.push(.danmakuSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        case .notification:
            Button { router.push(.notificationSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        case .theme:
            Button { router.push(.themeSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        case .syncBackup:
            // 主页面这一层走统一路由：以后从「我的」等别处进来也走同一条。
            Button { router.push(.syncBackup) } label: { tile(category) }
                .buttonStyle(.plain)
        case .network:
            Button { router.push(.networkSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        case .update:
            Button { router.push(.updateSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        case .download:
            Button { router.push(.downloadSettings) } label: { tile(category) }
                .buttonStyle(.plain)
        // 已经有独立页面的分类，直接推入既有路由。
        case .pluginList:
            Button { router.push(.pluginList) } label: { tile(category) }
                .buttonStyle(.plain)
        case .pluginShop:
            Button { router.push(.pluginShop) } label: { tile(category) }
                .buttonStyle(.plain)
        case .logs:
            Button { router.push(.logs) } label: { tile(category) }
                .buttonStyle(.plain)
        case .storage:
            Button { router.push(.storage) } label: { tile(category) }
                .buttonStyle(.plain)
        case .about:
            Button { router.push(.about) } label: { tile(category) }
                .buttonStyle(.plain)
        }
    }

    private func tile(_ category: SettingsCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .font(.system(size: 18, weight: .semibold)) // 图标尺寸：与列表其他分类图标的视觉大小对齐
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 30)
            // Colo 3474：说明那行删掉，行落回 44。原来每行都是「标题＋说明」两行，
            // 再叠 List 自己的一层内边距，比系统单行（44）松出一截；那些说明
            // 只是把标题换个说法，没有新信息。
            Text(category.label)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        // 不再挂 `.hitTarget44()`：List 的行本来就比 44 大（实测 52），
        // 再撑一次会自己叠一层，把行顶到 74（Colo 3489 说的「别硬加」）。
        .contentShape(Rectangle())
    }
}
