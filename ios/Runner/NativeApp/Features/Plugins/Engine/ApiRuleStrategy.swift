//
//  ApiRuleStrategy.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/api_rule_strategy.dart。
//
//  关键约定（与原实现一致，改变会破坏已存在的规则）：
//  * `@var` 的精确占位（整个字符串就是 `@var`）替换为原始值（可能是数字/布尔），
//    其余位置替换为字符串并在 URL 场景做百分号编码；
//  * `@source` 在搜索模板中是纯字符串替换，因此 `/GV@source` 这类写法可用；
//  * 剧集页模板提供 episodeUrl / roadIndex / roadNumber / episodeIndex / episodeNumber；
//  * 空 URL 的剧集被跳过并写入 diagnostics，而 ApiRuleFormatError 直接冒泡。
//

import Foundation

struct ApiRuleStrategy: Sendable {
    /// 对应 Dart 的 `^@([A-Za-z_][A-Za-z0-9_]*)$`（用 NSRegularExpression 避免
    /// 正则字面量在 Swift 6 下的静态初始化约束）。
    private static let exactVariablePattern = try! NSRegularExpression(pattern: "^@([A-Za-z_][A-Za-z0-9_]*)$")

    func decodeResponse(_ raw: String) throws -> JSONValue {
        do {
            return try JSONValue.decode(raw)
        } catch {
            throw ApiRuleFormatError(message: String(localized: "API 响应不是有效 JSON: \(String(describing: error.localizedDescription))"))
        }
    }

