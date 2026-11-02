//
//  BangumiInfoScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/info/info_page.dart + bangumi_info_card.dart：
//  * 顶栏：返回键 + 左对齐的大标题（字重字号与推荐页「热门番组」一致）+ 右上角「更多」；
//  * 封面与条目信息直接压在模糊的封面背景上，不再是背景下面另起一块；
//  * 条目信息：放送开始 / 放送时间（星期菜单 + 具体时刻 + 时间表开关）/ 更新进度 / 评分 / 排名，
//    最下面一行是收窄的追番状态菜单；
//  * 横向排列的「概览 / 吐槽 / 角色 / 关联 / 制作人员」标签；
//  * 别名不是详情页的区块，它在片源弹窗里当检索词用（见 SourceSheet）。
//

import Photos
import SwiftUI
import UIKit

struct BangumiInfoScreen: View {
    var bangumiID: Int
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    /// 传 nil 或开启「减弱动态效果」时退回系统默认推入。
    var zoomNamespace: Namespace.ID?

    @State private var controller: InfoController?
    /// 详情页第一次进来没拉到数据：不再画一张空页，改为给「重新加载」（LP 2996）。
    @State private var didFailToLoad = false
    @State private var isShowingSources = false
    @State private var selectedTab: InfoTab = .overview
    @State private var scrollOffset: CGFloat = 0
    @State private var toastMessage: String?
    /// 添加到时间表但番剧还没标成在看时，先弹确认。
    @State private var pendingTimelineItem: BangumiItem?
    /// 刚才是从选源面板点进播放页的：返回时要记得把面板放回来。
    @State private var returnToSourcesAfterPlayer = false
    /// 推播放页之前的栈深，用来判断已经退回详情页了。
    @State private var depthBeforePlayer = 0
    @State private var sourceNavigationRevision: UInt = 0

    /// 当前所在 Tab 的导航栈深度。四个 Tab 都算上，页面不关心自己在哪个 Tab。
    private var navigationDepth: Int {
        router.popularPath.count + router.timelinePath.count
            + router.collectPath.count + router.myPath.count
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                content(controller)
            } else if didFailToLoad {
                failedView
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        // 与列表卡片同 ID、同命名空间：从卡片点进来时原地放大，返回时收回去。
        // 找不到对应源视图（如从播放页推入）时系统自动回落到默认转场。
        .kazumiZoomDestination(id: bangumiID, namespace: zoomNamespace)
        // 自绘顶栏会连带关掉系统返回手势，这里把它接回来。
        .background {
            KazumiSwipeBackEnabler()
                .frame(width: 0, height: 0)
        }
        .task {
            if controller == nil {
                await load()
            }
        }
        .onChange(of: router.externalModalDismissalRevision) { _, _ in
            isShowingSources = false
        }
        .onChange(of: router.externalNavigationRevision) { _, _ in
            returnToSourcesAfterPlayer = false
            pendingTimelineItem = nil
            controller?.closeSourceSearch()
        }
        .onChange(of: bangumiID) { _, _ in
            controller = nil
            didFailToLoad = false
        }
    }

