//
//  MacDetailScreen.swift
//  Kazumi (macOS)
//
//  搜索结果点进来的这一页：用规则引擎拉章节，按线路列出剧集，点一集就交给播放器。
//
//  只有能拿到直链的线路能直接播：规则的 identifier 里多数是网页地址，iOS 那边靠
//  VideoSourceWebView 在网页里把 m3u8/mp4 捞出来，那条路 macOS 还没移植。
//  这里遇到非直链就明说，不假装在转圈。
//

import Foundation
import SwiftUI

struct MacDetailScreen: View {
    let pluginName: String
    let item: SearchItem

    @Environment(MacAppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var roads: [Road] = []
    @State private var roadIndex = 0
    @State private var isLoading = true
    @State private var message: String?

    private var plugin: Plugin? { app.plugins.plugin(named: pluginName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .task { await loadChapters() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                Text(pluginName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在读剧集…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if roads.isEmpty {
            ContentUnavailableView {
                Label("没读到剧集", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message ?? "这条规则在这部番上没有给出线路，换一条规则搜搜看。")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if roads.count > 1 {
                    Picker("线路", selection: $roadIndex) {
                        ForEach(Array(roads.enumerated()), id: \.offset) { index, road in
                            Text(road.name.isEmpty ? "线路 \(index + 1)" : road.name)
                                .tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                episodeGrid
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var episodeGrid: some View {
        ScrollView {
            let road = roads[min(roadIndex, roads.count - 1)]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(Array(road.data.enumerated()), id: \.offset) { index, name in
                    Button {
                        play(road: road, index: index)
                    } label: {
                        Text(name.isEmpty ? "第 \(index + 1) 集" : name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    // MARK: - 数据

    private func loadChapters() async {
        guard let plugin else {
            isLoading = false
            message = "这条规则已经不在本机了，回到「规则」栏重新装一次。"
            return
        }
        message = nil
        do {
            let trace = try await RuleEngine().queryChapters(
                RuleExecutionConfig(plugin: plugin),
                source: item.src
            )
            roads = trace.roads
            roadIndex = 0
            if roads.isEmpty { message = "这条规则在这部番上没有给出线路。" }
        } catch {
            message = error.localizedDescription
        }
        isLoading = false
    }

    /// 点一集：能取到直链就直接放，取不到就说明要网页解析。
    private func play(road: Road, index: Int) {
        guard let plugin else { return }
        guard index < road.identifier.count else {
            message = "这一集没有地址（规则的线路数据不完整）。"
            return
        }
        let raw = road.identifier[index]
        let absolute = EpisodeURL.normalize(baseUrl: plugin.baseUrl, raw: raw)
        let decoded = MediaUtility.decodeVideoSource(absolute)
        guard MediaUtility.isMediaURL(decoded), let url = URL(string: decoded) else {
            message = String(
                localized: "这条线路给的是网页地址，要在网页里解析出地址才能播——那套 WebView 还没移植到 macOS。换一条直链线路试试。"
            )
            return
        }
        let headers = plugin.buildHttpHeaders()
        let cookie = PluginCookieStore.shared.cookieHeader(pluginName: plugin.name, url: decoded)
        let title = road.data.indices.contains(index) && !road.data[index].isEmpty
            ? "\(item.name) · \(road.data[index])"
            : item.name
        app.play(
            MacPlayRequest(
                url: url,
                title: title,
                referer: headers["referer"],
                userAgent: PluginCookieStore.shared.userAgent(for: plugin.name) ?? headers["user-agent"],
                cookie: cookie.isEmpty ? nil : cookie
            )
        )
        dismiss()
    }
}