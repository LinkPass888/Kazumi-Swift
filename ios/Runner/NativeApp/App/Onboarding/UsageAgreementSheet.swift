//
//  UsageAgreementSheet.swift
//  Kazumi
//
//  完整「使用约定」的 sheet。
//

import SwiftUI

struct UsageAgreementSheet: View {
    let loadState: UsageAgreement.LoadState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading:
                    ProgressView("正在载入使用约定…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let paragraphs):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .failed:
                    ContentUnavailableView(
                        "使用约定载入失败",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("请重新打开 Kazumi 后再试。")
                    )
                }
            }
            .navigationTitle("使用约定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
