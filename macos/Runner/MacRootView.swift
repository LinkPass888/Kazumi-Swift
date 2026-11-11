//
//  MacRootView.swift
//  Kazumi (macOS)
//
//  macOS 版的第一屏：侧边栏沿用 iOS 版的信息架构（推荐 / 时间表 / 历史 / 收藏 /
//  我的 / 设置），内容区先按栏目写清楚「这块移植要做什么」。
//
//  为什么不是直接复用 iOS 的 KazumiTabShell：那一套是 UITabBar + 液态玻璃标签栏，
//  在 macOS 上根本没有对应控件，硬套只会得到一块被拉扁的 iPad 界面。macOS 侧的
//  容器换成 NavigationSplitView，页面本身再逐页搬（每页搬完删掉这里的一条 status）。
//

import SwiftUI

/// 侧边栏六个栏目，与 iOS 版一一对应。
enum MacSection: String, CaseIterable, Identifiable {
    case popular
    case timeline
    case history
    case library
    case profile
    case player
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: "推荐"
        case .timeline: "时间表"
        case .history: "历史"
        case .library: "收藏"
        case .profile: "我的"
        case .player: "播放器"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .popular: "sparkles.tv"
        case .timeline: "calendar"
        case .history: "clock.arrow.circlepath"
        case .library: "books.vertical"
        case .profile: "person.crop.circle"
        case .player: "play.rectangle"
        case .settings: "gearshape"
        }
    }

    /// 这一栏在 macOS 上要单独处理的地方。移植完一栏就删一条。
    var status: String {
        switch self {
        case .popular:
            "叠压头图与横向货架要按 macOS 的窗口宽度重排，不能照搬 iPad 的三栏比例。"
        case .timeline:
            "时间表卡片宽度随窗口走；横向排布改成按列数算，不做横向滚动。"
        case .history:
            "列表直接复用；右键菜单换成 macOS 的上下文菜单（右键 / 双指点按）。"
        case .library:
            "封面墙按窗口宽度算列数，选中态换成 macOS 的强调色描边。"
        case .profile:
            "统计卡与历史条带保留；分享 / 存档相关的按钮改成菜单面板入口。"
        case .player:
            "已经能放：本地文件与直链（mpv + gpu-next/MoltenVK）、播放暂停、±10 秒、进度、音量、倍速、全屏。选集、弹幕、断流自愈还没接。"
        case .settings:
            "设置页改成 Settings 窗口那套分组表单，文案沿用 iOS 的字符串目录。"
        }
    }
}

struct MacRootView: View {
    @State private var selection: MacSection? = .popular

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(MacSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationTitle("Kazumi")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            if let selection, selection == .player {
                MacPlayerScreen()
            } else if let selection {
                MacSectionPlaceholder(section: selection)
            } else {
                ContentUnavailableView("选一栏看看", systemImage: "sidebar.left")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// 栏目占位页：写清楚这一栏在 macOS 上要做什么，别让空窗口看起来像坏了。
private struct MacSectionPlaceholder: View {
    let section: MacSection

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.symbol)
        } description: {
            VStack(spacing: 8) {
                Text(section.status)
                Text("macOS 版正在移植：规则引擎、规则模型与规则网络层已经和 iOS 共用同一份源码编译。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }
}

/// 设置窗口里的「关于」：版本号读的是 `KazumiAppInfo`，那个文件和 iOS 共用，
/// 所以这里显示的就是 Info.plist 里真实写进去的版本。
struct MacAboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Kazumi")
                .font(.title2.weight(.semibold))

            Text("版本 \(KazumiAppInfo.version)（\(KazumiAppInfo.buildNumber)）")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("基于 mpv 的番剧播放器 · macOS 版")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Link("项目主页", destination: KazumiAppInfo.sourceURL)
                .font(.footnote)
        }
        .padding(28)
        .frame(width: 380)
    }
}