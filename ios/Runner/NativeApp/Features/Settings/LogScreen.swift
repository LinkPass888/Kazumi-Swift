//
//  LogScreen.swift
//  Kazumi
//
//  对应 lib/pages/settings 中的日志入口：把 os.Logger 的子系统日志聚合展示，
//  方便用户反馈问题时复制。这里改用运行期日志缓冲（KazumiLogBuffer），
//  因为 os.Logger 的日志无法被 App 自身读回。
//

import SwiftUI

struct LogScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var entries: [KazumiLogBuffer.Entry] = []
    @State private var filter = LogFilter.all
    @State private var searchText = ""
    @State private var isConfirmingClear = false

    enum LogFilter: Hashable, Identifiable {
        case all
        case category(KazumiLogBuffer.Category)

        var id: String {
            switch self {
            case .all: "all"
            case .category(let cat): cat.id
            }
        }

        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .category(let cat): cat.title
            }
        }

        static var allFilters: [LogFilter] {
            [.all] + KazumiLogBuffer.Category.allCases.map { .category($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("分类", selection: $filter) {
                ForEach(LogFilter.allFilters) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "暂无日志" : "未找到匹配日志")
                        .font(.headline)
                    Text(searchText.isEmpty ? "执行搜索、选源或播放后，这里会出现记录。" : "尝试更换搜索关键词或切换分类。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(entry.category.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(Color.secondary.opacity(0.15))
                                        )
                                }
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                KazumiPalette.cardShape(cornerRadius: 10, scheme: colorScheme, bordered: false)
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .searchable(text: $searchText, prompt: "搜索日志")
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("复制全部") {
                        UIPasteboard.general.string = KazumiLogExport.text(from: filtered)
                    }
                    Button("清空", role: .destructive) { isConfirmingClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(clearDialogTitle, isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                switch filter {
                case .all:
                    KazumiLogBuffer.shared.clearAll()
                case .category(let cat):
                    KazumiLogBuffer.shared.clear(cat)
                }
                refresh()
            }
            Button("取消", role: .cancel) {}
        }
        .task { refresh() }
    }

    private var clearDialogTitle: String {
        switch filter {
        case .all: String(localized: "确定清空全部运行日志？")
        case .category(let cat): String(localized: "确定清空「\(cat.title)」分类的日志？")
        }
    }

    private var filtered: [KazumiLogBuffer.Entry] {
        entries.filter { entry in
            let matchesCategory: Bool
            switch filter {
            case .all: matchesCategory = true
            case .category(let cat): matchesCategory = (entry.category == cat)
            }
            guard matchesCategory else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(query)
        }
    }

    private func refresh() {
        entries = KazumiLogBuffer.shared.snapshot()
    }
}
