//
//  SearchHistoryScreen.swift
//  Kazumi
//
//  对应 lib/pages/search 中的搜索历史区：展示最近搜索词（保留 10 条），
//  点击即可重新搜索，支持单条删除与全部清空。隐私模式下不记录历史。
//

import SwiftUI

struct SearchHistoryScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    @State private var histories: [String] = []
    @State private var isConfirmingClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if histories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("暂无搜索历史")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(histories, id: \.self) { keyword in
                            row(keyword)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
                // 顶部滚动边缘：渐进模糊（.soft）。
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("搜索历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !histories.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { isConfirmingClear = true }
                }
            }
        }
        .confirmationDialog("确定清空搜索历史？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                SearchHistoryStore.clear()
                histories = []
            }
            Button("取消", role: .cancel) {}
        }
        .task { histories = SearchHistoryStore.load() }
    }

    private func row(_ keyword: String) -> some View {
        Button {
            router.push(.search(keyword: keyword))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(keyword)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(
                KazumiPalette.cardShape(cornerRadius: 14, scheme: colorScheme)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除", role: .destructive) {
                SearchHistoryStore.remove(keyword)
                histories = SearchHistoryStore.load()
            }
        }
    }
}

/// 搜索历史存储（对应 search_history_repository：最多 10 条、去重、新的在最前）。
enum SearchHistoryStore {
    private static let key = "kazumi.settings.searchHistory"
    private static let limit = 10

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = load().filter { $0 != trimmed }
        items.insert(trimmed, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        UserDefaults.standard.set(items, forKey: key)
    }

    static func remove(_ keyword: String) {
        UserDefaults.standard.set(load().filter { $0 != keyword }, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

