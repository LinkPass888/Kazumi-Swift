//
//  DownloadScreen.swift
//  Kazumi
//
//  「下载管理」：按番列出下载记录，每集的状态、进度、文件大小都在这里。
//
//  以前这页是去文件夹里数文件（老实现），下载记录根本没读，所以下完也看不见。
//  现在直接读 DownloadCenter.records——记录是唯一的事实来源，文件由它指向。
//
//  结构（Colo 5174/5176 v2）：换成 List，因为左滑删除只有 List 行才有。
//    * 已下载那行点整行就播（放本地文件），行尾留一颗播放键
//    * 删除全在左滑里：滑一集删一集，滑番剧名删这一部全部
//    * 长按一集进多选，底部出「删除所选 / 全选 / 取消」
//  外观尽量保住：实面、圆角、不分隔线，跟分组页一个口径。
//

import SwiftUI

struct DownloadScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router

    private var downloads: DownloadCenter { environment.downloads }

    /// 展开着的番（默认都展开；收起为了长列表好翻）。
    @State private var collapsed: Set<String> = []
    @State private var pendingDelete: DownloadRecord?
    /// 多选态：选中的键是「记录 id#集号」。
    @State private var isSelecting = false
    @State private var selection: Set<String> = []

    var body: some View {
        Group {
            if downloads.records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        // LP 5198：多选不再靠长按，右上角给一颗「编辑」。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "完成" : "编辑") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isSelecting.toggle()
                        selection.removeAll()
                    }
                }
                .disabled(downloads.records.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting { selectionBar }
        }
        // 只删记录也要问一句：连同文件一起删，捡不回来。
        .confirmationDialog(
            "删除「\(pendingDelete?.title ?? "")」的全部下载？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let record = pendingDelete { downloads.removeRecord(record) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("这一部已经下好的文件会一起删掉。")
        }
    }

    private var list: some View {
        List {
            ForEach(downloads.records) { record in
                Section {
                    header(record)
                    if !collapsed.contains(record.id) {
                        ForEach(record.episodes) { episode in
                            episodeRow(record: record, episode: episode)
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // 多选时不要再让人点到左滑删除：误触会删文件。
        .environment(\.defaultMinListRowHeight, 44)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("暂无下载")
                .font(.headline)
            Text("在剧集列表点下载按钮缓存整部番，下好的会出现在这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 多选底栏

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button("取消") {
                withAnimation(.easeOut(duration: 0.15)) {
                    isSelecting = false
                    selection.removeAll()
                }
            }
            .font(.subheadline)

            Spacer(minLength: 0)

            Button(allSelectedForSelection() ? "取消全选" : "全选") {
                selectAll()
            }
            .font(.subheadline)
            .disabled(allSelectableNumbers().isEmpty)

            // Colo 5190：危险动作要看出危险——红底白字实心，不是红字。
            Button {
                deleteSelected()
            } label: {
                Text(selection.isEmpty ? "删除" : String(localized: "删除所选 \(String(describing: selection.count)) 集"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            // 没选中时灰底，别用浅红：白字在浅红上看不清。
                            .fill(selection.isEmpty ? Color(.tertiarySystemFill) : Color.red)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 一部番

    private func header(_ record: DownloadRecord) -> some View {
        let done = record.episodes.filter(\.isPlayableOffline).count
        let total = record.episodes.count
        let running = record.episodes.contains { $0.status.isActive }

        return HStack(spacing: 10) {
            Button {
                // LP 5482：编辑时点番剧名就该把这部番的集全选上，别只能一集一集点。
                if isSelecting {
                    toggleSelection(for: record)
                    return
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    if collapsed.contains(record.id) { collapsed.remove(record.id) }
                    else { collapsed.insert(record.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title.isEmpty ? "未命名番剧" : record.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        // Colo 5174：卡片头写总占用空间。
                        Text(subtitle(record: record, done: done, total: total, running: running))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if isSelecting {
                        // 编辑态：勾 / 半勾 / 空，一眼看出这部是整部选中还是只选了几集。
                        Image(systemName: recordSelectionSymbol(record))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(
                                recordSelectionIsEmpty(record) ? Color.secondary : Color.accentColor
                            )
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed.contains(record.id) ? -90 : 0))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button(role: .destructive) {
                    pendingDelete = record
                } label: {
                    Label("删除", systemImage: "trash")
                }
                // LP 5189：删除用系统删的红，不要跟主题色。
                .tint(.red)
            }
        }
    }

    private func subtitle(record: DownloadRecord, done: Int, total: Int, running: Bool) -> String {
        let count = String(localized: "\(String(describing: done))/\(String(describing: total)) 集")
        let size = ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file)
        let body = record.totalBytes > 0 ? "\(count) · \(size)" : count
        if running {
            return String(localized: "下载中 · \(String(describing: body))")
        }
        if done == total, total > 0 {
            return String(localized: "已下载完 · \(String(describing: body))")
        }
        return body
    }

    // MARK: - 一集

    @ViewBuilder
    private func episodeRow(record: DownloadRecord, episode: DownloadEpisode) -> some View {
        let key = selectionKey(record: record, number: episode.number)
        let isSelected = selection.contains(key)

        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            } else {
                statusIcon(episode)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(statusText(episode))
                    .font(.caption)
                    .foregroundStyle(episode.status == .failed ? Color.red : .secondary)
                    .lineLimit(2)
                if episode.status == .downloading || episode.status == .resolving {
                    ProgressView(value: max(0, min(1, episode.progress)))
                        .tint(KazumiPalette.accent(for: colorScheme))
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)

            // 多选时行尾动作全隐藏，免得跟勾选打架（Colo 5176）。
            // 已下载那行不放播放按钮：点整行就是播（Colo v3），行尾只留下载相关的动作。
            if !isSelecting {
                trailingAction(record: record, episode: episode)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture {
            if isSelecting {
                toggleSelection(key)
            } else {
                // 点任意一集都能进播放器（Colo v3）：本地有文件就放本地，
                // 没有就走在线解析，不会点了没动静。
                play(record: record, episode: episode)
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            guard !isSelecting else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                isSelecting = true
                selection = [key]
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button(role: .destructive) {
                    downloads.removeEpisode(recordKey: record.id, number: episode.number)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                // LP 5189：删除用系统删的红，不要跟主题色。
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ episode: DownloadEpisode) -> some View {
        // LP 5196：下载中、排队、暂停都是「加进下载但没下完」，统一用虚线下箭头；
        // 下完的实心，失败一颗感叹号。行下方那行小字仍然写清具体状态。
        // LP 5213：符号不用主题色，跟文字一个色。
        switch episode.status {
        case .downloading, .resolving, .paused, .pending:
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.primary)
        case .completed where episode.fileName != nil:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.primary)
        // 记录说下完、文件却不在：跟其他没下完的一个符号，别让行里留一个放不了的实心勾。
        case .completed:
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.primary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }

    private func statusText(_ episode: DownloadEpisode) -> String {
        switch episode.status {
        case .pending:
            return String(localized: "排队中")
        case .resolving:
            return String(localized: "正在解析播放地址")
        case .downloading:
            let percent = Int((episode.progress * 100).rounded())
            let size = ByteCountFormatter.string(fromByteCount: episode.totalBytes, countStyle: .file)
            return episode.totalBytes > 0 ? String(localized: "下载中 \(String(describing: percent))% · \(String(describing: size))") : String(localized: "下载中 \(String(describing: percent))%")
        case .paused:
            return String(localized: "已暂停")
        case .completed:
            // 文件不在时大小是假的，写清楚能重下，别只写一个数。
            guard episode.fileName != nil else { return String(localized: "文件不在，可重新下载") }
            return ByteCountFormatter.string(fromByteCount: episode.totalBytes, countStyle: .file)
        case .failed:
            // 失败原因直接说，不再只画个红点。
            return episode.errorMessage ?? String(localized: "下载失败")
        }
    }

    /// 一集能做的事：失败了重试、跑着暂停、暂停继续。删除在左滑里。
    @ViewBuilder
    private func trailingAction(record: DownloadRecord, episode: DownloadEpisode) -> some View {
        switch episode.status {
        case .failed:
            Button("重试") {
                downloads.enqueue(
                    bangumiID: record.bangumiID,
                    title: record.title,
                    coverURL: record.coverURL,
                    pluginName: record.pluginName,
                    road: record.road,
                    episodes: [(number: episode.number, title: episode.title, pageURL: episode.pageURL)]
                )
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        case .downloading, .resolving, .pending:
            Button {
                downloads.cancel(recordKey: record.id, numbers: [episode.number])
            } label: {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .paused:
            Button {
                downloads.enqueue(
                    bangumiID: record.bangumiID,
                    title: record.title,
                    coverURL: record.coverURL,
                    pluginName: record.pluginName,
                    road: record.road,
                    episodes: [(number: episode.number, title: episode.title, pageURL: episode.pageURL)]
                )
            } label: {
                Image(systemName: "play.circle")
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            }
            .buttonStyle(.plain)
        case .completed where episode.fileName == nil:
            // 文件不在了：给一条重下的路，不然这集只能看着、既放不了也重下不了。
            Button("重下") {
                downloads.enqueue(
                    bangumiID: record.bangumiID,
                    title: record.title,
                    coverURL: record.coverURL,
                    pluginName: record.pluginName,
                    road: record.road,
                    episodes: [(number: episode.number, title: episode.title, pageURL: episode.pageURL)]
                )
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        case .completed:
            EmptyView()
        }
    }

    // MARK: - 播放

    /// 放本地那份文件（Colo 5174）。播放器里先看本地，有就跳过解析。
    private func play(record: DownloadRecord, episode: DownloadEpisode) {
        // detailURL 要的是**条目身份**，不是这集的地址：接口模式的规则把它当 vod_id 发给站点，
        // 站点只收数字 id（LP 5512 的规则：sourcePath = $.vod_id，vod_id = @source）。
        // 这里原来塞的是 episode.pageURL（这一集的 m3u8），抓包里就成了
        // `get_detail?vod_id=<m3u8 地址>` → code 1001「vod_id必须是数字」（LP 5508）。
        // 老记录没存 itemSource，退回 pageURL 保持原样，至少不比以前更差。
        let identity = record.itemSource.isEmpty ? episode.pageURL : record.itemSource
        router.push(.player(
            bangumiID: record.bangumiID,
            episode: episode.number,
            source: PlaybackSource(
                pluginName: record.pluginName,
                itemName: record.title,
                detailURL: identity,
                directMediaURL: nil
            ),
            resumeRoad: record.road,
            resumeFromHistory: false,
            resumeRule: record.pluginName
        ))
    }

    // MARK: - 多选

    private func selectionKey(record: DownloadRecord, number: Int) -> String {
        "\(record.id)#\(number)"
    }

    private func toggleSelection(_ key: String) {
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }

    /// 能选的：记录里所有集（正在下载的也能删，removeEpisode 先取消再删）。
    private func allSelectableNumbers() -> Set<String> {
        var keys: Set<String> = []
        for record in downloads.records {
            for episode in record.episodes {
                keys.insert(selectionKey(record: record, number: episode.number))
            }
        }
        return keys
    }

    /// 这部番的全部集键。
    private func selectionKeys(for record: DownloadRecord) -> Set<String> {
        Set(record.episodes.map { selectionKey(record: record, number: $0.number) })
    }

    private func recordSelectionIsEmpty(_ record: DownloadRecord) -> Bool {
        selectionKeys(for: record).isDisjoint(with: selection)
    }

    private func recordSelectionIsFull(_ record: DownloadRecord) -> Bool {
        let keys = selectionKeys(for: record)
        return !keys.isEmpty && keys.isSubset(of: selection)
    }

    private func recordSelectionSymbol(_ record: DownloadRecord) -> String {
        if recordSelectionIsFull(record) { return "checkmark.circle.fill" }
        if recordSelectionIsEmpty(record) { return "circle" }
        return "minus.circle.fill"
    }

    /// 点番剧名：整部没选满就全选，已经选满就整部取消。
    private func toggleSelection(for record: DownloadRecord) {
        let keys = selectionKeys(for: record)
        withAnimation(.easeOut(duration: 0.15)) {
            if keys.isSubset(of: selection) {
                selection.subtract(keys)
            } else {
                selection.formUnion(keys)
            }
        }
    }

    private func selectAll() {
        let all = allSelectableNumbers()
        if selection.count >= all.count {
            selection.removeAll()
        } else {
            selection = all
        }
    }

    /// 全选之后标签要变成「取消全选」，跟播放器格子那边一个口径。
    private func allSelectedForSelection() -> Bool {
        let all = allSelectableNumbers()
        return !all.isEmpty && selection.count >= all.count
    }

    private func deleteSelected() {
        for record in downloads.records {
            let numbers = record.episodes
                .filter { selection.contains(selectionKey(record: record, number: $0.number)) }
                .map(\.number)
            if !numbers.isEmpty {
                downloads.removeEpisodes(recordKey: record.id, numbers: numbers)
            }
        }
        withAnimation(.easeOut(duration: 0.15)) {
            selection.removeAll()
            isSelecting = false
        }
    }
}
