//
//  PluginImportSheet.swift
//  Kazumi
//
//  粘贴导入：接受整表 JSON、单条 JSON 或 kazumi:// 规则链接，
//  预览解析结果（成功 / 失败 / 覆盖）后再确认写入。
//

import SwiftUI

struct PluginImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme

    /// 由调用方执行真正的写入（包含错误提示）。
    let onConfirm: (PluginImportSummary) async -> Void

    @State private var text = ""
    @State private var summary: PluginImportSummary?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("粘贴规则 JSON 或 kazumi:// 链接。支持一次导入多条，也支持夹在聊天文本里的链接。")
                        .font(.callout)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))

                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("在此粘贴…")
                                    .font(.footnote)
                                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 12) {
                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                text = clipboard
                                analyze()
                            }
                        } label: {
                            Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            text = ""
                            summary = nil
                        } label: {
                            Label("清空", systemImage: "xmark.circle")
                        }
                        .disabled(text.isEmpty)
                    }
                    .buttonStyle(.bordered)

                    if let summary { preview(summary) }
                }
                .padding(20)
            }
            .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle("导入规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        guard let summary, !summary.isEmpty else { return }
                        isImporting = true
                        Task {
                            await onConfirm(summary)
                            isImporting = false
                            dismiss()
                        }
                    }
                    .disabled(isImporting || summary == nil || summary?.isEmpty == true)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: text) { _, _ in analyze() }
    }

    @ViewBuilder
    private func preview(_ summary: PluginImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "可导入 \(String(describing: summary.plugins.count)) 条"), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            if summary.duplicateCount > 0 {
                Label(String(localized: "合并重复 \(String(describing: summary.duplicateCount)) 条"), systemImage: "arrow.triangle.merge")
            }
            if !summary.replacedNames.isEmpty {
                let nameList = summary.replacedNames.prefix(3).joined(separator: "、")
                let more = summary.replacedNames.count > 3 ? String(localized: " 等") : ""
                Label(String(localized: "将覆盖同名规则：\(nameList)\(more)"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(summary.failures.prefix(3), id: \.self) { failure in
                Label(failure, systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
            if summary.plugins.count > 3 {
                Text(summary.plugins.prefix(3).map(\.name).joined(separator: "、") + String(localized: " 等"))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            }
        }
        .font(.footnote)
    }

    private func analyze() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            summary = nil
            return
        }
        summary = PluginImportExport.importResult(for: trimmed, existing: plugins.pluginList)
    }
}
