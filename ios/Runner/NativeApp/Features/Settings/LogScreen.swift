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
    @State private var category = KazumiLogBuffer.Category.plugin
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("分类", selection: $category) {
                ForEach(KazumiLogBuffer.Category.allCases) { item in
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
                    Text("暂无日志")
                        .font(.headline)
                    Text("执行搜索、选源或播放后，这里会出现记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospaced())
                                    // Colo 3532：说明/辅助文字用 secondary，tertiary 只留给装饰。
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                // Colo 3532：灰底页面的日志卡只留 groupedRow 实面，不描边。
                                KazumiPalette.cardShape(cornerRadius: 10, scheme: colorScheme, bordered: false)
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                // 顶部滚动边缘：日志列表顶部用渐进模糊（.soft）。
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
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
        .confirmationDialog("确定清空该分类的日志？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                KazumiLogBuffer.shared.clear(category)
                refresh()
            }
            Button("取消", role: .cancel) {}
        }
        .task { refresh() }
    }

    private var filtered: [KazumiLogBuffer.Entry] {
        entries.filter { $0.category == category }
    }

    private func refresh() {
        entries = KazumiLogBuffer.shared.snapshot()
    }
}

