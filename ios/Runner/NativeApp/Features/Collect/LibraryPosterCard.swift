//
//  LibraryPosterCard.swift
//  Kazumi
//
//  追番页「卡片」布局的一颗海报卡片（specs 见
//  design/kazumi-library-cards-spec.md §四）：
//  * 竖版海报（宽高比 0.65）在上，标题在下；
//  * 整张卡片任意位置都能点开详情，只有封面右下角那颗状态钮例外；
//  * 那颗钮画的是当前追番状态本身（在看一颗心、想看一颗星…），
//    贴在封面角上而不是页脚——页脚放它要占 26 点，等于每个标题少两个字。
//

import SwiftUI

struct LibraryPosterCard: View {
    let entry: LibraryEntry
    /// 正在改收藏状态：菜单降到 0.4 并禁用，卡片本身仍可点。
    let isPending: Bool
    /// 卡片 → 详情页缩放转场所属的命名空间（由所在导航栈提供）。
    var zoomNamespace: Namespace.ID?
    var onOpen: () -> Void
    var onChangeType: (CollectType) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 封面宽高比，与 `BangumiPosterCard.coverAspectRatio` 同一套。
    private static let coverAspectRatio = BangumiPosterCard.coverAspectRatio
    /// 海报圆角：跟推荐页同一个值（Colo 3501 §二）。原来跟着卡片走 18，
    /// 卡片底去掉之后海报自己就是主体，圆角按海报算。
    private static let coverCornerRadius: CGFloat = PopularPosterTile.cornerRadius
    /// 标题两行的高度。跟着动态字体走：写死 34 的话，最大字号那一档
    /// 标题会长到页脚外面去。默认档量出来仍是 34，屏上不变。
    @ScaledMetric(relativeTo: .footnote) private var titleBlockHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Colo 3501 §二：卡底和 18 圆角整个去掉——这一格和推荐页是同一件事
        // （海报＋名字），海报自己就是主体，不需要再包一层底。
        // 交互没动：整卡命中区、缩放转场、读屏标签与六项操作都留在下面。
        // LP 2026-10-24：进详情页要整张卡片放大，不是只有封面。
        .kazumiZoomSource(id: entry.id, namespace: zoomNamespace)
        // 整格（海报、名字、空白）都是命中区。
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        // 整卡合成一个元素。读屏念到这张卡时听到的是「片名，在看」——
        // 这是状态唯一念得出来的地方，不许撤。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        // 角上那颗钮被合成掉了，读屏够不到它，所以把菜单里的事做成这张卡的操作：
        // 五项状态名，最后一项是动作名「取消追番」。
        .accessibilityActions {
            ForEach(CollectType.enabledCases) { type in
                Button(type.buttonTitle) { onChangeType(type) }
            }
            Button("取消追番") { onChangeType(.none) }
        }
    }

    // MARK: - 封面

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            // 先立一个比例确定的框（宽由网格给，高 = 宽 / 0.65），再把图铺满它。
            // 直接把图 .aspectRatio(.fit) 是不行的：`BangumiRemoteImage` 会
            // 铺满可用空间（maxHeight 无限），网格里每张封面各长各的，行就叠在一起。
            Color.clear
                .aspectRatio(Self.coverAspectRatio, contentMode: .fit)
                .overlay {
                    BangumiRemoteImage(url: entry.imageURL)
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.coverCornerRadius, style: .continuous))

            statusMenu
                .padding(6)
        }
    }

    private var statusMenu: some View {
        // 菜单里面那份和详情页共用 `CollectStatusMenu`；外面这颗只画符号。
        CollectStatusMenu(current: entry.collectType, onChange: onChangeType) {
            // LP 2026-10-24：不用三个点，直接画当前的追番状态（在看那颗心、想看那颗星…），
            // 一眼就知道这部现在是什么状态；点它还是开菜单改状态。
            // LP 2026-10-24 晚：符号改主题色——白底圆 + 主题色符号，浅色封面上也看得清。
            // LP 2026-10-25：底改成半透明，并且跟着深浅色模式走。
            // 原来写死 `Color.white`：浅色下是块死白、深色下更是突兀的一块白，
            // 也不透封面。改用材质——浅色是磨砂白、深色是磨砂黑，本身带透明度，
            // 封面的颜色透得上来；描边只用来在浅色封面上保住轮廓。
            Image(systemName: entry.collectType.statusSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                .hitTarget44()
                .opacity(isPending ? 0.4 : 1)
        }
        // 这里本来还有一句 .accessibilityLabel("…，修改追番状态")：念不到——
        // 整张卡是 .accessibilityElement(children: .ignore)，子元素的名字被合掉了。
        // 那颗钮该说的话由上面卡片的标签（「片名，在看」）和六项操作来说，
        // 所以整行删掉，不留一个改得再准也没人读的第二出处。
        .disabled(isPending)
    }

    // MARK: - 页脚

    /// 页脚只有标题。LP 2026-10-24：卡片上不显示评分；Ato 同日定：
    /// 状态已经在封面角上那颗符号上了，同一张卡不说两遍，
    /// 所以原来那行元信息（评分 / 状态名）整行去掉，也不留一条空横线。
    private var footer: some View {
        // Colo 3501 §二：12pt 常规、黑色、两行，离海报 6 点，块高 34，
        // 左右不留内边距（跟海报同宽）。
        // Colo 3519 改口：追番页是 3 列网格、每格 114 宽，名字改成左对齐——
        // 每张都从海报左缘起，竖着扫下来是一条直线；居中反而长短不齐更乱。
        // 推荐页那条货架还是居中，两页不一样是有意的。
        Text(entry.displayName)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .lineSpacing(1.3 * 12 - 12)
            .multilineTextAlignment(.leading)
            // `frame` 没有「无限宽 + 定高」这个组合，分开写：
            // 先定高、顶部对齐，再撑满整格宽度。
            .frame(height: titleBlockHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 6)
    }

    /// 与屏上同一句话：卡片上不显示评分，念出来的也不念；
    /// 状态名必须留着——角上那颗钮读屏念不到。
    private var accessibilityLabel: String {
        [entry.displayName, entry.collectType.title].joined(separator: "，")
    }
}
