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

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 三档只按可用空间分（Colo 6687 §一）：A 单栏、B 宽档（再按宽高比分横式两栏／竖式英雄行）、C 矮屏。
            if size.width < Self.narrowMaxWidth {
                narrowBody(size: size)
            } else if size.height >= Self.wideMinHeight, size.width > size.height,
                      Self.rightColumnWidth(forWidth: size.width) >= Self.rightColumnMinWidth {
                // 右栏 ≥ 320（Colo 6822）：不到就回落单栏，不缩左栏、不压海报。
                twoColumnBody(size: size)
            } else {
                heroRowBody(size: size)
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

    /// 两栏的左栏宽 = 封面高 × 0.67，右栏是剩下的（Colo 6683 / 6822）。
    private static func rightColumnWidth(forWidth width: CGFloat) -> CGFloat {
        width - (coverHeight(forWidth: width) * 0.67).rounded()
    }

    /// 两栏右栏的下限（Colo 6822）：低于这个数一行只放得下 1 张海报，货架就没意义了。
    private static let rightColumnMinWidth: CGFloat = 320

    /// 宽屏两栏：左边 1/3 大封面，右边 2/3 分组（LP 6644 / 简报）。
    ///
    /// 有侧栏的版面：封面宽由高反推，宽 = 高 × 0.67，比例恒为 2:3 一点不裁，
    /// 侧栏吃掉剩下的宽度（Colo 6683 第一条）。这一栏不跟着页面上下滚，分组那一栏自己滚。
    private func twoColumnBody(size: CGSize) -> some View {
        let coverHeight = Self.coverHeight(forWidth: size.width)
        let columnWidth = (coverHeight * 0.67).rounded()
        return HStack(alignment: .top, spacing: 0) {
            // 下拉放大由封面自己接（Colo 6736）：只有按在封面这块 484×722 里才长，
            // 按在信息块、右栏货架、两栏缝上都不动。
            leftColumn(coverHeight: coverHeight, columnWidth: columnWidth)
                .frame(width: columnWidth)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 0) {
                // 标题 x=500（栏左缘 484 + 16）、圆钮贴右边缘 16，同一行，深色字压白底（Colo 6725）。
                PopularWideTopBar()
                    .padding(.top, 12)

                ScrollView {
                    // 宽档海报 132×198（Colo 6708：13 寸右栏 892 一行 6 张）。
                    shelves(tileWidth: 132)
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
    private func leftColumn(coverHeight: CGFloat, columnWidth: CGFloat) -> some View {
        PopularHero(
            items: controller.heroItems,
            zoomNamespace: zoomNamespace,
            // 固定在一栏里，不存在滚出屏幕这回事。
            isOnScreen: true,
            coverHeightOverride: coverHeight,
            coverWidth: columnWidth,
            // 左栏做成一张英雄卡：封面纯美术在上，信息块在下面把剩下的高度填满（Colo 6691）。
            textPlacement: .below,
            // 标题和两颗圆钮收进右栏白底上，左栏一个字的没有（Colo 6725）。
            showsTopBar: false,
            // 封面自己接下拉手势（Colo 6736）。
            coverPullGesture: true
        )
    }


    /// 英雄行（Colo 6687 §3 / §4）：iPad 竖屏和 iPhone 横屏都走这一档。
    /// 封面在左、比例恒 2:3 不裁，文字块在右垂直居中；货架整宽接在下面，跟着页面一起滚。
    private func heroRowBody(size: CGSize) -> some View {
        let coverHeight = Self.coverHeight(forWidth: size.width)
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
                    textPlacement: isWide ? .trailingFilled : .trailing,
                    // 竖屏那档标题进右栏；手机那档照旧压在封面上，那七屏有基线锁着。
                    showsTopBar: !isWide
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
    private func narrowBody(size: CGSize) -> some View {
        let coverHeight = Self.coverHeight(forWidth: size.width)
        // 封面比例上限（Colo 6819）：容器宽 ÷ 封面高 > 0.85 时一张 2:3 海报要裁掉
        // 三成以上，横屏分屏 683×1032 就是这种。这时封面宽改成高 × 0.67、水平居中，
        // 信息块跟封面同宽，一点不裁。
        let cappedWidth = size.width / coverHeight > 0.85
            ? (coverHeight * 0.67).rounded()
            : size.width
        return ScrollView {
            LazyVStack(spacing: 0) {
                PopularHero(
                    items: controller.heroItems,
                    zoomNamespace: zoomNamespace,
                    // 封面整块滚出屏幕就停掉自动切换（Colo 3047）。
                    isOnScreen: scrollY < coverHeight,
                    pullScale: pullScale,
                    pullOffset: overPull,
                    coverHeightOverride: coverHeight,
                    coverWidth: cappedWidth
                )
                .frame(width: cappedWidth)
                .frame(maxWidth: .infinity)
                // 上拉过界时往回补，视觉上封面钉在屏幕顶端不动（Colo 2847 / LP 2887）；
                // 上滑时补偿是 0，封面跟着内容一起滚走（LP 2846）。
                .offset(y: -overPull)

                // 封面底边下面留 24 就够：渐隐到封面底边 600 已经是页面底色，底下不用再留一层
                // 让它化开（LP 2912 / Colo 2913：本周热门回到封面底边下 24，即 624）。
                shelves()
                    .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        // 顶部那条模糊改成上滑才出现（LP 3125 / 3126 / 3132）：在顶部时没有，内容滚上来才有，
        // 跟番剧详情页同一条。顶栏照旧跟着封面滚（LP 2865），不钉住。
        .scrollEdgeEffectStyle(.soft, for: .top)
        // 不上滑就不显示（LP 3139 / 3145）。这页的滚动区忽略了顶部安全区，内容正好压在那条边上，
        // 系统就当成「已经滚上来了」，一进页就挂着一条模糊、往下拉才消失。
        // 关掉之后由上面那条 style 管上滑时出现，回到顶部就没有。
        .scrollEdgeEffectHidden(!showsTopBlur, for: .top)
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
        // 封面要铺到状态栏，所以滚动区从屏幕最上方开始算。
        .ignoresSafeArea(edges: .top)
        // 一行都没拉到（缓存空 + 网络也失败）时给个能重试的页；否则就是顶层一个顶栏的空页。
        .overlay {
            if !controller.isLoading, controller.rows.isEmpty, controller.isFailed {
                failureView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // 先把缓存画出来，再后台刷新（LP 2733 / Ato 2734）：
            // 冷启动不该对着空页等网。
            controller.paintFromCache()
            Task { await controller.load() }
        }
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
