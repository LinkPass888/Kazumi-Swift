//
//  PopularListScreen.swift
//  Kazumi
//
//  「更多」的落点（Colo 规格 §4）：一行货架点进来，看这一组的全部。
//
//  承载的是原来推荐页那套网格——3 列（>600 五列、>840 六列）、滚到底续接、
//  右下角回到顶部。续接从货架挪到这里：横向货架没有「滚到底」这回事。
//
//  三个数据源的续接方式不同：
//  * 趋势榜：`trends` 按 offset 续接；
//  * 本季新番：季度接口一次给全季，不需要续接；
//  * 综合排名：`ranked` 按固定名次区间 + offset 续接；
//  * 标签：镜像按 offset 续接；镜像关掉时官方接口只能取一页（名次随机），
//    那种源本来就不进首页，这里也只在镜像开着时才铺行，见 PopularScreen。
//

import SwiftUI

struct PopularListScreen: View {
    let source: PopularListSource
    var zoomNamespace: Namespace.ID?

    @State private var controller: Controller
    @Environment(\.colorScheme) private var colorScheme

    init(source: PopularListSource, zoomNamespace: Namespace.ID? = nil) {
        self.source = source
        self.zoomNamespace = zoomNamespace
        _controller = State(initialValue: Controller(source: source))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(controller.items) { item in
                        BangumiPosterCard(
                            item: item,
                            width: posterWidth,
                            titleAreaHeight: 32,
                            zoomNamespace: zoomNamespace
                        )
                        .frame(width: posterWidth, height: cardHeight, alignment: .top)
                        .id(item.id)
                        .task {
                            await controller.loadMoreIfNeeded(current: item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 72)

                if controller.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay(alignment: .bottomTrailing) {
                if !controller.items.isEmpty {
                    scrollToTop {
                        withAnimation(.easeOut(duration: 0.35)) {
                            proxy.scrollTo(controller.items.first?.id, anchor: .top)
                        }
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .overlay {
            if controller.items.isEmpty && controller.isFailed {
                failureView
            }
        }
        .task {
            await controller.loadFirstPage()
        }
    }

    private var failureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("列表没能加载")
                .font(.headline)
            Text("网络好像不太顺，点一下重新加载。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新加载") {
                Task { await controller.loadFirstPage() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func scrollToTop(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .kazumiGlassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityLabel("回到顶部")
    }

    // MARK: - 网格尺寸（与改版前的推荐页同一套算式）

    private var columnCount: Int {
        let width = containerWidth
        if width > KazumiLayout.mediumWidth { return 6 }
        if width > KazumiLayout.compactWidth { return 5 }
        return 3
    }

    private var posterWidth: CGFloat {
        KazumiLayout.posterColumnWidth(
            containerWidth: containerWidth,
            columns: columnCount,
            spacing: 8,
            padding: 8
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(posterWidth), spacing: 8, alignment: .top),
            count: columnCount
        )
    }

    private var cardHeight: CGFloat {
        KazumiLayout.posterHeight(width: posterWidth) + 32
    }

    private var containerWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
    }
}

// MARK: - 控制器

extension PopularListScreen {
    @MainActor
    @Observable
    final class Controller {
        private(set) var items: [BangumiItem] = []
        private(set) var isLoadingMore = false
        private(set) var isFailed = false

        private let source: PopularListSource
        private var offset = 0
        private var reachedEnd = false
        private static let pageSize = 24

        init(source: PopularListSource) {
            self.source = source
        }

        func loadFirstPage() async {
            // `.task` 在这页上从详情页返回时会再跑一次（视图消失时任务被取消，
            // 重新出现时重建）。以前这里无条件 `items.removeAll()`：第一页只要不是
            // 立刻回来（冷缓存 / 慢网），网格先空一帧，ScrollView 的偏移被夹回 0，
            // 数据回来就从顶上重新铺——#29 报的「左滑返回有概率回到列表顶部」。
            // 已经有内容就不再重来：这一页只在首次进入时取。
            guard Self.shouldReloadFirstPage(itemCount: items.count) else { return }
            items.removeAll()
            offset = 0
            reachedEnd = false
            isFailed = false
            await loadNext()
        }

        /// 首次取数到底要不要真的去取。抽成纯函数便于单测：
        /// 列表里已经有内容时返回 false，空列表（首进 / 上次失败）返回 true。
        nonisolated static func shouldReloadFirstPage(itemCount: Int) -> Bool {
            itemCount == 0
        }

        func loadMoreIfNeeded(current item: BangumiItem) async {
            guard !isLoadingMore, !reachedEnd else { return }
            guard let index = items.firstIndex(where: { $0.id == item.id }),
                  index >= items.count - 8 else { return }
            await loadNext()
        }

        private func loadNext() async {
            guard !isLoadingMore, !reachedEnd else { return }
            isLoadingMore = true
            let page: [BangumiItem]?
            switch source {
            case .trending:
                page = BangumiAcceleration.isMirrorEnabled
                    ? await BangumiAPI.mirrorPopular(limit: Self.pageSize, offset: offset)
                    : await BangumiAPI.trends(limit: Self.pageSize, offset: offset)
            case .ranked:
                page = await BangumiAPI.ranked(limit: Self.pageSize, offset: offset)
            case .collected:
                page = await BangumiAPI.collected(limit: Self.pageSize, offset: offset)
            case .season:
                // 季度接口一次给全季，没有 offset。
                let range = AnimeSeason.seasonRange(for: Date())
                let groups = await BangumiAPI.mirrorSeasonCalendar(start: range.start, end: range.end)
                page = groups.flatMap { $0 }
                reachedEnd = true
            case .tag(let tag):
                page = BangumiAcceleration.isMirrorEnabled
                    ? await BangumiAPI.mirrorPopular(tag: tag, limit: Self.pageSize, offset: offset)
                    // 镜像关掉时官方接口只能取一页（名次随机），取完就到底。
                    : await BangumiAPI.listByTag(rank: Int.random(in: 1...8000), tag: tag)
            }

            // 取数失败不能当成"到底了"，否则这一页永远不再重试。
            guard let page else {
                isLoadingMore = false
                isFailed = items.isEmpty
                return
            }
            if page.isEmpty {
                reachedEnd = true
            } else {
                var existing = Set(items.map(\.id))
                for item in page where existing.insert(item.id).inserted {
                    items.append(item)
                }
                offset += page.count
            }
            if case .tag = source, !BangumiAcceleration.isMirrorEnabled { reachedEnd = true }
            isLoadingMore = false
            isFailed = items.isEmpty
        }
    }
}
