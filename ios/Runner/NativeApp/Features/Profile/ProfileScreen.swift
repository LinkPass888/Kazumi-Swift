//
//  ProfileScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/my/my_space_view.dart 的分组结构：
//  * 顶栏「我的」+ 右侧「全部设置」按钮；
//  * 观看足迹（看过番剧 / 观看集数）；
//  * 历史记录、离线下载（并排两块工具卡）；
//  * 规则管理（原版的异形强调卡）；
//  * 内容与偏好：规则管理 / 通知设置 / 播放设置 / 弹幕设置；
//  * 数据与应用：账号与备份 / 存储管理 / 关于 Kazumi。
//

import SwiftUI

struct ProfileScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 量到的页面尺寸（§6.0：列数与限宽都按容器算，不按整屏）。
    @State private var containerSize: CGSize = .zero

    private var isWideTier: Bool {
        containerSize.width >= 700 && containerSize.height >= 600
    }

    /// C 档：宽但矮（§六之二）。
    private var isShortTier: Bool {
        containerSize.width >= 700 && containerSize.height < 600
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                    watchStats
                    // 「规则管理」只保留这一处入口：原先这里还有一张异形强调卡直达同一页，
                    // 同屏两个入口反而让人怀疑是两个不同的功能。
                    // LP 3522：通知设置／播放设置／弹幕设置在「全部设置」里都有，这一页不再重复；
                    // 观看历史和离线下载从原来并排的两张工具卡收进这一组。
                    contentSection
                    section("数据与应用", rows: [
                        Row(symbol: "icloud", title: "同步设置", route: .syncBackup),
                        Row(symbol: "externaldrive", title: "存储与日志", route: .storage),
                        Row(symbol: "info.circle", title: "关于 Kazumi", route: .about),
                    ])
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                // 宽档内容限宽 700 居中（§6.4）。maxWidth 只封顶不撑宽，窄屏自然满宽。
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            guard size.width > 0 else { return }
            containerSize = size
        }
        // 顶部滚动边缘：渐进模糊（.soft），不额外叠材质或底色。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        // 顶栏换原生（LP 2026-10-24）：标题和设置按钮都归系统。
        // 原来那块自钉顶栏带不透明底色，会把滚动边缘的模糊整块挡住（Colo 1794 提的坑），
        // 所以这次连底色一起删掉，不再自己画任何一条栏。
        // 这一页下面挂的记录也一样：封面空的读到时补一次。
        .task {
            WatchRecordMetaBackfill.fill(recentRecords, in: library)
        }
        .navigationTitle("我的")
        // C 档大标题改 inline（§六之二）。
        .navigationBarTitleDisplayMode(isShortTier ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    // LP 2026-10-25：右上角是设置入口，用齿轮符号。
                    // 跟返回按钮一样走标签色，不用主题色。
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel("全部设置")
            }
        }
    }

    // MARK: - 头部

    // MARK: - 观看足迹

    /// Colo 3529：两张等宽白卡就是两个空盒子，合成一张统计条——
    /// 卡高跟组里一行一样 52，里面左右两块各占一半，一行里「数字 名字」。
    private var watchStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("观看足迹")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 20))
            layout {
                stat(value: "\(library.entries.count)", title: "看过番剧")
                stat(value: "\(library.history.count)", title: "观看集数")
            }
            // 写死的 52 高在辅助功能字号下会把名字截成「看…」，改成最小高、装不下自己长。
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }

    /// 一块：数字 24 semibold 主题色，隔 6 点接名字 13 次要色，整块左对齐、左留 14。
    private func stat(value: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(.title2, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        // 两块各自念成一件事：「12，看过番剧」。
        // 数字用 verbatim、名字用 Text(title) 各自解析，不能拼成同一个字符串——
        // 那样本地化名会被当成参数描述念出来。iOS 26 弃用了 `Text + Text`，改用插值合并。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(verbatim: value + "，"))\(Text(title))"))
    }

    // MARK: - 内容与偏好

    /// 规则管理 / 离线下载 / 观看历史三行，最后一行底下挂最近看过的三张海报。
    /// 组名 Camo 3523 定的「内容管理」：原来那个里的「偏好」跟着通知、播放、弹幕一起删了，
    /// 剩下这三行都是在这台设备上攒下的东西。
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容管理")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                rowButton(symbol: "puzzlepiece.extension", title: "规则管理") {
                    router.push(.pluginList)
                }
                Divider().padding(.leading, 54)
                rowButton(symbol: "arrow.down.circle", title: "离线下载") {
                    router.push(.download)
                }
                Divider().padding(.leading, 54)
                rowButton(symbol: "clock.arrow.circlepath", title: "观看历史") {
                    router.push(.history)
                }
                // LP 3534／Colo 3536：一个番都没有的时候，「暂无观看历史」留在这一行下面，
                // 但左边缘要跟「观看历史」四个字对齐——左起 54（14 卡片内边距 + 28 图标 + 12 间距），
                // 跟上面那条分隔线同一条竖线。上 8 下 12，13 号次要灰。
                if recentRecords.isEmpty {
                    emptyHistoryNote
                } else {
                    Divider().padding(.leading, 54)
                    recentStrip
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }

    /// 空态那句，左边缘跟「观看历史」四个字对齐（Colo 3536）。
    private var emptyHistoryNote: some View {
        HStack {
            Text("暂无观看历史")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        // 54 = 卡片左右内边距 14 + 图标 28 + 图标与标题间距 12。
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// 最近看过的三张：按时间倒序取前三个，同一部番只出现一次。
    private var recentRecords: [WatchRecord] {
        var seen = Set<Int>()
        var picked: [WatchRecord] = []
        for record in library.history.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard seen.insert(record.bangumiID).inserted else { continue }
            picked.append(record)
            if picked.count == 3 { break }
        }
        return picked
    }

    /// 观看历史那一行底下最近的几条，竖放（LP 3557、Colo 3559）：
    /// 番名普遍长，横放三张一截断就认不出是哪部，比高一点更糟。
    /// 点一条直接播那一集（LP 2026-10-27，跟 main 一样），不进详情页。
    ///
    /// 卡片的信息和排版照「观看历史」页那张抄（Camo 2026-11-11）：带播放 / 重看角标的
    /// 封面、番名两行、集数行、「看到 12:34」、进度条、最后一行「规则名 · 时间」。
    /// 尺寸不能跟那一页一样大：这里按封面比例缩小——封面 64 宽（历史页 84），
    /// 行高就是封面高度，内边距、行距、字号跟着小一档。
    /// **字重和颜色仍用这一页原来的**——正文 regular、次要信息 secondary，
    /// 不搬历史页那个加粗标题和主题色进度文案。
    /// 同一部番只留最近看的那一条来源（按 `updatedAt` 倒序，第一条就是它）。
    private var recentStrip: some View {
        VStack(spacing: 0) {
            ForEach(Array(recentRecords.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    // 条带里面的分隔线跟文字块对齐（12 + 封面 64 + 12 = 88），
                    // 不跟组里其它分隔线一样左起 54——那样会从封面中间穿过去。
                    Divider().padding(.leading, 88)
                }
                recentRow(record)
            }
        }
    }

    /// 一条：封面 64 宽在左，右边番名、集数、「看到 12:34」、进度条、
    /// 「规则名 · 时间」；右边这一列至少撑满封面高度，进度条和时间落在这一条底部。
    private func recentRow(_ record: WatchRecord) -> some View {
        Button {
            // 跟「观看历史」页同一份路由参数：带线路、带「接着看」标记、带卡片上
            // 那条规则名。少了 `resumeRule`，离线时本地文件就查不到——播放器的
            // `localFile` 是按「番剧 + 规则名」取的，下载好的集照样要联网（#27）。
            router.push(.player(
                bangumiID: record.bangumiID,
                episode: record.episodeNumber,
                source: nil,
                resumeRoad: record.roadIndex,
                resumeFromHistory: true,
                resumeRule: record.sourceRuleName
            ))
        } label: {
            HStack(spacing: 12) {
                recentPoster(record)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.bangumiName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(episodeLine(for: record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // 「看到 12:34」单独一行，在集数正下方（Colo 4895）。
                    // 没有进度就整行不出现；颜色用这一页的次要灰，不用主题色。
                    if let position = record.positionText {
                        Text(position)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }

                    Spacer(minLength: 0)

                    KazumiGlassProgressBar(
                        progress: record.fraction,
                        tint: KazumiPalette.accent(for: colorScheme)
                    )

                    // 底部照观看历史页合成一条：规则名 · 时间。
                    Text(metaLine(for: record))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 用 minHeight 而不是定高：字号放大时这一列自己长高，不会压到下一行。
                .frame(minHeight: Self.recentCoverWidth / BangumiPosterCard.coverAspectRatio, alignment: .top)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(verbatim: "\(record.bangumiName)，\(episodeLine(for: record))，\(record.positionText ?? String(localized: "继续观看"))")
        )
        .accessibilityAddTraits(.isButton)
    }

    /// 封面：宽高都给死，圆角与海报卡同一套。右下角那颗小三角是「接着看」的意思，
    /// 看完的换成「重看」（跟观看历史页同一颗）。
    private func recentPoster(_ record: WatchRecord) -> some View {
        BangumiRemoteImage(url: record.imageURL)
            .frame(width: Self.recentCoverWidth, height: Self.recentCoverWidth / BangumiPosterCard.coverAspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                // 角标也按封面比例缩：历史页那张是 26 / 11 / 6，这里 64 ÷ 84 折下来是 20 / 9 / 5。
                Image(systemName: record.isFinished ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(5)
            }
    }

    /// 封面宽：跟历史页那张（84）比小一档，行高按同一个封面比例算（64 ÷ 0.65 ≈ 98）。
    private static let recentCoverWidth: CGFloat = 64

    /// 底部那条：规则名 · 时间（Colo 4895）。规则名为空就只写时间。
    private func metaLine(for record: WatchRecord) -> String {
        let time = KazumiTimeText.relative(record.updatedAt)
        let rule = record.sourceRuleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return rule.isEmpty ? time : "\(rule) · \(time)"
    }

    /// 「第 1 集」或「第 1 集 · 标题」，跟观看历史页同一份写法。
    private func episodeLine(for record: WatchRecord) -> String {
        let number = String(localized: "第 \(record.episodeNumber) 集")
        let title = record.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // 老记录里的集标题是「第 N 话」（LP 4824「已经记录的就算了」，不迁移数据），
        // 跟新的「第 N 集」并排比一次，别把同一句话拼成「第 3 集 · 第 3 话」。
        let legacy = String(localized: "第 \(record.episodeNumber) 话")
        return title.isEmpty || title == number || title == legacy ? number : "\(number) · \(title)"
    }

    private func rowButton(
        symbol: String,
        title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            // 单行 52：正文那行实测 20.3，上下各 16 补到 52。
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组列表

    private struct Row: Identifiable {
        let id = UUID()
        var symbol: String
        var title: LocalizedStringKey
        var route: AppRoute
    }

    private func section(_ title: LocalizedStringKey, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowButton(symbol: row.symbol, title: row.title) {
                        router.push(row.route)
                    }
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }
}
