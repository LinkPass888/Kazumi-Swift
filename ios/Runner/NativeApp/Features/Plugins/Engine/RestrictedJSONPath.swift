//
//  RestrictedJSONPath.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/api_rule_strategy.dart 中的 RestrictedJsonPath。
//
//  只支持规则中实际用到的 JSONPath 子集：
//    $            根
//    .name        子属性（允许字母、数字、下划线、$、-）
//    [0]          数组下标
//    [*]          数组/对象通配
//    ['key']      带引号的属性（单双引号，支持反斜杠转义）
//  校验失败时抛 ApiRuleFormatError，文案与原实现保持一致。
//

import Foundation

enum RestrictedJSONPath {
    enum Segment: Sendable, Equatable {
        case key(String)
        case index(Int)
        case wildcard
    }

    /// 等价于 Dart 的 `validate`。
    static func validate(_ expression: String) throws {
        _ = try parse(expression)
    }

    static func parse(_ expression: String) throws -> [Segment] {
        let characters = Array(expression)
        guard !characters.isEmpty, characters[0] == "$" else {
            throw ApiRuleFormatError(message: String(localized: "JSONPath 必须以 \\$ 开头: \(String(describing: expression))"))
        }

        var index = 1
        var segments: [Segment] = []
        while index < characters.count {
            let char = characters[index]
            if char == "." {
                index += 1
                let start = index
                while index < characters.count, isNameCharacter(characters[index]) {
                    index += 1
                }
                if index == start {
                    throw ApiRuleFormatError(message: String(localized: "不支持的 JSONPath: \(String(describing: expression))"))
                }
                segments.append(.key(String(characters[start..<index])))
                continue
            }
            if char == "[" {
                let end = try findBracketEnd(characters, start: index, expression: expression)
                let content = String(characters[(index + 1)..<end]).trimmingCharacters(in: .whitespaces)
                if content == "*" {
                    segments.append(.wildcard)
                } else if let number = Int(content), !content.isEmpty, content.allSatisfy(\.isNumber) {
                    segments.append(.index(number))
                } else if content.count >= 2,
                          (content.hasPrefix("'") && content.hasSuffix("'")) ||
                          (content.hasPrefix("\"") && content.hasSuffix("\"")) {
                    segments.append(.key(unescape(String(content.dropFirst().dropLast()))))
                } else {
                    throw ApiRuleFormatError(message: String(localized: "不支持的 JSONPath 片段: [\(String(describing: content))]"))
                }
                index = end + 1
                continue
            }
            throw ApiRuleFormatError(message: String(localized: "不支持的 JSONPath: \(String(describing: expression))"))
        }
        return segments
    }

    private static func isNameCharacter(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "$" || char == "-")
    }

    private static func unescape(_ raw: String) -> String {
        var output = ""
        var escaped = false
        for char in raw {
            if escaped {
                output.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                output.append(char)
            }
        }
        if escaped { output.append("\\") }
        return output
    }

    private static func findBracketEnd(_ characters: [Character], start: Int, expression: String) throws -> Int {
        var quote: Character?
        var escaped = false
        var index = start + 1
        while index < characters.count {
            let char = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if char == "\\" {
                escaped = true
                index += 1
                continue
            }
            if let currentQuote = quote {
                if char == currentQuote { quote = nil }
                index += 1
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                index += 1
                continue
            }
            if char == "]" { return index }
            index += 1
        }
        throw ApiRuleFormatError(message: String(localized: "JSONPath 缺少 ]: \(String(describing: expression))"))
    }

    /// 等价于 json_path 包 `JsonPath(expression).readValues(document)`。
    static func read(_ document: JSONValue, expression: String) throws -> [JSONValue] {
        let segments = try parse(expression)
        var current: [JSONValue] = [document]
        for segment in segments {
            var next: [JSONValue] = []
            for node in current {
                switch segment {
                case .key(let key):
                    // 下标总是返回 JSONValue（缺失时为 .null），用 exists 判断键是否存在。
                    let value = node[key]
                    if value.exists { next.append(value) }
                case .index(let position):
                    if let values = node.arrayValue, values.indices.contains(position) {
                        next.append(values[position])
                    }
                case .wildcard:
                    if let values = node.arrayValue {
                        next.append(contentsOf: values)
                    } else if let object = node.objectValue {
                        next.append(contentsOf: object.values)
                    }
                }
            }
            current = next
        }
        return current
    }

    static func readFirst(_ document: JSONValue, expression: String) throws -> JSONValue? {
        try read(document, expression: expression).first
    }
}
