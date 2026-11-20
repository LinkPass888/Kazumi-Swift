//
//  WatchHistoryScreen.swift
//  Kazumi
//
//  对应 lib/pages/history/history_page.dart：全部观看记录，按时间倒序，
//  显示播放进度并可继续观看；支持单条删除与全部清空。
//

import SwiftUI

struct WatchHistoryScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingClear = false
    @State private var isConfirmingBatchDelete = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""

    private var records: [WatchRecord] {
        library.history
            // 位置和时长都是 0 的那类不进列表：加载失败留下的空记录（LP 2026-10-25）。
            // 已经写进本机存储的老记录在这里也被挡掉，不必等它自然过期。
            .filter { $0.progressSeconds > 0 || $0.durationSeconds > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filteredRecords: [WatchRecord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.bangumiName.localizedStandardContains(q)
                || $0.sourceRuleName.localizedStandardContains(q)
        }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无观看历史")
                        .font(.headline)
                    Button("去推荐看看") {
                        router.selectedDestination = .popular
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRecords) { record in
                            card(record)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, isSelecting ? 84 : 24)
                    // 跟设置二级页同一套外壳（Ato 7332/7334）：限宽 700 居中，行内缩 16，行宽 668。
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                // 顶部滚动边缘：渐进模糊（.soft）。
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaInset(edge: .bottom) {
                    if isSelecting {
                        HStack(spacing: 12) {
                            Button(selectedIDs.count == filteredRecords.count ? "取消全选" : "全选") {
                                if selectedIDs.count == filteredRecords.count {
                                    selectedIDs.removeAll()
                                } else {
                                    selectedIDs = Set(filteredRecords.map(\.id))
                                }
                            }
                            .buttonStyle(.bordered)

                            Spacer(minLength: 0)

                            Button(role: .destructive) {
                                isConfirmingBatchDelete = true
                            } label: {
                                Text(selectedIDs.isEmpty
                                    ? String(localized: "删除所选")
                                    : String(localized: "删除所选（\(selectedIDs.count)）"))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedIDs.isEmpty)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
                }
            }
        }
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索番名或规则")
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isSelecting.toggle()
                            selectedIDs.removeAll()
                        }
                    } label: {
                        Text(isSelecting ? "完成" : "选择")
                            .foregroundStyle(Color.primary)
                    }
                }
                if !isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        // 删全部有二次确认兜着，这一颗不用删除红：跟返回按钮一样用系统的
                        // 黑/白（Color.primary），也不跟主题色走。
                        Button {
                            isConfirmingClear = true
                        } label: {
                            Text("清空")
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
            }
        }
        .confirmationDialog("确定清空全部观看历史？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                library.removeHistory(recordIDs: Set(records.map(\.id)))
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "确定删除选中的 \(selectedIDs.count) 条观看历史？"),
            isPresented: $isConfirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("删除所选", role: .destructive) {
                library.removeHistory(recordIDs: selectedIDs)
                selectedIDs.removeAll()
                isSelecting = false
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            KazumiImageLoader.shared.prefetch(library.history.map(\.imageURL))
            // 老记录的名字和封面是空的，读到就补一次（Colo 3566）。
            WatchRecordMetaBackfill.fill(library.history, in: library)
        }
    }

    private func openPlayer(for record: WatchRecord) {
        let cachedSource: PlaybackSource? = {
            guard let url = record.detailURL, !url.isEmpty, !record.sourceRuleName.isEmpty else { return nil }
            return PlaybackSource(
                pluginName: record.sourceRuleName,
                itemName: record.bangumiName,
                detailURL: url,
                directMediaURL: MediaUtility.isMediaURL(url) ? url : nil
            )
        }()
        router.push(.player(
            bangumiID: record.bangumiID,
            episode: record.episodeNumber,
            source: cachedSource,
            // 跟详情页「开始观看」一个口径：线路也接，越界整条作废（Ato 4849）。
            resumeRoad: record.roadIndex,
            resumeFromHistory: true,
            // 按这张卡片这条规则的记录重建播放源，别按番剧号取最新那份（Fuck 4875）。
            resumeRule: record.sourceRuleName
        ))
    }

    private func card(_ record: WatchRecord) -> some View {
        let isSelected = selectedIDs.contains(record.id)
        return Button {
            if isSelecting {
                if isSelected {
                    selectedIDs.remove(record.id)
                } else {
                    selectedIDs.insert(record.id)
                }
            } else {
                openPlayer(for: record)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? KazumiPalette.accent(for: colorScheme) : .secondary)
                }
                poster(record)

                VStack(alignment: .leading, spacing: 6) {
                    Text(record.bangumiName)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(episodeLine(for: record))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // 「看到 12:34」单独一行，在集数正下方（Colo 4895，照 main 的
                    // history_record_tile.dart）：12 号半粗、主题色、等宽数字，
                    // 一小时以上写 1:02:03。没有进度就整行不出现。
                    if let position = record.positionText {
                        Text(position)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            .lineLimit(1)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 0)

                    // 进度条原样留着（LP 4902「进度条不要删」）。
                    KazumiGlassProgressBar(
                        progress: record.fraction,
                        tint: KazumiPalette.accent(for: colorScheme)
                    )

                    // 底部照 main 合成一条：规则名 · 时间。百分比和「已看完」不再出现
                    // ——进度用上面那行具体时长说（LP 4892、Colo 4895）。main 还有
                    // 「在线/缓存」一段，我们只存在线播放的记录，永远同一个值，先不做
                    // （Camo 4897、Colo 4899）。
                    Text(metaLine(for: record))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 右边这一列撑满封面高度，进度条与时间落在卡片底部对齐。
                .frame(height: Self.coverWidth / BangumiPosterCard.coverAspectRatio, alignment: .top)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Colo 3532：灰底页面的卡片只留 groupedRow 实面，不描边。
                KazumiPalette.cardShape(cornerRadius: 20, scheme: colorScheme, bordered: false)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 已看完的从头播，就不能再叫「继续观看」——名字要跟代码做的事一致。
            Button(record.isFinished ? "重新观看" : "继续观看", systemImage: "play.fill") {
                openPlayer(for: record)
            }
            Button("查看番剧详情", systemImage: "info.circle") {
                router.push(.bangumiInfo(bangumiID: record.bangumiID))
            }
            Button("删除记录", systemImage: "trash", role: .destructive) {
                library.removeHistory(recordID: record.id)
            }
        }
    }

    /// 封面：宽高都给死，圆形角与海报卡同一套。右下角那颗小三角是「接着看」的意思。
    private func poster(_ record: WatchRecord) -> some View {
        BangumiRemoteImage(url: record.imageURL)
            .frame(width: Self.coverWidth, height: Self.coverWidth / BangumiPosterCard.coverAspectRatio)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: record.isFinished ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(6)
            }
    }

    private static let coverWidth: CGFloat = 84

    /// 「第 1 集」或「第 1 集 · 标题」：有集标题就用集标题，没有就退回集数。
    private func episodeLine(for record: WatchRecord) -> String {
        let number = String(localized: "第 \(String(describing: record.episodeNumber)) 集")
        let title = record.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // 老记录里的集标题是「第 N 话」（LP 4824「已经记录的就算了」，不迁移数据），
        // 跟新的「第 N 集」并排比一次，别把同一句话拼成「第 3 集 · 第 3 话」。
        let legacy = String(localized: "第 \(String(describing: record.episodeNumber)) 话")
        return title.isEmpty || title == number || title == legacy ? number : "\(number) · \(title)"
    }

    /// 底部那条：规则名 · 时间（Colo 4895）。规则名为空就只写时间。
    private func metaLine(for record: WatchRecord) -> String {
        let time = whenText(record.updatedAt)
        let rule = record.sourceRuleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return rule.isEmpty ? time : "\(rule) · \(time)"
    }

    /// 时间用相对说法：今天 / 昨天 / 具体日期，扫一眼就知道新旧。
    /// 语言固定中文（Camo 4914：跟着手机语言走，英文手机上会漏出「6:00 PM」）。
    private func whenText(_ date: Date) -> String {
        KazumiTimeText.relative(date)
    }
}