    /// 第一次进来没拉到数据：说清楚，并给一个能再来一次的按钮。
    private var failedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            Text("详情没能加载")
                .font(.system(size: 17, weight: .semibold))
            Text("网络好像不太顺，点一下重新加载。")
                .font(.system(size: 14))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
            Button {
                didFailToLoad = false
                Task { await load() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule(style: .continuous).fill(KazumiPalette.accent(for: colorScheme)))
                    .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 内容

    private func content(_ controller: InfoController) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // ScrollViewReader 包在外面：展开评论的回复时要喊这个列表滚一滚（Colo 3366）。
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 标题与 hero 是一个紧凑的整体：两者间距 12，与下方分隔用 18。
                        VStack(alignment: .leading, spacing: 12) {
                            // 展开态 28pt bold。不再主动淡出：让它随内容滚进顶部模糊里，
                            // 只在最后一小段行程里收掉，顶栏那份同一时间接上（见 titleRevealProgress），
                            // 避开两份标题同时半透明重叠的那几帧。
                            Text(controller.item.displayName)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(1 - titleRevealProgress)

                            hero(controller)
                        }

                        tabStrip(controller)
                        tabContent(controller, onExpandComment: { id in
                            // 在上半部往下展开、在下半部往上展开：都把这条滚到中间，
                            // 展开出来的回复就不会跑出屏幕外。
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        })
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
                // 顶部渐进模糊：只作用顶部那一条，不叠材质、不加底色。
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y)
                } action: { _, newValue in
                    scrollOffset = newValue
                }
                // 顶栏吸附在安全区（不再是 ScrollView 的兄弟节点）：内容从它下方滚过去，
                // 顶部模糊才盖得住标题那一行；否则模糊只能铺在顶栏下面，内容滚上来是硬切一刀。
                .safeAreaInset(edge: .top, spacing: 0) {
                    topBar(controller)
                }
            }

            startPlayingButton
        }
        .overlay(alignment: .top) { toastView }
        // 出入场由值驱动：状态变化本身不在动画事务里，只有结果被动画化。
        .animation(.easeOut(duration: 0.2), value: toastMessage)
        // 导航标题给无障碍与系统用；页面内的 inline 那份因此不再重复朗读。
        .navigationTitle(controller.item.displayName)
        .sheet(isPresented: $isShowingSources) {
            let current = controller
            // 点结果：先关面板、再往右推进播放页（LP 3273 / Colo 3275）。
            // 返回时下面 onChange 把面板带着原来那批结果放回来，不重新检索。
            SourceSheet(
                controller: current,
                onPlay: { pluginName, result in
                    guard router.pendingExternalLink == nil else { return }
                    sourceNavigationRevision = router.externalNavigationRevision
                    isShowingSources = false
                    returnToSourcesAfterPlayer = true
                    depthBeforePlayer = navigationDepth
                    // 从哪一集接着看：按「这部剧 + 这条规则名」查历史，记着第几集、
                    // 哪条线路就从哪里起（LP 4822 / 4844，跟 main 的 _initOnlineMode 一致）。
                    let point = resumePoint(for: current.item.id, pluginName: pluginName)
                    router.push(
                        .player(
                            bangumiID: current.item.id,
                            episode: point?.episode ?? 1,
                            source: PlaybackSource(
                                pluginName: pluginName,
                                itemName: result.name,
                                // 原样传 src：接口模式的规则拿它当 vod_id，拼成网址就查不到剧集。
                                detailURL: result.src,
                                directMediaURL: MediaUtility.isMediaURL(result.src) ? result.src : nil
                            ),
                            resumeRoad: point?.road,
                            resumeFromHistory: true,
                            resumeRule: nil
                        )
                    )
                },
                // 空面板上的「去规则仓库添加」：不传这个就只有 dismiss，按钮点了不跳（LP 2026-10-29）。
                // 跟点结果一样先收面板，回来再把面板开一次——装完规则正好接着选源。
                onOpenRuleShop: {
                    guard router.pendingExternalLink == nil else { return }
                    sourceNavigationRevision = router.externalNavigationRevision
                    isShowingSources = false
                    returnToSourcesAfterPlayer = true
                    depthBeforePlayer = navigationDepth
                    router.push(.pluginShop)
                }
            )
        }
        // 从播放页返回：把面板放回来。栈深回到推播放页之前就说明回来了。
        .onChange(of: navigationDepth) { _, newDepth in
            guard sourceNavigationRevision == router.externalNavigationRevision,
                  router.pendingExternalLink == nil,
                  returnToSourcesAfterPlayer, newDepth <= depthBeforePlayer else { return }
            returnToSourcesAfterPlayer = false
            isShowingSources = true
        }
        .confirmationDialog(
            "添加到时间表",
            isPresented: Binding(
                get: { pendingTimelineItem != nil },
                set: { if !$0 { pendingTimelineItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("标记为在看并添加") {
                guard let item = pendingTimelineItem else { return }
                pendingTimelineItem = nil
                markWatchingAndEnableTimeline(item)
            }
            Button("取消", role: .cancel) { pendingTimelineItem = nil }
        } message: {
            Text("时间表只放「在看」的番。要标记为在看，再添加到时间表吗？")
        }
    }

    // MARK: - 顶栏

    /// 返回键 + 居中的折叠标题 + 更多菜单。
    ///
    /// 滚动内容顶部是 17pt semibold 的标题（与时间表卡片番剧名同号同重）；
    /// 往上滑到阈值后，这里出现居中 17pt semibold 的一份，与返回键同行。
    /// 两份同号同重，衔接时不像换了一个控件。
    ///
    /// 不再给顶栏加 `.ultraThinMaterial` 背景条：滚动时那一条灰底会横在
    /// 内容上方，与页面背景断开。
    /// 展开态标题 → 顶栏居中标题的交接进度（0…1），两处共用同一个值。
    /// 只用透明度接力，不给顶栏那份加位移或缩放，避免两份同时在视野里跳。
    ///
    /// 交接只发生在最后 10pt：大标题先随内容滚进顶部模糊里（不主动淡出），
    /// 滚过自身高度后顶栏那份在 10pt 行程内接上，中间不会有两份都半透明的帧。
    private var titleRevealProgress: CGFloat {
        let handoffStart: CGFloat = 30
        let travel: CGFloat = 10
        return min(1, max(0, (scrollOffset - handoffStart) / travel))
    }

    private func topBar(_ controller: InfoController) -> some View {
        let progress = titleRevealProgress
        return HStack(spacing: 10) {
            barButton(symbol: "chevron.left", label: "返回") {
                dismiss()
            }

            // 中间那段弹性空间：标题在弹性宽度里居中，且始终占位，
            // 折叠与否都不影响两侧按钮的位置。
            Text(controller.item.displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .opacity(progress)
                .accessibilityHidden(true)

            Menu {
                Button {
                    copyTitle(controller)
                } label: {
                    Label("复制标题", systemImage: "doc.on.doc")
                }
                Button {
                    saveCover(controller)
                } label: {
                    Label("保存封面", systemImage: "square.and.arrow.down")
                }
                Button {
                    openExternally(controller)
                } label: {
                    Label("外部打开", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(
                        width: KazumiGlassMetrics.barButtonSize,
                        height: KazumiGlassMetrics.barButtonSize
                    )
            }
            .buttonStyle(.plain)
            .kazumiGlassCapsule(interactive: true)
            .accessibilityLabel("更多")
        }
        .padding(.leading, KazumiGlassMetrics.barEdgeInset)
        .padding(.trailing, KazumiGlassMetrics.barEdgeInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// 顶栏圆形玻璃按钮，尺寸与间距取自 KazumiGlassMetrics。
    private func barButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(
                    width: KazumiGlassMetrics.barButtonSize,
                    height: KazumiGlassMetrics.barButtonSize
                )
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .accessibilityLabel(label)
    }
}

// MARK: - 封面 + 条目信息

extension BangumiInfoScreen {
    /// 封面与条目信息一起压在模糊封面上（原版 _InfoHeaderBackground 的做法）。
    ///
    /// 尺寸固定（对齐 main 的 bangumi_info_card.dart）：封面宽 = (行宽 - 16) / 2，
    /// 高 = 宽 / 0.65，hero 高 = 封面高 + 上下各 12 的 padding。长标题 / 短标题
    /// 都不会把 hero 撑高，背景模糊层也随之同尺寸。
    private func hero(_ controller: InfoController) -> some View {
        let height = heroCoverHeight
        return HStack(alignment: .top, spacing: 16) {
            cover(controller.item)
            infoColumn(controller, coverHeight: height)
        }
        .padding(12)
        // 同上：封面高是下限，不是上限；信息列长高了整块跟着长。
        .frame(minHeight: height + 24, alignment: .top)
        .background { backdrop(controller) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// 背景：同一张封面放大打模糊，再叠一层页面底色把它压成「磨砂」，
    /// 保证浅色 / 深色下上面的文字都读得清。
    private func backdrop(_ controller: InfoController) -> some View {
        BangumiRemoteImage(url: controller.item.largeImage)
            .blur(radius: 26)
            .overlay {
                KazumiPalette.background(for: colorScheme)
                    .opacity(colorScheme == .dark ? 0.62 : 0.74)
            }
    }

    private func cover(_ item: BangumiItem) -> some View {
        BangumiRemoteImage(url: item.largeImage)
            .frame(width: heroCoverWidth, height: heroCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 封面宽度：`(行宽 - 16) / 2`。
    ///
    /// 原生详情页信息列是纯竖排、没有 main 的评分透视图，iPhone 上永远是 /2。
    private var heroCoverWidth: CGFloat {
        let screenWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        let rowWidth = min(screenWidth - 32, 950)
        return max(84, (rowWidth - 16) / 2)
    }

    private var heroCoverHeight: CGFloat {
        heroCoverWidth / BangumiPosterCard.coverAspectRatio
    }

    /// 条目信息列：高度钉死为封面高，文字区在上、追番按钮贴底（对应 main 的
    /// spaceBetween）。文字放不下时整块等比缩小，不靠省略号截断。
    private func infoColumn(_ controller: InfoController, coverHeight: CGFloat) -> some View {
        let item = controller.item
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                infoLine(label: "放送开始", value: item.airDate.isEmpty ? "未知" : item.airDateText)

                broadcastRow(controller)

                // 更新进度：紧跟在「放送时间」之后。
                if let progress = updateProgress(controller) {
                    infoLine(label: "更新进度", value: progress)
                }

                // 评分行跟着设置里那颗「显示评分」走（LP 2026-10-25）。
                if settings.showRating, item.ratingScore > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("评分")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            Text(String(format: "%.1f", item.ratingScore))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            if item.votes > 0 {
                                Text("(\(item.votes) 人)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if item.rank > 0 {
                    infoLine(label: "Bangumi Ranked:", value: "#\(item.rank)")
                }
            }
            // 文字区压缩优先级最高：整块等比缩，宁可字小一点。
            .minimumScaleFactor(0.75)
            .layoutPriority(1)

            Spacer(minLength: 6)

            // 追番按钮钉在信息列底部，状态只换文案与图标，不换位置与尺寸。
            collectMenu(controller)
                .frame(minWidth: 96, minHeight: 36, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // 至少和封面一样高，行多了往下长（Colo 3013）：行数是变的——有排名没排名、
        // 有更新进度没更新进度，钉死等于赌行数不变，多出来那行会被挤没。
        .frame(minHeight: coverHeight, alignment: .topLeading)
    }

    /// 「放送时间」：星期菜单 + 具体时刻 + 时间表开关。
    private func broadcastRow(_ controller: InfoController) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("放送时间")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                weekdayMenu(controller)

                // 具体时刻来自 bangumi-mal 的季度表，取不到就不显示。
                if let time = controller.airTime {
                    Text(time)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }

                Button {
                    toggleTimeline(controller)
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            isInTimeline(controller) ? KazumiPalette.accent(for: colorScheme) : Color.secondary
                        )
                        // 图标本身只有 17×15，点不中很容易被当成“点了没反应”或误触旁边。
                        // 撑到 44×44 的可点区域，再用负 padding 把布局尺寸收回去，
                        // 这样命中范围变大、这一行的高度不变。
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .padding(-13.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isInTimeline(controller) ? "从时间表移除" : "添加到时间表")
            }
        }
    }

    /// 放送星期菜单：七项，收窄成一颗小胶囊（与推荐页的标签菜单同一处理）。
    private func weekdayMenu(_ controller: InfoController) -> some View {
        let current = currentWeekday(controller)
        return Menu {
            ForEach(1...7, id: \.self) { weekday in
                Button {
                    BangumiTimelineStore.shared.setWeekday(weekday, for: controller.item.id)
                } label: {
                    Text(weekday == current ? "✓ \(weekdayTitle(weekday))" : weekdayTitle(weekday))
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(weekdayTitle(current))
                    .font(.system(size: 18, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择放送星期")
    }
}


// MARK: - 追番菜单 / 信息行

extension BangumiInfoScreen {
    /// 追番状态菜单：收窄放在条目信息最下方。
    /// 里面那份（五项带图标 → 分隔线 → 红色「取消追番」）和追番页卡片共用
    /// `CollectStatusMenu`，两处不会再分叉；外面这颗按钮两边不同是对的：
    /// 这里宽得下字，卡片只有 116.7 宽、只放得下符号。
    private func collectMenu(_ controller: InfoController) -> some View {
        let current = currentType(controller)
        return CollectStatusMenu(
            current: current,
            // 没追的番没有可取消的，这一项不出现。
            showsCancelItem: current != .none,
            onChange: { collect(controller, $0) }
        ) {
            HStack(spacing: 3) {
                Image(systemName: current.statusSymbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(current.buttonTitle)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(current == .none ? Color.primary : KazumiPalette.accent(for: colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("追番状态：\(current.buttonTitle)")
    }

    /// 「标签: 值」一行。值用强调色加粗，与原版一致。
    private func infoLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 「已更新/总集数」，对应原版 bangumi_info_card.dart 的 _updateProgress。
    /// 播期已过的算已更新；总集数取列表里的最大集号（列表可能缺集）。
    private func updateProgress(_ controller: InfoController) -> String? {
        let episodes = controller.episodes
        guard !episodes.isEmpty else { return nil }
        let today = AnimeSeason.format(Date())
        let aired = episodes.filter { episode in
            let airdate = episode.airdate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !airdate.isEmpty else { return false }
            return airdate <= today
        }.count
        guard aired > 0 else { return nil }
        let total = episodes.map { Int($0.sort) }.max() ?? episodes.count
        return String(format: "%02d/%02d", aired, total)
    }
}


// MARK: - 标签条

extension BangumiInfoScreen {
    /// 横向排列的标签行：概览 / 吐槽 / 角色 / 关联 / 制作人员。
    private func tabStrip(_ controller: InfoController) -> some View {
        ScrollView(.horizontal) {
            // 间距与胶囊内边距都收窄（2 点 / 4 点）：375 屏默认字号下五颗全在
            // 一行内容宽 324 点（文字 180 + 内边距 120 + 间距 24），不靠缩字号塞。
            HStack(spacing: 6) {
                ForEach(InfoTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selectedTab = tab }
                        Task { await loadTab(tab, controller: controller) }
                    } label: {
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(
                                isSelected ? KazumiPalette.onAccent(for: colorScheme) : Color.primary
                            )
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        isSelected
                                            ? KazumiPalette.accent(for: colorScheme)
                                            : KazumiPalette.cardSurface(for: colorScheme)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    /// 标签对应的内容面板。
    @ViewBuilder
    private func tabContent(
        _ controller: InfoController,
        onExpandComment: @escaping (String) -> Void
    ) -> some View {
        switch selectedTab {
        case .overview:
            InfoOverviewPanel(item: controller.item)
        case .comments:
            InfoCommentsPanel(
                comments: controller.comments,
                total: controller.commentsTotal,
                isLoading: controller.isLoadingComments,
                isPosting: controller.isPostingComment,
                onSend: { text in
                    await controller.postComment(text, type: currentType(controller))
                },
                onExpandComment: onExpandComment
            )
        case .characters:
            InfoCharactersPanel(
                characters: controller.characters,
                isLoading: controller.isLoadingCharacters
            )
        case .relations:
            InfoRelationsPanel(
                relations: controller.relations,
                isLoading: controller.isLoadingRelations,
                zoomNamespace: zoomNamespace
            )
        case .staff:
            InfoStaffPanel(
                staff: controller.staff,
                isLoading: controller.isLoadingStaff
            )
        }
    }
}

// MARK: - 开始播放

extension BangumiInfoScreen {
    /// 右下角的「开始播放」按钮（原版是 FloatingActionButton.extended）。
    ///
    /// 按压反馈用自定义 ButtonStyle：`.plain` 会在按住时把整个按钮变半透明，
    /// 深色下看起来像消失了；这里改成轻微缩放 + 压暗。
    /// 这部剧在这条规则上接着看的位置（第几集 + 第几条线路），没有记录就是 nil。
    /// 越界怎么退由播放器判（`PlayerController.applyStartPoint`）。
    private func resumePoint(for bangumiID: Int, pluginName: String) -> (episode: Int, road: Int)? {
        library.resumePoint(for: bangumiID, pluginName: pluginName)
    }

    private var startPlayingButton: some View {
        Button {
            isShowingSources = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("开始观看")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(KazumiPalette.accent(for: colorScheme)))
        }
        .buttonStyle(KazumiPressButtonStyle())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.trailing, 18)
        .padding(.bottom, 22)
        .accessibilityLabel("开始观看")
    }
}

/// 按压时轻微缩放 + 压暗，而不是把按钮变透明。
struct KazumiPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


// MARK: - 提示

extension BangumiInfoScreen {
    @ViewBuilder
    private var toastView: some View {
        if let message = toastMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .padding(.top, 8)
                // 自动消失只做纯赋值，不包 withAnimation：连同下面把出入场
                // 交给 .animation(value:)，这条路径上不再存在“在动画里改状态”。
                // task 以文案为 id：快速连点时上一条定时器自然作废，不会提前清掉新的。
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    toastMessage = nil
                }
        }
    }
}

// MARK: - 加载

extension BangumiInfoScreen {
    private func load() async {
        let environment = self.environment

        // 1. 先拿缓存铺页面：列表里渲染过的条目、或以前进过这个详情页，
        //    都能立刻画出标题、封面、剧集，不再整页转圈等网络。
        if let cached = BangumiSubjectCache.shared.item(for: bangumiID) {
            let created = InfoController(item: cached, plugins: environment.plugins)
            created.applyCachedEpisodes()
            controller = created
            // 缓存只负责先显示，内容随后照常刷新。
            await refresh(created)
            return
        }

        // 2. 没有缓存（第一次进这部番）：等接口。
        //
        // 拉不到不要马上塞一个「未知番剧」的占位（LP 2990 / 2996）：那样页面会停在
        // 一张没有封面、没有简介、没有评分的空页上，还会把标题写成「未知番剧」。
        // 先重试一次，仍失败就留着转圈、给出「重新加载」，用户点一下就能再来。
        var base = await BangumiAPI.info(id: bangumiID)
        if base == nil {
            base = await BangumiAPI.info(id: bangumiID)
        }
        guard let base else {
            didFailToLoad = true
            return
        }
        let created = InfoController(item: base, plugins: environment.plugins)
        controller = created
        await refresh(created)
    }

    /// 刷新详情、剧集与播出时刻。详情页已经在屏幕上时，这些只是把内容补全。
    private func refresh(_ controller: InfoController) async {
        await controller.loadDetailIfNeeded()
        await controller.loadEpisodes()
        // 播出时刻要单独拉季度表，失败只是不显示时刻。
        await controller.loadAirTime()
    }

    /// 标签点开时才去拉对应数据。
    private func loadTab(_ tab: InfoTab, controller: InfoController) async {
        switch tab {
        case .overview:
            break
        case .comments:
            await controller.loadComments()
        case .characters:
            await controller.loadCharacters()
        case .relations:
            await controller.loadRelations()
        case .staff:
            await controller.loadStaff()
        }
    }
}

// MARK: - 追番 / 时间表

extension BangumiInfoScreen {
    /// 当前追番状态（本地收藏库里的）。
    private func currentType(_ controller: InfoController) -> CollectType {
        library.entry(for: controller.item.id)?.collectType ?? .none
    }

    private func collect(_ controller: InfoController, _ type: CollectType) {
        // 口径同 collect_controller.dart 的 _syncBangumiCollectIfEnabled：
        // 「自动同步追番」开着才推 Bangumi，推不成功就整次作废。
        let syncEnabled = settings.bangumiSyncEnable
        let showToast = settings.bangumiImmediateSyncToastEnable
        guard syncEnabled else {
            applyCollect(controller, type)
            return
        }
        Task {
            let pushed = await environment.bangumiSync.pushCollectible(
                bangumiID: controller.item.id,
                type: type
            )
            guard pushed else {
                toastMessage = "同步到 Bangumi 失败，已取消本次状态修改"
                return
            }
            applyCollect(controller, type)
            if showToast { toastMessage = "已同步到 Bangumi" }
        }
    }

    private func applyCollect(_ controller: InfoController, _ type: CollectType) {
        let item = controller.item
        if type == .none {
            library.remove(bangumiID: item.id)
            // 与原版一致：不再处于「在看」时，时间表条目一并删除。
            BangumiTimelineStore.shared.dropIfNotWatching(item.id, collectType: CollectType.none)
            return
        }
        library.upsert(
            LibraryEntry(
                id: item.id,
                type: type.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: controller.episodes.count,
                currentEpisode: 0,
                addedAt: library.entry(for: item.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
        // 改成「在看」以外的状态时，时间表条目随之失效（原版 dropIfNotWatching）。
        BangumiTimelineStore.shared.dropIfNotWatching(item.id, collectType: type)
    }

    /// 当前放送星期：用户手动改过就用手动的，否则用时间表里实际所在的那一列。
    ///
    /// 顺序和 main 一致：手动选的星期 → 时间表的分组（含凌晨档换列）→
    /// 开播日过一遍凌晨档规则。不能直接拿开播日：接口经常不给开播日，退回
    /// 默认值就会和时间表对不上（时间表排周一、这里写周日）。
    private func currentWeekday(_ controller: InfoController) -> Int {
        let store = BangumiTimelineStore.shared
        if let entry = store.entry(for: controller.item.id), entry.weekdayCustom {
            return max(1, min(7, entry.weekday))
        }
        if let column = TimelineWeekdayCache.weekday(of: controller.item.id) {
            return column
        }
        return TimelineColumn.weekday(
            bangumiWeekday: controller.item.airWeekday,
            airTimeOf: controller.item.id
        )
    }

    private func isInTimeline(_ controller: InfoController) -> Bool {
        BangumiTimelineStore.shared.entry(for: controller.item.id)?.showInTimeline ?? false
    }

    /// 时间表开关：打开即添加到时间表（与原版 _setShowInTimeline 一致）。
    ///
    /// 原版点亮前要求番剧处于「在看」状态：不在看就先弹确认，确认后顺手
    /// 标成在看。之前这里直接写存储，既缺这一步，写入路径本身还会崩
    /// （存储层用非字符串键做 JSONSerialization，见 BangumiTimelineStore）。
    private func toggleTimeline(_ controller: InfoController) {
        let next = !isInTimeline(controller)
        guard next else {
            BangumiTimelineStore.shared.setShowInTimeline(
                false,
                for: controller.item.id,
                weekday: currentWeekday(controller)
            )
            toastMessage = "已从时间表移除"
            return
        }
        if currentType(controller) != .watching {
            pendingTimelineItem = controller.item
            return
        }
        enableTimeline(controller)
    }

    /// 真正写入「添加到时间表」。
    private func enableTimeline(_ controller: InfoController) {
        BangumiTimelineStore.shared.setShowInTimeline(
            true,
            for: controller.item.id,
            weekday: currentWeekday(controller)
        )
        toastMessage = "已添加到时间表"
    }

    /// 确认「标记为在看并添加」后：先写收藏，再添加到时间表。
    private func markWatchingAndEnableTimeline(_ item: BangumiItem) {
        library.upsert(
            LibraryEntry(
                id: item.id,
                type: CollectType.watching.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: 0,
                currentEpisode: 0,
                addedAt: library.entry(for: item.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
        BangumiTimelineStore.shared.setShowInTimeline(
            true,
            for: item.id,
            weekday: TimelineWeekdayCache.weekday(of: item.id)
                ?? TimelineColumn.weekday(bangumiWeekday: item.airWeekday, airTimeOf: item.id)
        )
        toastMessage = "已标记为在看，并添加到时间表"
    }

    /// 星期序号（1 = 周一 ... 7 = 周日）的中文标题。
    private func weekdayTitle(_ weekday: Int) -> String {
        let titles = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return titles[max(1, min(7, weekday)) - 1]
    }
}

// MARK: - 更多菜单

extension BangumiInfoScreen {
    private func copyTitle(_ controller: InfoController) {
        UIPasteboard.general.string = controller.item.displayName
        toastMessage = "标题已复制"
    }

    private func saveCover(_ controller: InfoController) {
        let urlString = controller.item.largeImage
        guard !urlString.isEmpty, let url = Self.imageURL(from: urlString) else {
            toastMessage = "暂无封面"
            return
        }
        Task { @MainActor in
            do {
                let (data, _) = try await KazumiNetworkPolicy.requestSession.session.data(from: url)
                // 交给 PlayerScreenshot 那条 nonisolated 的路（LP 4688 / Fuck 4696）：
                // 这里原来是 Task { @MainActor } 里套 continuation，闭包照样被染成主线程隔离，
                // PhotoKit 在自己队列上回调就撞断言直接崩。两个页面同一条路，不再各写一份。
                if let failure = await PlayerScreenshot.save(png: data) {
                    toastMessage = failure
                } else {
                    toastMessage = "已保存到相册"
                }
            } catch {
                toastMessage = "封面保存失败，请重试"
            }
        }
    }

    private func openExternally(_ controller: InfoController) {
        guard let url = URL(string: "https://bangumi.tv/subject/\(controller.item.id)") else { return }
        UIApplication.shared.open(url)
    }

    /// Bangumi 的图片地址可能是协议相对地址，统一补成 https。
    private static func imageURL(from raw: String) -> URL? {
        let normalized = KazumiImageLoader.normalizedURLString(raw)
        return normalized.isEmpty ? nil : URL(string: normalized)
    }
}

