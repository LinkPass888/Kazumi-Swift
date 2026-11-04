//
//  PluginEditorScreen.swift
//  Kazumi
//
//  规则编辑路由入口（对应 lib/pages/plugin_editor/editor route）。
//  路由只带规则名，真正的编辑表单由 PluginEditorView 承载。
//

import SwiftUI

struct PluginEditorScreen: View {
    @Environment(PluginsController.self) private var plugins

    var ruleID: String?

    var body: some View {
        if let plugin = resolvedPlugin {
            PluginEditorView(original: plugin)
        } else if ruleID == nil {
            PluginEditorView(original: Plugin.template(apiLevel: KazumiAppInfo.ruleAPILevel))
        } else {
            ContentUnavailableView(
                "规则不存在",
                systemImage: "questionmark.square.dashed",
                description: Text("该规则可能已被删除，请返回规则列表重试。")
            )
        }
    }

    private var resolvedPlugin: Plugin? {
        guard let ruleID else { return nil }
        return plugins.plugin(named: ruleID)
    }
}
