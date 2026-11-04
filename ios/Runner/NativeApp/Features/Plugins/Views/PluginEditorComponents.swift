//
//  PluginEditorComponents.swift
//  Kazumi
//
//  编辑器里复用的小部件：玻璃卡片容器与统一风格的输入框。
//

import SwiftUI

/// 一组相关字段的卡片。
/// LP 2026-10-24：编辑器中间这块不要液态玻璃了，换成普通卡片底色 + 一圈细描边。
struct EditorCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            KazumiPalette.cardShape(cornerRadius: 20, scheme: colorScheme)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

/// 带标题的文本输入。多行时用 TextEditor，单行时用 TextField。
struct EditorTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var multiline = false
    var monospaced = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            if multiline {
                TextEditor(text: $text)
                    .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && !prompt.isEmpty {
                            Text(prompt)
                                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                TextField(prompt, text: $text)
                    .font(monospaced ? .system(.footnote, design: .monospaced) : .callout)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
