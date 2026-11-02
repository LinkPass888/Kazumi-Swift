//
//  AboutScreen.swift
//  Kazumi
//
//  对应 lib/pages/about/about_page.dart + credits_page.dart：
//  应用信息、检测更新、项目链接、致谢（数据来源与开源项目）。
//

import SwiftUI

struct AboutScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(AppRouter.self) private var router

    /// 检测更新状态（nil 表示还没点过）。
    @State private var updateState: UpdateState = .idle

    private enum UpdateState: Equatable {
        case idle
        case checking
        case latest
        case newer(String)
        case failed(String)

        var isChecking: Bool { self == .checking }
    }

    private var appIcon: UIImage? {
        UIImage(named: "AppIcon") ?? Bundle.main.iconImage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Group {
                        if let appIcon {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "play.rectangle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text(KazumiAppInfo.displayName)
                        .font(.title2.bold())
                    Text(String(localized: "版本 \(KazumiAppInfo.fullVersion)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "规则 API 级别 \(KazumiAppInfo.ruleAPILevel)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)

                actionRow(
                    title: "检测更新",
                    symbol: "arrow.triangle.2.circlepath",
                    detail: updateDetail,
                    isBusy: updateState.isChecking
                ) {
                    Task { await checkForUpdate() }
                }

                // LP 2541：点这一行翻一页，直接读仓库里的 CHANGELOG.md，不再把人扔到浏览器。
                actionRow(
                    title: "查看更新日志",
                    symbol: "list.bullet.rectangle",
                    detail: "看每个版本改了什么"
                ) {
                    router.push(.changelog)
                }

                VStack(spacing: 8) {
                    linkRow("项目主页", url: KazumiAppInfo.projectURL)
                    linkRow("源码仓库", url: KazumiAppInfo.sourceURL)
                    linkRow("问题反馈", url: KazumiAppInfo.issuesURL)
                    linkRow("贡献指南", url: KazumiAppInfo.contributingURL)
                    NavigationLink {
                        ThirdPartyLicensesScreen()
                    } label: {
                        licensesRow("第三方许可证")
                    }
                    linkRow("Telegram 频道", url: KazumiAppInfo.telegramURL)
                    linkRow("图标作者", url: KazumiAppInfo.iconAuthorURL)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("致谢 · 数据来源")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    linkRow("Bangumi 番组计划", url: KazumiAppInfo.bangumiIndexURL)
                    linkRow("bangumi-data（CC BY 4.0）", url: KazumiAppInfo.bangumiDataIndexURL)
                    linkRow("bangumi-mal 映射表", url: KazumiAppInfo.bangumiMALIndexURL)
                    linkRow("BangumiExtLinker（CC BY 4.0）", url: KazumiAppInfo.bangumiExtLinkerURL)
                    linkRow("AniSkip 片头片尾数据", url: KazumiAppInfo.aniSkipIndexURL)
                    linkRow("AniList 放送时刻", url: KazumiAppInfo.aniListIndexURL)
                    linkRow("弹弹play 弹幕", url: KazumiAppInfo.dandanIndexURL)
                    linkRow("trace.moe 以图搜番", url: KazumiAppInfo.traceMoeURL)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("致谢 · 开源项目")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    linkRow("mpv / MPVKit（播放内核）", url: KazumiAppInfo.mpvKitURL)
                    linkRow("Anime4K（超分辨率着色器）", url: KazumiAppInfo.anime4KURL)
                    linkRow("Fuzi（XPath 解析）", url: KazumiAppInfo.fuziURL)
                    linkRow("GPL-3.0 许可证", url: KazumiAppInfo.licenseURL)
                }

                Text("本应用与上述数据提供方无隶属关系，番剧信息与评论版权归原作者所有。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        // 顶部滚动边缘：渐进模糊（.soft）。
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Colo 3532：二级页统一用分组页底（显式按 colorScheme 取色）。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 「检测更新 / 查看日志」这类动作行：图标 + 标题 + 右侧状态。
    private func actionRow(
        title: LocalizedStringKey,
        symbol: String,
        detail: LocalizedStringKey,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    .frame(width: 28)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(
                // Colo 3532：灰底页面上的卡片不再描边，只留一块 groupedRow 实面。
                KazumiPalette.cardShape(cornerRadius: 14, scheme: colorScheme, bordered: false)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var updateDetail: LocalizedStringKey {
        switch updateState {
        case .idle: "检查是否有新版本"
        case .checking: "正在检查…"
        case .latest: "已是最新版本"
        case .newer(let version): "发现 \(version)"
        case .failed: "检查失败，可重试"
        }
    }

    // MARK: - 检测更新

    /// 查 GitHub 最新 release，与本地版本比较。
    ///
    /// 与 Flutter 版一致：拿 tag 名做版本比较（去掉前缀 v），发现更新时把
    /// 用户带到 release 页面。
    private func checkForUpdate() async {
        guard !updateState.isChecking else { return }
        updateState = .checking
        do {
            var request = URLRequest(url: KazumiAppInfo.latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                updateState = .failed("网络异常")
                return
            }
            let json = try JSONValue.decode(data)
            let tag = json["tag_name"].stringValue ?? ""
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if remote.isEmpty {
                updateState = .failed("无法解析版本")
                return
            }
            if VersionCompare.needUpdate(local: KazumiAppInfo.version, remote: remote) {
                updateState = .newer(remote)
                openURL(KazumiAppInfo.releasesURL)
            } else {
                updateState = .latest
            }
        } catch {
            updateState = .failed("检查失败，可重试")
        }
    }


    /// 进到 App 内那一页的链接行（跟 linkRow 同一套外观，右边是箭头而不是外链图标）。
    private func licensesRow(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(
            KazumiPalette.cardShape(cornerRadius: 14, scheme: colorScheme, bordered: false)
        )
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(
                KazumiPalette.cardShape(cornerRadius: 14, scheme: colorScheme, bordered: false)
            )
        }
        .buttonStyle(.plain)
    }
}

private extension Bundle {
    /// 从资产目录取应用图标（AppIcon 不是普通图片资源，退回主图标名）。
    var iconImage: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

