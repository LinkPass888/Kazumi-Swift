//
//  RulesMirrorMenu.swift
//  Kazumi
//
//  规则仓库加速：点一下就地展开四条，不推页、不弹面板（Colo 规格 2026-11-02）。
//  设置 → 网络设置 →「访问加速」和引导页第二屏共用这一件。
//  展开那一刻并行测四个镜像的延迟，只在这里测，不轮询、不在收起状态偷偷测（Ato 6230）。
//

import SwiftUI

struct RulesMirrorMenu: View {
    /// 放在 Form 的 Section 里时用兄弟行（Ato 6281）：折叠那行一行，展开的四条各自一行，
    /// 不拿 VStack 包在一起。引导页那张是自绘卡片，不是列表，照旧走 VStack。
    var asListRows = false
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    /// 延迟槽固定 56（Colo 6243：44 装不下「807 ms」，四位数要 52），跟字号一起放大。
    @ScaledMetric(relativeTo: .footnote) private var latencySlot: CGFloat = 56

    @State private var isExpanded = false
    /// 四行整块淡入用：插入不动高度，只有这四行自己淡进来（Ato 6275）。
    @State private var rowsVisible = false
    /// 最近一次展开测到的延迟；收起那行显示的就是它，没测过就空着。
    @State private var latency: [RulesMirror: Measurement] = [:]

    private enum Measurement: Equatable {
        case testing
        case value(Int)
        case failed
    }

    private var selected: RulesMirror {
        RulesMirror(rawValue: settings.rulesMirror) ?? .ghProxy
    }

    /// 列表模式下行的左右留白交给 Form（系统默认 16），自己不再加一层，免得两边叠成 32。
    private var hPad: CGFloat { asListRows ? 0 : 16 }

    var body: some View {
        if asListRows {
            Group {
                headerRow
                if isExpanded {
                    Group {
                        ForEach(RulesMirror.allCases, id: \.self) { mirror in
                            optionRow(mirror)
                        }
                    }
                    .opacity(rowsVisible ? 1 : 0)
                }
            }
            // 展开、收起只换高度，别给高度隐式动画——行会上下抖（LP 6280）。
            .animation(nil, value: isExpanded)
        } else {
            VStack(spacing: 0) {
                headerRow
                if isExpanded {
                    Group {
                        ForEach(RulesMirror.allCases, id: \.self) { mirror in
                            Divider()
                                .padding(.leading, 16)
                            optionRow(mirror)
                        }
                    }
                    .opacity(rowsVisible ? 1 : 0)
                }
            }
            .animation(nil, value: isExpanded)
        }
    }

    private var headerRow: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 6) {
                Text("规则仓库加速")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(selected.shortTitle)
                    .font(.body)
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme, theme: settings.themeColor))
                // 收起那行只显短名和箭头，不显延迟（LP）。箭头固定 16 pt 槽，换符号不动布局。
                // 这一行右侧整体一个色：短名和箭头都是主题色（Ato 6276）。
                // 一颗原生单箭头：收起朝下、展开朝上，不缩不放（Ato 6306、LP 6310）。
                // 槽固定 16 pt、箭头在槽里居中，位置不动。
                // 不用 .symbolEffect(.replace)：它自带一下缩放，小图标看着像抖（Colo 6279）。
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.body)
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme, theme: settings.themeColor))
                    .frame(width: 16)
            }
            .padding(.horizontal, hPad)
            .frame(minHeight: asListRows ? 0 : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("规则仓库加速")
        .accessibilityValue(selected.shortTitle)
        .accessibilityHint("展开选择")
    }

    private func optionRow(_ mirror: RulesMirror) -> some View {
        Button {
            settings.rulesMirror = mirror.rawValue
            // 显式动画 .animation(nil, value:) 管不住（Colo 6287），收起就不带动画。
            rowsVisible = false
            isExpanded = false
        } label: {
            HStack(spacing: 6) {
                Text(mirror.shortTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(mirror.note)
                    .font(.system(size: 13))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    latencyLabel(latency[mirror])
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            KazumiPalette.accent(for: colorScheme, theme: settings.themeColor)
                        )
                        .opacity(mirror == selected ? 1 : 0)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, hPad)
            .frame(minHeight: asListRows ? 0 : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mirror.shortTitle)，\(mirror.note)\(spokenLatency(latency[mirror]))")
        .accessibilityAddTraits(mirror == selected ? .isSelected : [])
    }

    /// 延迟：测着「…」，通了「24 ms」，连不上是一颗红三角。名字和勾不上色。
    private func latencyLabel(_ measurement: Measurement?) -> some View {
        Group {
            switch measurement {
            case .failed:
                // LP 6244：连不上用警告三角，跟数字同字号同粗细、同属红色那档。
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.system(size: 14, weight: .semibold))
            case .testing:
                Text("…").foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            case let .value(ms):
                Text("\(ms) ms")
                    .monospacedDigit()
                    .foregroundStyle(ms <= 200 ? .green : (ms <= 600 ? .orange : .red))
            case nil:
                Text("")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .frame(width: latencySlot, alignment: .trailing)
    }

    /// 读屏补一句延迟，念出来的是「32 毫秒」而不是「32 ms」。
    private func spokenLatency(_ measurement: Measurement?) -> String {
        switch measurement {
        case .testing: return "，正在测试"
        case let .value(ms): return "，\(ms) 毫秒"
        case .failed: return "，连接不上"
        case nil: return ""
        }
    }

    private func toggle() {
        if isExpanded {
            // 收起：高度不带动画，整块直接收。
            rowsVisible = false
            isExpanded = false
            return
        }
        // 高度瞬间到位，只有四条整块淡入；箭头自己 0.2 秒换符号（Ato 6275）。
        isExpanded = true
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) { rowsVisible = true }
        }
        measure()
    }

    /// 四个一起发出（不排队），回来一个填一个。
    private func measure() {
        latency = Dictionary(uniqueKeysWithValues: RulesMirror.allCases.map { ($0, .testing) })
        Task {
            await withTaskGroup(of: (RulesMirror, Int?).self) { group in
                for mirror in RulesMirror.allCases {
                    group.addTask {
                        (mirror, await RulesRepoClient.shared.measureLatency(for: mirror))
                    }
                }
                for await (mirror, ms) in group {
                    latency[mirror] = ms.map(Measurement.value) ?? .failed
                }
            }
        }
    }
}
