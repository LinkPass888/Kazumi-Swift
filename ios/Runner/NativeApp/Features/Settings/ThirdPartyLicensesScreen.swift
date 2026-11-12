//
//  ThirdPartyLicensesScreen.swift
//  Kazumi
//
//  对应原版「第三方许可证」页（Flutter 的 LicensePage + 注册进
//  LicenseRegistry 的条目，见 lib/services/network/bangumi_data_licenses.dart）。
//
//  此页直接展示仓库 licenses/ 下随包一起打进 App 的许可文本：
//  bangumi-data 的署名、ech_http 的依赖许可、m3e 的分词库等。
//  文件在 project.yml 里以 folder reference 打进 bundle，运行时按目录枚举。
//

import SwiftUI

/// 一份许可文本：标题、所属目录、正文。
struct LicenseDocument: Identifiable, Hashable {
    let id: String
    /// 分组用的目录名（bangumi-data / ech_http …），空串表示根目录。
    let group: String
    /// 文件名，界面上的标题。
    let title: String
    /// 包里读出来的正文；读不到时为 nil（界面上说明文件缺失，不留空白）。
    let text: String?

    /// 从 bundle 的 licenses 目录里读出全部许可文本。
    static func loadAll(bundle: Bundle = .main) -> [LicenseDocument] {
        guard let root = bundle.url(forResource: "licenses", withExtension: nil) else {
            return []
        }
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var documents: [LicenseDocument] = []
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            let parts = relative.split(separator: "/").map(String.init)
            // 证书本身（.pem）不是许可文本，不上列表。
            guard url.pathExtension.lowercased() != "pem" else { continue }
            let group = parts.count > 1 ? parts[0] : ""
            let name = parts.last ?? url.lastPathComponent
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            documents.append(
                LicenseDocument(
                    id: relative,
                    group: group,
                    title: name,
                    text: text
                )
            )
        }
        // 先按目录、再按文件名排，顺序稳定，不随文件系统变化。
        return documents.sorted {
            ($0.group, $0.title) < ($1.group, $1.title)
        }
    }
}

struct ThirdPartyLicensesScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    private let documents: [LicenseDocument]

    init(documents: [LicenseDocument] = LicenseDocument.loadAll()) {
        self.documents = documents
    }

    /// 按目录分组，目录名用界面上看得懂的说法。
    private var groups: [(title: String, documents: [LicenseDocument])] {
        let titled = Dictionary(grouping: documents, by: \.group)
        let names: [String: String] = [
            "bangumi-data": String(localized: "bangumi-data 数据署名"),
            "ech_http": String(localized: "网络库 ech_http 的依赖"),
            "": "其他"
        ]
        return titled
            .map { (names[$0.key] ?? $0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        List {
            if documents.isEmpty {
                Section {
                    Group {
                        Text("这个版本里没有打包许可文本。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    Group {
                        ForEach(group.documents) { document in
                            NavigationLink {
                                LicenseTextScreen(document: document)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.subheadline)
                                    if document.text == nil {
                                        Text("文件读不出来")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    // Colo 3532：List 的行底色显式取 groupedRow，不依赖系统动态色。
                    .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                }
            }
        }
        // Colo 3532：从系统白底改为与设置首页一致的分组页底。
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("第三方许可证")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 单份许可的正文。
struct LicenseTextScreen: View {
    let document: LicenseDocument
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            Text(document.text ?? String(localized: "这个文件在当前包里读不出来。"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                // Colo 3532：正文自己也要一块 groupedRow 实面，不靠在系统白底上。
                .background(KazumiPalette.groupedRow(for: colorScheme))
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
