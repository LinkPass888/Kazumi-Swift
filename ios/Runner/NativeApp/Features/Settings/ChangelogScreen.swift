//
//  ChangelogScreen.swift
//  Kazumi
//
//  关于页「查看更新日志」翻进来的这一页（LP 2541）：
//  直接读仓库里的 CHANGELOG.md 并排版出来，不再把人扔到浏览器。
//  仓库文件在 main 分支上，取 raw 地址；拉不到时给一句提示和「在浏览器打开」的出口。
//

import SwiftUI

struct ChangelogScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var state: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded([ChangelogSection])
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch state {
                case .loading:
                    HStack {
                        Spacer()
                        ProgressView("正在获取更新日志…")
                        Spacer()
                    }
                    .padding(.top, 40)
                case .failed(let message):
                    failureState(message)
                case .loaded(let sections):
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("更新日志")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard case .loading = state else { return }
            await load()
        }
        .refreshable { await load() }
    }

    // MARK: - 加载

    private func load() async {
        do {
            let text = try await ChangelogLoader.fetch()
            let sections = ChangelogParser.parse(text)
            guard !sections.isEmpty else {
                state = .failed(String(localized: "仓库里的更新日志是空的。"))
                return
            }
            state = .loaded(sections)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - 排版

    private func sectionView(_ section: ChangelogSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let version = section.version {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(version)
                        .font(.headline)
                    if let date = section.date {
                        Text(date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if let title = group.title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.bullets) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // 圆点是排版用的，不读给读屏。
                            Circle()
                                .fill(KazumiPalette.secondaryText(for: colorScheme).opacity(0.55))
                                .frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                                .accessibilityHidden(true)
                            Text(bullet.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Colo 3532：分组页底上的卡片用 groupedRow 实面，不描边。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KazumiPalette.groupedRow(for: colorScheme))
        )
    }

    private func failureState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("没能取到更新日志")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("在浏览器打开") {
                openURL(KazumiAppInfo.releasesURL)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 24)
    }
}

// MARK: - 数据

struct ChangelogSection: Identifiable, Equatable {
    var id: String { version ?? title ?? UUID().uuidString }
    /// `##` 那一行的版本号；文件开头还没到 `##` 时没有。
    var version: String?
    var title: String?
    var date: String?
    var groups: [ChangelogGroup] = []
}

struct ChangelogGroup: Identifiable, Equatable {
    var id: String { "\(title ?? "")#\(bullets.first?.id.uuidString ?? "")" }
    var title: String?
    var bullets: [ChangelogBullet] = []
}

struct ChangelogBullet: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// 拉仓库根目录的 CHANGELOG.md（raw，不走 API，没有限流和 token）。
enum ChangelogLoader {
    /// main 分支上的 raw 地址；换仓库只改这一处。
    static let url = URL(
        string: "https://raw.githubusercontent.com/LinkPass888/Kazumi-LiquidGlass-iOS/main/CHANGELOG.md"
    )!

    static func fetch() async throws -> String {
        var request = URLRequest(url: url)
        // 更新日志会变，别让中间的缓存一直给旧版本。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChangelogError.badStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChangelogError.notUTF8
        }
        return text
    }

    enum ChangelogError: LocalizedError {
        case badStatus(Int)
        case notUTF8

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                String(localized: "服务器返回 \(String(describing: code))。")
            case .notUTF8:
                String(localized: "文件不是 UTF-8 文本。")
            }
        }
    }
}

/// 够用的 Markdown 解析：只认文件里实际出现的 `#`、`##`、`###` 和 `- ` 项目符号。
/// 行内链接与粗体交给 AttributedString 自己处理，别自己写正则。
enum ChangelogParser {
    static func parse(_ text: String) -> [ChangelogSection] {
        var sections: [ChangelogSection] = []
        var current = ChangelogSection(version: nil, title: nil, date: nil)
        var currentGroup = ChangelogGroup(title: nil)

        func flushGroup() {
            if currentGroup.title != nil || !currentGroup.bullets.isEmpty {
                current.groups.append(currentGroup)
                currentGroup = ChangelogGroup(title: nil)
            }
        }
        func flushSection() {
            flushGroup()
            if current.version != nil || !current.groups.isEmpty || current.title != nil {
                sections.append(current)
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("### ") {
                flushGroup()
                currentGroup.title = String(line.dropFirst(4))
            } else if line.hasPrefix("## ") {
                flushSection()
                let heading = String(line.dropFirst(3))
                current = parseVersionHeading(heading)
            } else if line.hasPrefix("# ") {
                // 文件大标题：作为第一段的小标题，不当版本。
                flushSection()
                current = ChangelogSection(version: nil, title: String(line.dropFirst(2)), date: nil)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let body = String(line.dropFirst(2))
                currentGroup.bullets.append(ChangelogBullet(text: body))
            } else {
                // 段落（例如版本说明里的一整句）：当作一条没有圆点的正文。
                currentGroup.bullets.append(ChangelogBullet(text: line))
            }
        }
        flushSection()
        return sections
    }

    /// `2.4.8 (2026-10-20)` → 版本 2.4.8、日期 2026-10-20。
    private static func parseVersionHeading(_ heading: String) -> ChangelogSection {
        var version = heading
        var date: String?
        if let open = heading.firstIndex(of: "("), let close = heading.lastIndex(of: ")"), open < close {
            version = String(heading[heading.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            date = String(heading[heading.index(after: open)..<close])
        }
        return ChangelogSection(version: version, title: nil, date: date)
    }
}
