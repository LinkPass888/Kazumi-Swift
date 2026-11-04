//
//  PluginImportExport.swift
//  Kazumi
//
//  规则导入 / 导出。导入逻辑在 PluginImportParser（1:1 翻译 Dart），
//  这里补充导出、剪贴板分享文本与文件导入的统一入口。
//

import Foundation

enum PluginExportFormat: Sendable {
    /// 整表 JSON 数组，可直接保存为 .json 文件再导入。
    case jsonArray
    /// kazumi:// 规则链接（单条）。
    case ruleLink

    var fileExtension: String {
        switch self {
        case .jsonArray: "json"
        case .ruleLink: "txt"
        }
    }
}

enum PluginImportExport {
    /// 单条规则导出为 kazumi:// 链接。
    static func ruleLink(for plugin: Plugin) -> String {
        KazumiRuleLink.encode(json: plugin.toJSON().serialized(pretty: false))
    }

    /// 规则集合导出为 JSON 数组文本；`pretty` 便于用户阅读与手动编辑。
    static func json(for plugins: [Plugin], pretty: Bool = true) -> String {
        JSONValue.array(plugins.map { $0.toJSON() }).serialized(pretty: pretty)
    }

    /// 解析导入内容（JSON / 链接 / 混合文本），并提示会被覆盖的本地规则。
    static func importResult(for input: String, existing: [Plugin]) -> PluginImportSummary {
        let parsed = PluginImportParser.parse(input)
        let installed = Dictionary(
            existing.map { (pluginNameKey($0.name), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let replaced = parsed.plugins.compactMap { installed[pluginNameKey($0.name)]?.name }
        return PluginImportSummary(
            plugins: parsed.plugins,
            failures: parsed.failures,
            duplicateCount: parsed.duplicateCount,
            replacedNames: replaced
        )
    }
}

struct PluginImportSummary: Sendable {
    var plugins: [Plugin]
    var failures: [String]
    var duplicateCount: Int
    /// 导入后会覆盖同名本地规则的名称（用于确认弹窗）。
    var replacedNames: [String]

    var isEmpty: Bool { plugins.isEmpty }
}
