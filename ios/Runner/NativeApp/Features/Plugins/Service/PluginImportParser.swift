//
//  PluginImportParser.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/plugin_import_parser.dart。
//
//  支持三种导入来源：JSON 对象 / JSON 数组、字符串数组（元素为 kazumi:// 链接）、
//  以及混在任意文本里的 kazumi:// 链接。规则按名称去重（后者覆盖前者）。
//

import Foundation

struct PluginImportParseResult: Sendable {
    var plugins: [Plugin]
    var failures: [String]
    var duplicateCount: Int

    var failureCount: Int { failures.count }
}

enum PluginImportParser {
    /// 对应 `^[A-Za-z0-9+/_=%\-\s]+`：链接 payload 只截取这些字符。
    private static func payloadPrefix(_ raw: String) -> String? {
        var result = ""
        for char in raw {
            let allowed = char.isWhitespace ||
                (char.isASCII && (char.isLetter || char.isNumber || "+/_=%-".contains(char)))
            guard allowed else { break }
            result.append(char)
        }
        // Dart 的 trimRight 只去掉尾部空白，这里保持相同语义。
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result.isEmpty ? nil : result
    }

    static func parse(_ input: String) -> PluginImportParseResult {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return PluginImportParseResult(plugins: [], failures: [String(localized: "导入内容为空")], duplicateCount: 0)
        }

        var parsed: [Plugin] = []
        var failures: [String] = []
        var decodedJSON: JSONValue?
        do {
            decodedJSON = try JSONValue.decode(value)
        } catch {
            // 非 JSON：下面按规则链接解析。
        }

        if let decodedJSON {
            if let list = decodedJSON.arrayValue {
                for (index, entry) in list.enumerated() {
                    parseEntry(entry, index: index + 1, plugins: &parsed, failures: &failures)
                }
            } else {
                parseEntry(decodedJSON, index: 1, plugins: &parsed, failures: &failures)
            }
        } else {
            let segments = KazumiRuleLink.segments(in: value)
            if segments.isEmpty {
                failures.append("未找到有效的 JSON 或 kazumi:// 规则链接")
            } else {
                for (index, segment) in segments.enumerated() {
                    do {
                        let entry = try decodeRuleEntry(scheme: segment.scheme, rawPayload: segment.rawPayload)
                        parseEntry(entry, index: index + 1, plugins: &parsed, failures: &failures)
                    } catch {
                        failures.append(String(localized: "第 \(String(describing: index + 1)) 条：\(String(describing: describe(error)))"))
                    }
                }
            }
        }

        // 与 Dart 的 LinkedHashMap 一致：保留首次出现的顺序，后出现的同规则覆盖内容。
        var order: [String] = []
        var unique: [String: Plugin] = [:]
        var duplicateCount = 0
        for plugin in parsed {
            let key = pluginNameKey(plugin.name)
            if unique[key] != nil {
                duplicateCount += 1
            } else {
                order.append(key)
            }
            unique[key] = plugin
        }

        return PluginImportParseResult(
            plugins: order.compactMap { unique[$0] },
            failures: failures,
            duplicateCount: duplicateCount
        )
    }

    private static func decodeRuleEntry(scheme: String, rawPayload: String) throws -> JSONValue {
        guard let payload = payloadPrefix(rawPayload) else {
            throw PluginImportError.missingPayload
        }
        // 聊天软件常在链接后接正文，从最长的候选开始尝试，逐步缩短。
        var candidates: [String] = [payload]
        for whitespaceIndex in payload.indices where payload[whitespaceIndex].isWhitespace {
            let candidate = String(payload[payload.startIndex..<whitespaceIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, candidate != candidates.last {
                candidates.append(candidate)
            }
        }

        var firstError: Error?
        for candidate in candidates {
            do {
                let json = try KazumiRuleLink.decode(scheme + candidate)
                let decoded = try JSONValue.decode(json)
                if decoded.objectValue != nil { return decoded }
                if firstError == nil { firstError = PluginImportError.notObject }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? PluginImportError.invalidLink
    }

    private static func parseEntry(
        _ entry: JSONValue,
        index: Int,
        plugins: inout [Plugin],
        failures: inout [String]
    ) {
        do {
            let object: JSONValue
            if entry.objectValue != nil {
                object = entry
            } else if let link = entry.stringValue {
                let decoded = try JSONValue.decode(KazumiRuleLink.decode(link))
                guard decoded.objectValue != nil else { throw PluginImportError.notObject }
                object = decoded
            } else {
                throw PluginImportError.notObjectOrLink
            }

            let plugin = Plugin(json: object)
            if plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PluginImportError.emptyName
            }
            if plugin.requiresNewerClient {
                throw PluginImportError.requiresNewerClient
            }
            plugins.append(plugin)
        } catch {
            failures.append(String(localized: "第 \(String(describing: index)) 条：\(String(describing: describe(error)))"))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

enum PluginImportError: Error, LocalizedError, Sendable {
    case missingPayload
    case notObject
    case notObjectOrLink
    case emptyName
    case requiresNewerClient
    case invalidLink

    var errorDescription: String? {
        switch self {
        case .missingPayload: "Missing payload in Kazumi rule link"
        case .notObject: String(localized: "规则链接内容必须是 JSON object")
        case .notObjectOrLink: "规则必须是 JSON object 或 kazumi:// 链接"
        case .emptyName: String(localized: "规则名称不能为空")
        case .requiresNewerClient: String(localized: "规则需要更高版本客户端")
        case .invalidLink: "Invalid Kazumi rule link"
        }
    }
}
