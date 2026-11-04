//
//  DeepLinksScreen.swift
//  Kazumi
//
//  深链格式说明页（LP 7491）。关于页「项目主页」上面一行进来，列出 App 认的
//  几种 kazumi:// 地址。解析在 App/State/AppRouter.swift 的 KazumiLink.parse。
//  只摆格式，不放可点的链接——点开会直接跳走，反而挡住看格式。
//

import SwiftUI

struct DeepLinksScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    private struct LinkFormat: Identifiable {
        let id: String
        let name: LocalizedStringKey
        /// 这组写法认的地址，可能不止一种（bangumi / watch 打开同一页）。
        /// 纯 ASCII 的地址不在目录里，回退到键本身；带中文占位符的（番剧号/
        /// 关键词）在目录里有繁中，繁中用户才看不到简体。
        let patterns: [LocalizedStringKey]
        /// 补充说明，没有就不显示。
        var note: LocalizedStringKey?
    }

    // Camo 7496 定的字与顺序；bangumi 与 watch 打开的是同一页，合成一条写。
    private let formats: [LinkFormat] = [
        LinkFormat(
            id: "bangumi",
            name: "番剧详情",
            patterns: ["kazumi://bangumi/<番剧号>", "kazumi://watch/<番剧号>"],
            note: "两种写法打开同一页，行为相同。"
        ),
        LinkFormat(
            id: "search",
            name: "搜索",
            patterns: ["kazumi://search?query=<关键词>"],
            note: "关键词里的空格写成 +。"
        ),
        LinkFormat(
            id: "history",
            name: "观看历史",
            patterns: ["kazumi://history"]
        ),
        LinkFormat(
            id: "downloads",
            name: "下载",
            patterns: ["kazumi://downloads"]
        ),
        LinkFormat(
            id: "library",
            name: "追番",
            patterns: ["kazumi://library"],
            note: "只切到「追番」页，不往里推。"
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("在其它 App 或快捷指令里打开下面这些地址，可以直接跳到 Kazumi 的对应页面。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(formats) { format in
                        row(format)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
            // 跟设置二级页同一套外壳（Ato 7332/7334）：限宽 700 居中，行内缩 16，行宽 668。
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .kazumiSettingsNavBacking()
        .navigationTitle("深链")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ format: LinkFormat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(format.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
            ForEach(format.patterns.indices, id: \.self) { index in
                Text(format.patterns[index])
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = format.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            KazumiPalette.cardShape(cornerRadius: 14, scheme: colorScheme, bordered: false)
        )
    }
}