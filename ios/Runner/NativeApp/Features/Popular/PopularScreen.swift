import SwiftUI

/// 推荐页：封面上半屏 + 下面几行横向海报架。
///
/// 封面在滚动内容里（LP 2846）：上滑跟着内容一起滚走；下拉到顶时不拉伸、不放大、
/// 不回弹——下拉出来的那段往回补（Colo 2847），视觉上封面钉在屏幕顶端不动；
/// 同时封面自己从中心往四周放大（LP 2869 / Colo 2870）。
/// 这页没有下拉刷新（LP 2823 / Colo 2824）：各行照旧按各自的过期时间自己换新。
struct PopularScreen: View {
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?

    @State private var controller = PopularController()
    @Environment(AppRouter.self) private var router

    /// 滚动内容上沿在滚动空间里的 y：0 是原位，负数是上拉过界（下拉出来的那段）。
    @State private var scrollY: CGFloat = 0
    /// 顶部那条模糊开没开：只有真的上滑才开，回弹和手抖不算（LP 3145 / 3147）。
    @State private var showsTopBlur = false
    /// 滚动区顶部实际生效的 inset（含安全区）：下拉补偿归零起点用（LP 2887 的量法）。
    @State private var topInset: CGFloat = 0
    /// iPad 竖屏两栏：封面拖动量外提（Colo 7139）——封面块和右栏货架从同一个状态算偏移，
    /// 同一个弹簧、零延迟；窄档不用它。
    @State private var heroDragPull: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 卡片画法只看可用高这一个信号（Colo 8228 §4.1）：<760 叠压、≥760 现行画法。
            // 与宽度档是两条独立判据，不共用常量、不互相读（Ato 8199）。
            let overlayCard = size.height < Self.overlayCardMaxHeight
            // 叠压卡「填满焦点区」的那个高：可用高 ＋ 卡片自己铺上去的顶部安全区。
            let heroFillHeight = size.height + proxy.safeAreaInsets.top
            // 三档只按可用空间分（Colo 6687 §一）：A 单栏、B 宽档（再按宽高比分横式两栏／竖式英雄行）、C 矮屏。
            if size.width < Self.narrowMaxWidth {
                narrowBody(size: size, safeTop: proxy.safeAreaInsets.top)
            } else if size.height >= Self.wideMinHeight, size.width > size.height,
                      Self.rightColumnWidth(forWidth: size.width) >= Self.rightColumnMinWidth {
                // 右栏 ≥ 320（Colo 6822）：不到就回落单栏，不缩左栏、不压海报。
                twoColumnBody(size: size, overlayCard: overlayCard, heroFillHeight: heroFillHeight)
            } else if size.height < Self.wideMinHeight, size.width > size.height {
                // C 档：宽但矮（iPhone 横屏 750×402）。货架整宽接在封面下面会被浮动
                // tab 条压住，改成封面钉左、货架收进右栏自己滚（Colo 6886）。
                compactTwoColumnBody(size: size, insets: proxy.safeAreaInsets)
            } else {
                heroRowBody(size: size, overlayCard: overlayCard, heroFillHeight: heroFillHeight)
            }
        }
    }

    /// 设备屏高：封面高一律取屏高 × 0.70（LP 6677 / 6679，Ato 6680 定案）。
    ///
    /// 不按栏宽换算比例了：18 Pro 也一起改，402×874 上封面 600 → 612，
    /// 推荐页竖屏不再跟旧图比，八屏基线摘掉推荐页、其余七屏照旧。
    /// 也不用容器高度——容器扣掉了安全区和 tab 栏，那不是「屏高」。
    private static var deviceScreenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 874
    }

    /// 状态栏高（跟 PopularHero 原版顶栏同一个数）：窄档自画标题那行的行顶用它，
    /// 不加 8（Colo 7226：HEAD topBar .padding(.top, statusBarHeight)）。
    private static var statusBarHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.statusBarManager?.statusBarFrame.height ?? 44
    }

    /// 封面高：一律屏高 × 0.70（LP 6677「统一改成 70%」／Ato 6682 不分机型）。
    ///
    /// 只有特别窄的窗口（Slide Over 320 那种）再兜一条底：高不超过容器宽 ÷ 0.45，
    /// 否则封面会被裁掉一半（Colo 6683 的兜底）。
    private static func coverHeight(forWidth width: CGFloat) -> CGFloat {
        min(deviceScreenHeight * 0.70, width / 0.45)
    }

    /// 分档门槛（Colo 6687 §一）：窄于 700 是单栏；宽档再要求高 ≥ 600，
    /// 否则 iPhone 横屏那种 874×402 宽度够、高度放不下封面，要落到矮屏档。
    private static let narrowMaxWidth: CGFloat = 700
    private static let wideMinHeight: CGFloat = 600
    /// 叠压卡的高度门槛（Colo 8228 §4.1）：可用高 <760 才叠压。760 夹在 Duo 摊开 669／
    /// iPad mini 横屏 744 与 iPad 11″ 横屏 820 之间。只给卡片画法用，别拿它定栏数。
    private static let overlayCardMaxHeight: CGFloat = 760

    /// 两栏的左栏宽 = 封面高 × 0.67，右栏是剩下的（Colo 6683 / 6822）。
    private static func rightColumnWidth(forWidth width: CGFloat) -> CGFloat {
        width - (coverHeight(forWidth: width) * 0.67).rounded()
    }

    /// 两栏右栏的下限（Colo 6822）：低于这个数一行只放得下 1 张海报，货架就没意义了。
    private static let rightColumnMinWidth: CGFloat = 320

    /// C 档左栏封面：210×315，正好 2:3（Colo 6886）。
    /// 315 是避开浮动 tab 条的上限——tab 条从屏顶 342 起，封面从 0 排到 315。
    private static let compactCoverWidth: CGFloat = 210
    private static let compactCoverHeight: CGFloat = 315
    /// C 档左栏封面与右栏之间的缝（Colo 6886：750 − 210 − 24 = 516）。
    private static let compactColumnGap: CGFloat = 24

    /// 宽屏两栏：左边 1/3 大封面，右边 2/3 分组（LP 6644 / 简报）。
    ///
    /// 有侧栏的版面：封面宽由高反推，宽 = 高 × 0.67，比例恒为 2:3 一点不裁，
    /// 侧栏吃掉剩下的宽度（Colo 6683 第一条）。这一栏不跟着页面上下滚，分组那一栏自己滚。
    private func twoColumnBody(size: CGSize, overlayCard: Bool, heroFillHeight: CGFloat) -> some View {
        // 叠压态封面填满焦点区可用高（Colo 8228 §4.2）；栏宽仍按现行公式算，不动右栏货架。
        let baseCoverHeight = Self.coverHeight(forWidth: size.width)
        let coverHeight = overlayCard ? heroFillHeight : baseCoverHeight
        let columnWidth = (baseCoverHeight * 0.67).rounded()
        // 英雄行块跟移量 = 封面往下长的那截（1:1，Colo 7139）；宽档 pullScale=1、pullOffset=0，
        // 同 PopularHero.effectiveOffset 同一口径：coverHeight × min(dragPull,120) / 550。
        let heroFollowOffset = coverHeight * min(max(heroDragPull, 0), 120) / 550
        return HStack(alignment: .top, spacing: 0) {
            // 下拉放大由封面自己接（Colo 6736）：只有按在封面这块 484×722 里才长，
            // 按在信息块、右栏货架、两栏缝上都不动。
            // 整个英雄行块跟封面 1:1 同偏移（Colo 7139：iPad 竖屏下拉时右栏也要下移），
            // 偏移量从拖动量同一个状态算，松手同一个弹簧回去。
            leftColumn(
                coverHeight: coverHeight,
                columnWidth: columnWidth,
                dragPull: $heroDragPull,
                overlayCard: overlayCard
            )
                .frame(width: columnWidth)
                .ignoresSafeArea(edges: .top)
                .offset(y: heroFollowOffset)

            VStack(spacing: 0) {
                // 标题 x=500（栏左缘 484 + 16）、圆钮贴右边缘 16，同一行，深色字压白底（Colo 6725）。
                // 让开安全区再留 18（Ato 8217）。
                PopularWideTopBar()
                    .padding(.top, 18)

                ScrollView {
                    // 宽档海报 132×198（Colo 6708：13 寸右栏 892 一行 6 张）。
                    // 货架跟英雄行块同一个偏移、同一个状态（Colo 7139：右栏 1:1 同步下移，
                    // 不能封面在拉、右栏钉着不动）。
                    shelves(tileWidth: 132)
                        .offset(y: heroFollowOffset)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity)
        }
        // 只有封面那一栏铺到状态栏；右栏得待在顶上那排 tab 底下（现在浮在内容上，会压住第一行标题）。
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            controller.paintFromCache()
            Task { await controller.load() }
        }
    }

    /// 两栏版面的左栏内容：封面纯美术在上，信息块在下面把剩下的高度填满（Colo 6691）。
    /// dragPull：拖动量外提（Colo 7139），右栏货架跟封面同一个状态同步位移。
    private func leftColumn(
        coverHeight: CGFloat,
        columnWidth: CGFloat,
        dragPull: Binding<CGFloat>,
        overlayCard: Bool
    ) -> some View {
        PopularHero(
            items: controller.heroItems,
            zoomNamespace: zoomNamespace,
            // 固定在一栏里，不存在滚出屏幕这回事。
            isOnScreen: true,
            coverHeightOverride: coverHeight,
            coverWidth: columnWidth,
            // 短屏叠压：封面填满、文字压底部渐隐（Colo 8228 §4.2）；
            // 其余仍是「封面纯美术在上、信息块在下面」（Colo 6691）。
            textPlacement: overlayCard ? .overlay : .below,
            // 标题和两颗圆钮收进右栏白底上，左栏一个字的没有（Colo 6725）。
            showsTopBar: false,
            // 封面自己接下拉手势（Colo 6736）；叠压态不做下拉放大（Colo 8228 §4.2，短屏没富余高度）。
            coverPullGesture: !overlayCard,
            // 拖动量外提 + 整块跟移（Colo 7139：iPad 竖屏下拉，右栏 1:1 同偏移）。
            dragPullSource: dragPull,
            blockPullOffset: true,
            overlayWideCard: overlayCard
        )
    }


    /// 浮动 tab 条（药丸）左缘，屏幕 x。UITabBar 自己整屏宽，药丸是它里面的
    /// `_UITabBarItemPlatterView`（实测 x 278、宽 318）；系统改名就找不到，返回 nil 回落。
    private static func tabBarLeadingEdge() -> CGFloat? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow,
              let bar = Self.findTabBar(in: window) else { return nil }
        var queue: [UIView] = bar.subviews
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if String(describing: type(of: v)) == "_UITabBarItemPlatterView" {
                return v.convert(v.bounds, to: window).minX.rounded()
            }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }

    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for sub in view.subviews { if let b = findTabBar(in: sub) { return b } }
        return nil
    }

    /// C 档两栏（Colo 6886）：封面钉在左栏，货架收进右栏自己竖向滚。
    ///
    /// 旧的英雄行把货架整宽接在封面下面：封面 281 高，货架首行落点在 y≈368，
    /// 而浮动 tab 条占 y 342…385——一屏只剩 17 点，等于没有货架。
    private func compactTwoColumnBody(size: CGSize, insets: EdgeInsets) -> some View {
        // 封面右缘 = 浮动 tab 条左缘 − 1（Colo 6947）；量不到回落 272。
        let slotWidth = Self.tabBarLeadingEdge().map { max(200, $0 - 1 - insets.leading) } ?? Self.compactCoverWidth
        // 封面框 x 0..272、y 0..402（Ato 6939 / Colo 6940）：向左铺进安全区、向下铺到屏底。
        let bleed = insets.leading
        // 底安全区只取 home 条那一段（横屏 21）：proxy 里的底内边距把浮动 tab 条也算进去了（实测 64），
        // 块底会被顶高 43 点（Colo 6940：402 − 21 − 16 = 365）。
        let homeBar = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.bottom ?? 21
        let fullHeight = size.height + insets.top + insets.bottom
        return HStack(alignment: .top, spacing: Self.compactColumnGap) {
            Color.clear
                .frame(width: slotWidth, height: size.height)
                .overlay(alignment: .topLeading) {
                    PopularHero(
                        items: controller.heroItems,
                        zoomNamespace: zoomNamespace,
                        // 固定在一栏里，不存在滚出屏幕这回事。
                        isOnScreen: true,
                        coverHeightOverride: fullHeight,
                        coverWidth: slotWidth + bleed,
                        textPlacement: .overlay,
                        // 两颗圆钮跟着标题去右栏顶上，左栏一个字的没有。
                        showsTopBar: false,
                        compactColumn: true,
                        compactLeadingBleed: bleed,
                        compactBottomInset: homeBar + PopularHero.compactTextBottomInset
                    )
                    .frame(width: slotWidth + bleed, height: fullHeight)
                    .offset(x: -bleed, y: -insets.top)
                }

            VStack(spacing: 0) {
                // 让开安全区再留 18（Ato 8217）。
                PopularWideTopBar()
                    .padding(.top, 18)

                ScrollView {
                    shelves(tileWidth: 96)
                        .padding(.top, 24)
                        // 右栏底部留 60 给浮动 tab 条（6886/6888 规格 v2 定稿：玻璃顶 342，402 − 342 = 60）。
                        .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            controller.paintFromCache()
            Task { await controller.load() }
        }
    }

    /// 英雄行（Colo 6687 §3 / §4）：iPad 竖屏和 iPhone 横屏都走这一档。
    /// 封面在左、比例恒 2:3 不裁，文字块在右垂直居中；货架整宽接在下面，跟着页面一起滚。
    private func heroRowBody(size: CGSize, overlayCard: Bool, heroFillHeight: CGFloat) -> some View {
        // 矮窗口（H<760）在竖式英雄行上同样改叠压：封面填满、文字压上去（Colo 8228 §4.2）。
        let coverHeight = overlayCard ? heroFillHeight : Self.coverHeight(forWidth: size.width)
        // 封面宽上限（Colo 6826 / Ato 6832）：min(高 × 0.70 × 0.67, 容器宽 − 368)。
        // 第二个项就是「文字块正好 320」，11 寸 553→452、mini 531→376，13 寸恒等。
        // 字号本来就跟着封面宽走（coverTextScale），不用另外改。
        let coverWidth = min((coverHeight * 0.67).rounded(), size.width - 368)
        let isWide = size.height >= Self.wideMinHeight
        // 文字块最宽 420（Colo 6687 §4.2，HIG 限制行宽）；iPad 竖屏那档按容器宽算，339 左右。
        let textWidth = isWide
            ? max(120, size.width - coverWidth - 48)
            : max(120, min(420, size.width - coverWidth - 48))

        let growth = coverHeight * (pullScale - 1)

        return ScrollView {
            LazyVStack(spacing: 0) {
                PopularHero(
                    items: controller.heroItems,
                    zoomNamespace: zoomNamespace,
                    isOnScreen: scrollY < coverHeight,
                    pullScale: pullScale,
                    pullOffset: overPull,
                    coverHeightOverride: coverHeight,
                    coverWidth: coverWidth,
                    // 竖屏那档右栏要把简介和标签也带上（Ato 6720），iPhone 横屏那档还是原来那块。
                    textPlacement: overlayCard ? .overlay : (isWide ? .trailingFilled : .trailing),
                    // 竖屏那档标题进右栏；手机那档照旧压在封面上，那七屏有基线锁着。
                    showsTopBar: !isWide,
                    overlayWideCard: overlayCard
                )
                .environment(\.popularHeroTextWidth, textWidth)
                // 上拉过界时往回补，封面钉在屏幕顶端不动，跟单栏那条同一个规矩。
                .offset(y: -overPull)

                shelves(tileWidth: isWide ? 132 : nil)
                    // 封面放大后底边往下长多少，货架就让多少，不被盖住（Ato 6718 第一条）。
                    .offset(y: growth - overPull)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            scrollY = newValue
        }
        // 封面铺到屏幕最顶（Colo 6687 §3.1 / §4.2）：跟单栏那条一样忽略顶部安全区。
        .ignoresSafeArea(edges: .top)
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            controller.paintFromCache()
            Task { await controller.load() }
        }
    }

    /// 单栏版面：竖屏和窄窗口都用这一版，一个像素不动。
    private func narrowBody(size: CGSize, safeTop: CGFloat) -> some View {
        // §五（A 档单栏，Colo 7072 / Ato 7071；改口 Ato 7111 / Colo 7112；Ato 7141 删渐变；
        // 结构回旧 hero：Ato 7186/7189，信息块压封面下部、封面图垫到简介下）：
        // 封面顶到 y=0 全出血；tab 条 / 搜索·历史圆钮直接叠在封面上（白字，LP 7140 拍板
        // 接受亮封面看不清的取舍，后续撞上看不清走系统材质，不是恢复黑渐变）；
        // 大标题「推荐」旧版原样（Ato 7170/7181，见 narrowTopControls）；
        // 信息块用旧 hero 默认 .overlay（textTop = 封面高 − 块高，压在封面下部，旧渐隐配套）。
        // iPad 窄窗口隐藏系统顶栏、改画透明叠图 tab 条；iPhone 保留底部系统 tab 栏。
        let coverWidth = size.width
        // 封面高度 = 屏高 × 0.70（Ato 7175 / LP 7173：不再用 0.90×宽；440 宽机 ≈669，
        // 接近 2:3 海报）；特窄窗口炤旧兜底（宽 ÷ 0.45，Colo 6683）。
        let coverHeight = Self.coverHeight(forWidth: size.width)
        // 下拉补偿以「内容顶」为原点（LP 2887）：滚动区尊重顶部安全区时静止 offset = −顶部 inset，
        // 减掉再判过界。现在滚动区忽略顶部安全区，静止 offset 归 0，这段照常兜住回弹。
        let overPullNarrow = max(0, -(scrollY + topInset))
        let pullScaleNarrow = 1 + min(overPullNarrow, 120) / 550
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return ScrollView {
            LazyVStack(spacing: 0) {
                ZStack(alignment: .top) {
                    PopularHero(
                        items: controller.heroItems,
                        zoomNamespace: zoomNamespace,
                        // 封面整块滚出屏幕就停掉自动切换（Colo 3047）。
                        isOnScreen: scrollY < coverHeight,
                        pullScale: pullScaleNarrow,
                        pullOffset: overPullNarrow,
                        coverHeightOverride: coverHeight,
                        coverWidth: coverWidth,
                        // 信息块走 hero 默认旧结构 textPlacement .overlay
                        //（textTop = 封面高 − 块高，压封面下部，旧渐隐配套）——Ato 7186/7189。
                        // 顶栏仍由 narrowTopControls 钉住画（存留改动④下拉钉住可点），
                        // hero 内部旧 topBar 不再叠一份。
                        showsTopBar: false
                    )
                    narrowTopControls(safeTop: safeTop, isPad: isPad)
                }
                .offset(y: -overPullNarrow)

                // 封面底边下留 8（HEAD 旧版同一条：渐隐到封面底边已是页面底色，不用再留一层）。
                shelves()
                    .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
        // 封面顶到 y=0 全出血（§五 叠图版）：滚动区铺进顶部安全区，
        // 圆钮/tab 条从窗口顶画起（Ato 7141：不再压黑渐变，白字直接叠封面）。
        .ignoresSafeArea(edges: .top)
        .scrollIndicators(.hidden)
        // 顶部那条模糊改成上滑才出现（LP 3125 / 3126 / 3132）：在顶部时没有，内容滚上来才有，
        // 跟番剧详情页同一条。顶栏照旧跟着封面滚（LP 2865），不钉住。
        .scrollEdgeEffectStyle(.soft, for: .top)
        // 不上滑就不显示（LP 3139 / 3145）。滚动区尊重顶部安全区时系统不会在页首误判，
        // 但回弹和手抖那段仍然算「已滚上来」的边缘，这里显式接管：关掉之后由上面
        // 那条 style 管上滑时出现，回到顶部就没有。
        .scrollEdgeEffectHidden(!showsTopBlur, for: .top)
        // 封面顶到安全区顶、顶栏落在安全区下的背景上（§五：不铺进状态栏、
        // 顶栏文字不压图、封面不压窗口控制点）。滚动区尊重顶部安全区，
        // 下拉补偿用 topInset（ScrollGeometry.contentInsets.top）归零起点。
        // 下拉位移用 onScrollGeometryChange 量（LP 2887）：PreferenceKey 在橡皮筋
        // 回弹那段不更新，补偿算出来一直是 0，封面就跟着内容一起下来。
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            scrollY = newValue
            // 真的滚上去一段才开、回落到很浅才关（LP 3147）：中间留出这一段差，
            // 系统自己回弹、手抖出来的那几点的位移就不算数了。
            if newValue > 12, !showsTopBlur {
                showsTopBlur = true
            } else if newValue < 4, showsTopBlur {
                showsTopBlur = false
            }
        }
        // 顶部实际生效的 inset 另挂一条量（transform 里只能拿 ScrollGeometry，
        // action 拿不到）：下拉补偿归零起点和顶栏补差都用它。
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentInsets.top
        } action: { _, newValue in
            topInset = newValue
        }
        // 一行都没拉到（缓存空 + 网络也失败）时给个能重试的页；否则就是顶层一个顶栏的空页。
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        // 大标题仍自画、位置照原版顶栏那一行（LP 7221）；系统大标题不采用。
        // iPad 窄窗口：系统顶栏 tab 条隐藏，改画叠图 tab 条（Ato 7111）；
        // iPhone 保留底部系统 tab 栏。
        // iPhone 这档不能写 `.visible`：这里是本 Tab 导航栈的根页面，根上显式声明
        // 可见性会盖掉被推入页面自己的设置——播放页 `.toolbar(.hidden, for: .tabBar)`
        // 因此失效，从推荐页「开始观看」进播放页时底部 tab 不收（LP 7339）。
        // 用 `.automatic` 不表态，默认仍是可见，播放页的 `.hidden` 就能生效。
        .toolbar(isPad ? .hidden : .automatic, for: .tabBar)
        .onAppear {
            // 先把缓存画出来，再后台刷新（LP 2733 / Ato 2734）：
            // 冷启动不该对着空页等网。
            controller.paintFromCache()
            Task { await controller.load() }
        }
    }

    /// 顶部叠图控件（§五 叠图版 / Ato 7111 / Colo 7112；Ato 7141 删渐变；大标题按 LP 7157
    /// 加回、样式旧版原样 Ato 7168）：iPhone 大标题「推荐」左 16、和搜索/历史圆钮同一行（行高 44）；
    /// iPad 窄窗那行被居中 tab 条（73–109）占了，标题放 tab 条下面（行顶 117）。
    /// iPad 窄窗口隐藏系统顶栏，这里改画透明 tab 条（白字，选中 100% / 未选 72%）直接压在封面上；
    /// 搜索 / 历史圆钮两设备都贴封面右上、与 tab 同行（同一行右端不随封面顶推，Ato 7111）。
    private func narrowTopControls(safeTop: CGFloat, isPad: Bool) -> some View {
        // 大标题自画、照原版顶栏那一行（LP 7221：位置找回最初的位置）——
        // iPhone 跟圆钮同一行、左边 16（HEAD topBar 的 .padding(.horizontal, 16)）；
        // iPad 窄窗口在叠图 tab 条下一行。圆钮钉住可点（存留改动④）。
        ZStack(alignment: .top) {
            if isPad {
                HStack(spacing: 0) {
                    ForEach(AppDestination.allCases, id: \.self) { dest in
                        Button {
                            router.selectedDestination = dest
                        } label: {
                            Text(dest.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(router.selectedDestination == dest ? 1 : 0.72))
                                .frame(height: 36)
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 36)
                .padding(.top, 73)
                // 大标题在 tab 条下一行（行顶 117 = 109+8，左 16）；样式照 HEAD topBar 原样
                //（.largeTitle semibold、字距 −0.4、黑 30% 阴影），字恒白（LP 7275 / Colo 7279）。
                Text("推荐")
                    .font(.largeTitle.weight(.semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.30), radius: 8, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 117)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 10) {
                // iPhone：大标题和圆钮同一行，左边 16（HEAD topBar 原排法与样式）。
                if !isPad {
                    Text("推荐")
                        .font(.largeTitle.weight(.semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.30), radius: 8, y: 1)
                        .frame(height: 44, alignment: .center)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                PopularTopBarCircle(symbol: "magnifyingglass", label: "搜索") {
                    router.push(.search(keyword: ""))
                }
                PopularTopBarCircle(symbol: "clock", label: "观看历史") {
                    router.push(.history)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(height: 44, alignment: .top)
            .padding(.top, isPad ? 69 : Self.statusBarHeight)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }

    /// 四行全空时的错误态：跟列表页那份同一个形状（那里也是「更多」点进去的第一屏）。
    private var failureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("推荐没能加载")
                .font(.headline)
            Text("网络好像不太顺，点一下重新加载。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新加载") {
                Task { await controller.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 160)
    }

    /// 下拉出来的那段：只在过界时为正，上滑时是 0（Colo 2847）。
    private var overPull: CGFloat {
        max(0, -scrollY)
    }

    /// 下拉过界时封面的放大倍数：下拉 d 放大 1 + d/550，封顶 1.22（LP 2938 / Colo 2939）。
    /// 只放大封面那张图，块和文字都不动。
    private var pullScale: CGFloat {
        1 + min(overPull, 120) / 550
    }


    /// 下面那几行横向海报架。
    private func shelves(tileWidth: CGFloat? = nil) -> some View {
        LazyVStack(spacing: 24) {
            ForEach(controller.rows) { row in
                PopularShelf(
                    row: row,
                    zoomNamespace: zoomNamespace,
                    onMore: { router.push(.popularList($0)) },
                    // 第一行「热门番组」标题点开选标签（LP 3044：菜单从封面大标题挪到这儿）。
                    tagOptions: row.list == .trending ? heroTags : [],
                    onPickTag: row.list == .trending ? { router.push(.popularList(.tag($0))) } : nil,
                    tileWidth: tileWidth,
                    compactHeader: tileWidth != nil
                )
                // 行距就是规格那 24（Colo 6747）：手机那档多给的 8 留着不动。
                .padding(.top, tileWidth == nil ? 8 : 0)
            }
        }
    }
}
