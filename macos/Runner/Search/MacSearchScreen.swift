//
//  MacSearchScreen.swift
//  Kazumi (macOS)
//
//  macOS 版的搜索：拿本机已安装的每条规则各搜一次（规则引擎是两边共用的同一份），
//  结果按规则分组。点一条结果进详情页拿线路与剧集。
//
//  这里不复制 iOS 的 PluginSearchService：那个类带着「会话作废」「验证码流程」
//  两件事，后者依赖 WebView。macOS 先跑直搜——同一条规则重复搜时，用 generation
//  丢掉过期的结果就够了。
//

import Foundation
import SwiftUI

/// 一条搜索结果 + 它来自哪条规则。
struct MacSearchHit: Identifiable, Hashable {
    var id: String { "\(pluginName)\u{1}\(item.src)\u{1}\(item.name)" }
    var pluginName: String
    var item: SearchItem
}

struct MacSearchScreen: View {
    @Environment(MacAppModel.self) private var app

    @State private var keyword = ""
    @State private var hits: [MacSearchHit] = []
    @State private var failedRules: [String] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var selectedHit: MacSearchHit?
    /// 每次开搜加一；回来时对不上就把结果丢掉（同一条规则连搜两次不会串）。
    @State private var generation = 0

    var body: some View {
        Group {
            if app.plugins.pluginList.isEmpty {
                ContentUnavailableView {
                    Label("还没有规则", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("搜索要先装一条规则：到「规则」栏从规则仓库装几条，再回来搜。")
                }
            } else if isSearching, hits.isEmpty {
                ProgressView("正在搜…")
                    .controlSize(.large)
            } else if hits.isEmpty {
                ContentUnavailableView {
                    Label(hasSearched ? "没搜到" : "搜点什么", systemImage: "magnifyingglass")
                } description: {
                    Text(
                        hasSearched
                            ? "换个关键词试试，或者换几条规则——有的规则只认日文原名。"
                            : "输入番剧名，用全部 \(app.plugins.pluginList.count) 条规则一起搜。"
                    )
                }
            } else {
                resultList
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $keyword, prompt: "番剧名")
        .onSubmit(of: .search) { startSearch() }
        .sheet(item: $selectedHit) { hit in
            MacDetailScreen(pluginName: hit.pluginName, item: hit.item)
        }
    }

    private var resultList: some View {
        List {
            ForEach(grouped, id: \.pluginName) { group in
                Section(group.pluginName) {
                    ForEach(group.hits) { hit in
                        Button {
                            selectedHit = hit
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "tv")
                                    .foregroundStyle(.secondary)
                                Text(hit.item.name)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !failedRules.isEmpty {
                Section("没搜出结果") {
                    Text(failedRules.joined(separator: "、"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSearching { ProgressView().controlSize(.small).padding(12) }
        }
    }

    private struct MacSearchGroup { var pluginName: String; var hits: [MacSearchHit] }

    /// 按规则分组，保持规则列表里的顺序（用户在「规则」栏排过的顺序）。
    private var grouped: [MacSearchGroup] {
        let order = app.plugins.pluginList.map(\.name)
        return order.compactMap { name in
            let items = hits.filter { $0.pluginName == name }
            return items.isEmpty ? nil : MacSearchGroup(pluginName: name, hits: items)
        }
    }

    /// 一条规则这次搜的结果：拿到条目，或者失败（失败的详情只进日志，屏上只报规则名）。
    private enum SearchOutcome: Sendable {
        case items([SearchItem])
        case failed
    }

    private func startSearch() {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        generation &+= 1
        let current = generation
        let plugins = app.plugins.pluginList
        isSearching = true
        hasSearched = true
        hits = []
        failedRules = []
        Task {
            let engine = RuleEngine()
            let outcome = await withTaskGroup(of: (String, SearchOutcome).self) { group in
                for plugin in plugins {
                    group.addTask {
                        do {
                            let trace = try await engine.search(
                                RuleExecutionConfig(plugin: plugin),
                                keyword: text
                            )
                            return (plugin.name, .items(trace.response.data))
                        } catch {
                            return (plugin.name, .failed)
                        }
                    }
                }
                var all: [(String, SearchOutcome)] = []
                for await result in group { all.append(result) }
                return all
            }
            guard current == generation else { return }
            var newHits: [MacSearchHit] = []
            var failures: [String] = []
            for (name, result) in outcome {
                switch result {
                case .items(let items):
                    newHits += items.map { MacSearchHit(pluginName: name, item: $0) }
                case .failed:
                    failures.append(name)
                }
            }
            hits = newHits
            failedRules = failures.sorted()
            isSearching = false
            KazumiLog.plugin.info(
                "mac search: \(text, privacy: .public) -> \(newHits.count, privacy: .public) hit(s), \(failures.count, privacy: .public) rule(s) failed"
            )
        }
    }
}