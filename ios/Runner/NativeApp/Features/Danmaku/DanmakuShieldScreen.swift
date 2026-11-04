//
//  DanmakuShieldScreen.swift
//  Kazumi
//
//  对应 lib/pages/settings/danmaku/danmaku_shield_settings.dart：
//  遮罩词按行保存，支持普通词（包含匹配）与正则（`/pattern/` 语法），
//  保存在 settings 的 danmakuFilterRules 键下，与 Flutter 版同名互通。
//

import SwiftUI

struct DanmakuShieldScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var rules: [String] = []
    @State private var newRule = ""
    @State private var isRegex = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    Text("添加屏蔽词")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("输入要屏蔽的文字", text: $newRule)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                // Colo 3532：灰底页面的输入框只留 groupedRow 实面，不描边。
                                KazumiPalette.cardShape(cornerRadius: 12, scheme: colorScheme, bordered: false)
                            )

                        Toggle("正则", isOn: $isRegex)
                            .labelsHidden()
                            .accessibilityLabel("作为正则表达式")
                    }

                    Button {
                        addRule()
                    } label: {
                        Text(isRegex ? "添加正则规则" : "添加屏蔽词")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(.white)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(newRule.isEmpty ? Color.gray : KazumiPalette.accent(for: colorScheme))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(newRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ruleList
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // 顶部滚动边缘：渐进模糊（.soft），不另外加材质或底色。
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("弹幕屏蔽")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadRules()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("屏蔽规则")
                .font(.headline)
            Text("每行一条。正则用 /pattern/ 包裹；命中任一条的弹幕不会显示。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ruleList: some View {
        if rules.isEmpty {
            Text("还没有屏蔽规则")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(spacing: 8) {
                ForEach(rules, id: \.self) { rule in
                    HStack(spacing: 10) {
                        Text(rule.hasPrefix("/") ? ".*" : "abc")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(rule)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            remove(rule)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除规则")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        KazumiPalette.cardShape(cornerRadius: 12, scheme: colorScheme, bordered: false)
                    )
                }
            }
        }
    }

    // MARK: - 存取

    private var storageKey: String { "kazumi.settings." + SettingsKey.danmakuFilterRules }

    private func loadRules() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        rules = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addRule() {
        let trimmed = newRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let rule = isRegex ? "/\(trimmed)/" : trimmed
        guard !rules.contains(rule) else { return }
        rules.append(rule)
        newRule = ""
        persist()
    }

    private func remove(_ rule: String) {
        rules.removeAll { $0 == rule }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(rules.joined(separator: "\n"), forKey: storageKey)
    }
}

