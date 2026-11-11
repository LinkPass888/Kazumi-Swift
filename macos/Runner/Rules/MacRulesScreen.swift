//
//  MacRulesScreen.swift
//  Kazumi (macOS)
//
//  macOS 版的规则栏：本机装了哪些规则，以及从规则仓库装新的。
//
//  规则列表、安装、删除都走共享的 `PluginsController`——落盘路径与 iOS 同一条
//  （Application Support/Kazumi/rules/v2/plugins.json），只是两侧各存各的。
//  规则仓库地址由 `KazumiEndpoints` 决定（自定义仓库在 iOS 上加了会同步到这条链路）。
//

import Foundation
import SwiftUI

struct MacRulesScreen: View {
    @Environment(MacAppModel.self) private var app

    @State private var catalog: [PluginHTTPItem] = []
    @State private var isLoadingCatalog = false
    @State private var busyNames: Set<String> = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if app.plugins.pluginList.isEmpty {
                    Text("还没装规则。下面从规则仓库挑一条装。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.plugins.pluginList) { plugin in
                        installedRow(plugin)
                    }
                }
            } header: {
                Text("已安装（\(app.plugins.pluginList.count)）")
            }

            Section {
                if isLoadingCatalog {
                    ProgressView().controlSize(.small)
                } else if catalog.isEmpty {
                    Text(message ?? "规则仓库还没读到。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(catalog) { item in
                        catalogRow(item)
                    }
                }
            } header: {
                Text("规则仓库")
            } footer: {
                if let message, !catalog.isEmpty {
                    Text(message).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("规则")
        .toolbar {
            Button {
                Task { await loadCatalog(force: true) }
            } label: {
                Label("刷新规则仓库", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingCatalog)
        }
        .task { await loadCatalog(force: false) }
    }

    private func installedRow(_ plugin: Plugin) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                Text(URL(string: plugin.baseUrl)?.host ?? plugin.baseUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(plugin.version)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await app.plugins.removePlugin(plugin)
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func catalogRow(_ item: PluginHTTPItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(item.author.isEmpty ? item.version : "\(item.author) · \(item.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busyNames.contains(item.name) {
                ProgressView().controlSize(.small)
            } else {
                switch app.plugins.pluginStatus(item) {
                case .installed:
                    Text("已安装")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .update:
                    Button("更新") { Task { await install(item) } }
                        .controlSize(.small)
                case .install:
                    Button("安装") { Task { await install(item) } }
                        .controlSize(.small)
                }
            }
        }
    }

    private func loadCatalog(force: Bool) async {
        isLoadingCatalog = true
        message = nil
        do {
            if force {
                catalog = try await app.plugins.refreshPluginCatalog()
            } else {
                catalog = try await app.plugins.ensurePluginCatalog()
            }
        } catch {
            message = error.localizedDescription
            catalog = []
        }
        isLoadingCatalog = false
    }

    private func install(_ item: PluginHTTPItem) async {
        busyNames.insert(item.name)
        defer { busyNames.remove(item.name) }
        let result = await app.plugins.tryUpdatePlugin(named: item.name)
        switch result {
        case .updated:
            message = "已安装 \(item.name)"
        case .notNewer:
            message = "\(item.name) 已是最新版本"
        case .requiresNewerClient:
            message = "规则「\(item.name)」需要更高版本的客户端"
        case .failed:
            message = "安装「\(item.name)」失败，可能是网络或规则仓库那边的问题"
        }
    }
}