    func prepareRequest(_ config: ApiRequestConfig, variables: [String: JSONValue]) throws -> PreparedRuleRequest {
        let method = config.method.uppercased()
        guard method == "GET" || method == "POST" else {
            throw ApiRuleFormatError(message: String(localized: "仅支持 GET/POST，当前为 \(String(describing: method))"))
        }
        let trimmedURL = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ApiRuleFormatError(message: String(localized: "API 请求 URL 不能为空"))
        }
        let url = try renderTemplate(trimmedURL, variables: variables, encode: true)
        guard isValidAbsoluteURL(url) else {
            throw ApiRuleFormatError(message: String(localized: "API 请求 URL 无效: \(String(describing: url))"))
        }
        let hasBody = method == "POST" && config.bodyType != .none
        return PreparedRuleRequest(
            method: method,
            url: url,
            headers: try renderMap(config.headers, variables: variables),
            query: try renderMap(config.query, variables: variables),
            bodyType: config.bodyType,
            body: hasBody ? try renderValue(config.body ?? .null, variables: variables) : nil,
            includeCookies: true
        )
    }

    /// 校验搜索规则的 JSONPath；插件编辑器保存前也复用它。
    func validateSearchConfig(_ config: ApiSearchConfig) throws {
        try RestrictedJSONPath.validate(config.listPath)
        try RestrictedJSONPath.validate(config.namePath)
        try RestrictedJSONPath.validate(config.sourcePath)
        let template = config.sourceTemplate
        if !template.isEmpty && !template.contains("@source") {
            throw ApiRuleFormatError(message: String(localized: "详情页地址模板必须引用 @source"))
        }
    }

    func parseSearch(_ raw: String, config: ApiSearchConfig) throws -> RuleSearchParseResult {
        try validateSearchConfig(config)
        let document = try decodeResponse(raw)
        let nodes = try RestrictedJSONPath.read(document, expression: config.listPath)
        let template = config.sourceTemplate
        var items: [SearchItem] = []
        var fragments: [String] = []
        var diagnostics: [String] = []

        for (index, node) in nodes.enumerated() {
            do {
                let name = stringValue(try RestrictedJSONPath.readFirst(node, expression: config.namePath))
                let source = stringValue(try RestrictedJSONPath.readFirst(node, expression: config.sourcePath))
                if name.isEmpty || source.isEmpty {
                    diagnostics.append(String(localized: "搜索节点 \(String(describing: index)) 缺少名称或来源，已跳过"))
                    continue
                }
                // 纯字符串替换，`@source` 可以紧跟字母（例如 `/GV@source`）。
                let src = template.isEmpty
                    ? source
                    : template.replacingOccurrences(of: "@source", with: encodeComponent(source))
                items.append(SearchItem(name: name, src: src))
                fragments.append(node.serialized(pretty: false))
            } catch let error as ApiRuleFormatError {
                throw error
            } catch {
                diagnostics.append(String(localized: "搜索节点 \(String(describing: index)) 解析失败: \(String(describing: error.localizedDescription))"))
            }
        }

        return RuleSearchParseResult(items: items, matchedFragments: fragments, diagnostics: diagnostics)
    }

    func parseChapters(
        _ raw: String,
        config: ApiChapterConfig,
        source: String,
        baseUrl: String
    ) throws -> RuleChapterParseResult {
        try validateChapterConfig(config)
        let document = try decodeResponse(raw)
        var rootVariables: [String: JSONValue] = ["source": .string(source)]
        for (key, path) in config.variables {
            guard let value = try RestrictedJSONPath.readFirst(document, expression: path), !value.isNull else {
                throw ApiRuleFormatError(message: String(localized: "选集响应变量 \(String(describing: key)) 未匹配到值: \(String(describing: path))"))
            }
            rootVariables[key] = value
        }
        var diagnostics: [String] = []
        let roads = config.format == .delimited
            ? try parseDelimited(
                document,
                config: config,
                rootVariables: rootVariables,
                baseUrl: baseUrl,
                diagnostics: &diagnostics
            )
            : try parseNested(
                document,
                config: config,
                rootVariables: rootVariables,
                baseUrl: baseUrl,
                diagnostics: &diagnostics
            )
        return RuleChapterParseResult(roads: roads, diagnostics: diagnostics)
    }

    private func parseNested(
        _ document: JSONValue,
        config: ApiChapterConfig,
        rootVariables: [String: JSONValue],
        baseUrl: String,
        diagnostics: inout [String]
    ) throws -> [Road] {
        let hasRoads = !config.roadsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let roadNodes: [JSONValue] = hasRoads
            ? try RestrictedJSONPath.read(document, expression: config.roadsPath)
            : [document]
        var roads: [Road] = []

        for (roadIndex, roadNode) in roadNodes.enumerated() {
            do {
                let roadName: String = (hasRoads && !config.roadNamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ? stringValue(try RestrictedJSONPath.readFirst(roadNode, expression: config.roadNamePath))
                    : ""
                let episodeNodes = try RestrictedJSONPath.read(roadNode, expression: config.episodesPath)
                var urls: [String] = []
                var names: [String] = []

                for (episodeIndex, episodeNode) in episodeNodes.enumerated() {
                    do {
                        let episodeName = stringValue(
                            try RestrictedJSONPath.readFirst(episodeNode, expression: config.episodeNamePath)
                        )
                        let rawURL = config.episodeUrlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? ""
                            : stringValue(try RestrictedJSONPath.readFirst(episodeNode, expression: config.episodeUrlPath))
                        let pageURL = try resolveEpisodeURL(
                            config,
                            rootVariables: rootVariables,
                            rawURL: rawURL,
                            roadIndex: roadIndex,
                            episodeIndex: episodeIndex,
                            baseUrl: baseUrl
                        )
                        if pageURL.isEmpty {
                            diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 的剧集节点 \(String(describing: episodeIndex)) 缺少 URL，已跳过"))
                            continue
                        }
                        urls.append(pageURL)
                        names.append(episodeName.isEmpty ? String(localized: "第\(String(describing: episodeIndex + 1))集") : episodeName)
                    } catch let error as ApiRuleFormatError {
                        throw error
                    } catch {
                        diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 的剧集节点 \(String(describing: episodeIndex)) 解析失败: \(String(describing: error.localizedDescription))"))
                    }
                }
                if urls.isEmpty {
                    diagnostics.append(String(localized: "线路节点 \(String(describing: roadIndex)) 没有有效剧集，已跳过"))
                    continue
                }
                roads.append(Road(
                    name: roadName.isEmpty ? String(localized: "播放线路\(String(describing: roads.count + 1))") : roadName,
                    data: urls,
                    identifier: names
                ))
            } catch let error as ApiRuleFormatError {
                throw error
            } catch {
                diagnostics.append(String(localized: "线路节点 \(String(describing: roadIndex)) 解析失败: \(String(describing: error.localizedDescription))"))
            }
        }
        return roads
    }
    private func parseDelimited(
        _ document: JSONValue,
        config: ApiChapterConfig,
        rootVariables: [String: JSONValue],
        baseUrl: String,
        diagnostics: inout [String]
    ) throws -> [Road] {
        let namesValue = stringValue(try RestrictedJSONPath.readFirst(document, expression: config.roadNamesPath))
        let episodesValue = stringValue(try RestrictedJSONPath.readFirst(document, expression: config.roadEpisodesPath))
        guard !episodesValue.isEmpty else { return [] }

        let roadNames = namesValue.components(separatedBy: config.roadSeparator)
        let roadGroups = episodesValue.components(separatedBy: config.roadSeparator)
        var roads: [Road] = []

        for (roadIndex, group) in roadGroups.enumerated() {
            var urls: [String] = []
            var names: [String] = []
            let entries = group.components(separatedBy: config.episodeSeparator)
            for (episodeIndex, rawEntry) in entries.enumerated() {
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                if entry.isEmpty { continue }
                guard let range = entry.range(of: config.fieldSeparator) else {
                    diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 的剧集条目 \(String(describing: episodeIndex)) 缺少字段分隔符，已跳过"))
                    continue
                }
                let name = String(entry[entry.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawURL = String(entry[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    let pageURL = try resolveEpisodeURL(
                        config,
                        rootVariables: rootVariables,
                        rawURL: rawURL,
                        roadIndex: roadIndex,
                        episodeIndex: episodeIndex,
                        baseUrl: baseUrl
                    )
                    if pageURL.isEmpty {
                        diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 的剧集条目 \(String(describing: episodeIndex)) 缺少 URL，已跳过"))
                        continue
                    }
                    urls.append(pageURL)
                    names.append(name.isEmpty ? String(localized: "第\(String(describing: episodeIndex + 1))集") : name)
                } catch let error as ApiRuleFormatError {
                    throw error
                } catch {
                    diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 的剧集条目 \(String(describing: episodeIndex)) 解析失败: \(String(describing: error.localizedDescription))"))
                }
            }
            if urls.isEmpty {
                diagnostics.append(String(localized: "线路 \(String(describing: roadIndex)) 没有有效剧集，已跳过"))
                continue
            }
            let configuredName = roadIndex < roadNames.count
                ? roadNames[roadIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            roads.append(Road(
                name: configuredName.isEmpty ? String(localized: "播放线路\(String(describing: roads.count + 1))") : configuredName,
                data: urls,
                identifier: names
            ))
        }
        return roads
    }

    private func resolveEpisodeURL(
        _ config: ApiChapterConfig,
        rootVariables: [String: JSONValue],
        rawURL: String,
        roadIndex: Int,
        episodeIndex: Int,
        baseUrl: String
    ) throws -> String {
        guard let page = config.episodePage else {
            return EpisodeURL.normalize(baseUrl: baseUrl, raw: rawURL)
        }
        let templateURL = page.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templateURL.isEmpty else {
            throw ApiRuleFormatError(message: String(localized: "播放页地址模板不能为空"))
        }
        // 模板语言没有算术能力，故同时提供 0 基与 1 基下标；
        // episodeUrl 承载 episodeUrlPath 抽出的原值且没有替代品。
        var variables = rootVariables
        variables["episodeUrl"] = .string(rawURL)
        variables["roadIndex"] = .int(roadIndex)
        variables["roadNumber"] = .int(roadIndex + 1)
        variables["episodeIndex"] = .int(episodeIndex)
        variables["episodeNumber"] = .int(episodeIndex + 1)

        let path = try renderTemplate(templateURL, variables: variables, encode: true)
        guard var components = URLComponents(string: path) else {
            throw ApiRuleFormatError(message: String(localized: "剧集页面 URL 无效: \(String(describing: path))"))
        }
        let renderedQuery = try renderMap(page.query, variables: variables)
        var mergedQuery: [String: String] = [:]
        for item in components.queryItems ?? [] {
            mergedQuery[item.name] = item.value ?? ""
        }
        for (key, value) in renderedQuery {
            mergedQuery[key] = value.toStringValue
        }
        components.queryItems = mergedQuery.isEmpty
            ? nil
            : mergedQuery.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return EpisodeURL.normalize(baseUrl: baseUrl, raw: components.string ?? path)
    }

    /// 校验章节规则；插件编辑器保存前也复用它。
    func validateChapterConfig(_ config: ApiChapterConfig) throws {
        for path in config.variables.values {
            try RestrictedJSONPath.validate(path)
        }
        if config.format == .delimited {
            try RestrictedJSONPath.validate(config.roadNamesPath)
            try RestrictedJSONPath.validate(config.roadEpisodesPath)
            if config.roadSeparator.isEmpty || config.episodeSeparator.isEmpty || config.fieldSeparator.isEmpty {
                throw ApiRuleFormatError(message: String(localized: "选集分隔符不能为空"))
            }
            return
        }
        if !config.roadsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try RestrictedJSONPath.validate(config.roadsPath)
        }
        if !config.roadNamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try RestrictedJSONPath.validate(config.roadNamePath)
        }
        try RestrictedJSONPath.validate(config.episodesPath)
        try RestrictedJSONPath.validate(config.episodeNamePath)
        if !config.episodeUrlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try RestrictedJSONPath.validate(config.episodeUrlPath)
        } else if config.episodePage == nil {
            throw ApiRuleFormatError(message: String(localized: "必须配置播放入口地址路径或播放页地址模板"))
        }
        if let page = config.episodePage,
           page.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ApiRuleFormatError(message: "播放页地址模板不能为空")
        }
    }

    private func renderMap(_ input: [String: JSONValue], variables: [String: JSONValue]) throws -> [String: JSONValue] {
        var output: [String: JSONValue] = [:]
        for (key, value) in input {
            let renderedKey = try renderTemplate(key, variables: variables)
            output[renderedKey] = try renderValue(value, variables: variables)
        }
        return output
    }

    private func renderValue(_ value: JSONValue, variables: [String: JSONValue]) throws -> JSONValue {
        switch value {
        case .string(let text):
            if let name = Self.exactVariableName(in: text) {
                guard let variable = variables[name] else {
                    throw ApiRuleFormatError(message: String(localized: "缺少模板变量 @\(String(describing: name))"))
                }
                return variable
            }
            return .string(try renderTemplate(text, variables: variables))
        case .array(let items):
            return .array(try items.map { try renderValue($0, variables: variables) })
        case .object(let object):
            var output: [String: JSONValue] = [:]
            for (key, item) in object {
                output[key] = try renderValue(item, variables: variables)
            }
            return .object(output)
        default:
            return value
        }
    }

    /// 对应 Dart `(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)`：
    /// 逐个字符扫描，遇到 `@` 时检查前一个字符，避免 `a@b` 这类标识符被误替换。
    private func renderTemplate(
        _ template: String,
        variables: [String: JSONValue],
        encode: Bool = false
    ) throws -> String {
        var output = ""
        let characters = Array(template)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            let previous = index > 0 ? characters[index - 1] : nil
            let blockedPrefix = previous.map(isIdentifierCharacter) ?? false
            if char == "@" && !blockedPrefix {
                var cursor = index + 1
                if cursor < characters.count, isIdentifierStart(characters[cursor]) {
                    var name = String(characters[cursor])
                    cursor += 1
                    while cursor < characters.count, isIdentifierCharacter(characters[cursor]) {
                        name.append(characters[cursor])
                        cursor += 1
                    }
                    guard let value = variables[name] else {
                        throw ApiRuleFormatError(message: String(localized: "缺少模板变量 @\(String(describing: name))"))
                    }
                    let text = value.toStringValue
                    output.append(encode ? encodeComponent(text) : text)
                    index = cursor
                    continue
                }
            }
            output.append(char)
            index += 1
        }
        return output
    }

    private func isIdentifierStart(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char == "_")
    }

    /// 整个字符串恰好是一个 `@name` 占位时返回变量名。
    private static func exactVariableName(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = exactVariablePattern.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges == 2,
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[nameRange])
    }

    private func isIdentifierCharacter(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "_")
    }

    private func isValidAbsoluteURL(_ string: String) -> Bool {
        guard let components = URLComponents(string: string) else { return false }
        return !(components.scheme ?? "").isEmpty && !(components.host ?? "").isEmpty
    }

    /// 对应 Dart 的 Uri.encodeComponent。
    private func encodeComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func stringValue(_ value: JSONValue?) -> String {
        guard let value, !value.isNull else { return "" }
        if case .string(let text) = value {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.toStringValue
    }
}
