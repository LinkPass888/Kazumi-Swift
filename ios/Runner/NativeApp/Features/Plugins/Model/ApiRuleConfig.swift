//
//  ApiRuleConfig.swift
//  Kazumi
//
//  1:1 翻译 lib/plugins/api_rule_config.dart。
//  字段默认值、normalize 规则、以及"非默认配置也要随规则持久化"的条件序列化
//  均与原实现一致，保证规则文件可双向兼容。
//

import Foundation

/// 规则模式（xpath / api）。
enum RuleMode: String, Sendable {
    case xpath
    case api

    static func normalize(_ value: JSONValue?) -> RuleMode {
        value?.stringValue == RuleMode.api.rawValue ? .api : .xpath
    }
}

enum ApiBodyType: String, Sendable {
    case none
    case json
    case form

    static func normalize(_ value: JSONValue?) -> ApiBodyType {
        switch value?.stringValue {
        case ApiBodyType.json.rawValue: .json
        case ApiBodyType.form.rawValue: .form
        default: .none
        }
    }
}

enum ApiChapterFormat: String, Sendable {
    case nested
    case delimited

    static func normalize(_ value: JSONValue?) -> ApiChapterFormat {
        value?.stringValue == ApiChapterFormat.delimited.rawValue ? .delimited : .nested
    }
}

/// API 请求模板。
struct ApiRequestConfig: Hashable, Sendable {
    var method: String = "GET"
    var url: String = ""
    var headers: [String: JSONValue] = [:]
    var query: [String: JSONValue] = [:]
    var bodyType: ApiBodyType = .none
    var body: JSONValue?

    init(
        method: String = "GET",
        url: String = "",
        headers: [String: JSONValue] = [:],
        query: [String: JSONValue] = [:],
        bodyType: ApiBodyType = .none,
        body: JSONValue? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.query = query
        self.bodyType = bodyType
        self.body = body
    }

    init(json: JSONValue?) {
        let object = json?.objectValue ?? [:]
        self.method = (object["method"]?.stringValue ?? "GET").uppercased()
        self.url = object["url"]?.stringValue ?? ""
        self.headers = ApiRequestConfig.stringMap(object["headers"])
        self.query = ApiRequestConfig.stringMap(object["query"])
        self.bodyType = ApiBodyType.normalize(object["bodyType"])
        self.body = object["body"]
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "method": .string(method.uppercased()),
            "url": .string(url)
        ]
        if !headers.isEmpty { object["headers"] = .object(headers) }
        if !query.isEmpty { object["query"] = .object(query) }
        if bodyType != .none {
            object["bodyType"] = .string(bodyType.rawValue)
            if let body { object["body"] = body }
        }
        return .object(object)
    }

    static func stringMap(_ value: JSONValue?) -> [String: JSONValue] {
        guard let object = value?.objectValue else { return [:] }
        return object
    }
}
/// 搜索结果映射（JSONPath）。
struct ApiSearchConfig: Hashable, Sendable {
    var request: ApiRequestConfig
    var listPath: String
    var namePath: String
    var sourcePath: String

    /// 详情页地址模板，用 `@source` 替换；为空时保留原值。
    var sourceTemplate: String

    init(
        request: ApiRequestConfig = ApiRequestConfig(),
        listPath: String = "$.data[*]",
        namePath: String = "$.name",
        sourcePath: String = "$.url",
        sourceTemplate: String = ""
    ) {
        self.request = request
        self.listPath = listPath
        self.namePath = namePath
        self.sourcePath = sourcePath
        self.sourceTemplate = sourceTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(json: JSONValue?) {
        let object = json?.objectValue ?? [:]
        self.init(
            request: ApiRequestConfig(json: object["request"]),
            listPath: object["listPath"]?.stringValue ?? "$.data[*]",
            namePath: object["namePath"]?.stringValue ?? "$.name",
            sourcePath: object["sourcePath"]?.stringValue ?? "$.url",
            sourceTemplate: object["sourceTemplate"]?.stringValue ?? ""
        )
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "request": request.toJSON(),
            "listPath": .string(listPath),
            "namePath": .string(namePath),
            "sourcePath": .string(sourcePath)
        ]
        if !sourceTemplate.isEmpty { object["sourceTemplate"] = .string(sourceTemplate) }
        return .object(object)
    }
}

/// 最终播放页地址模板（配合响应变量与集数下标）。
struct ApiEpisodePageConfig: Hashable, Sendable {
    var url: String = ""
    var query: [String: JSONValue] = [:]

    init(json: JSONValue?) {
        let object = json?.objectValue ?? [:]
        self.url = object["url"]?.stringValue ?? ""
        self.query = ApiRequestConfig.stringMap(object["query"])
    }

    func toJSON() -> JSONValue {
        .object(["url": .string(url), "query": .object(query)])
    }
}

/// 剧集列表映射。
struct ApiChapterConfig: Hashable, Sendable {
    var request: ApiRequestConfig
    var format: ApiChapterFormat

    // nested 形态
    var roadsPath: String
    var roadNamePath: String
    var episodesPath: String
    var episodeNamePath: String
    var episodeUrlPath: String

    // delimited 形态
    var roadNamesPath: String
    var roadEpisodesPath: String
    var roadSeparator: String
    var episodeSeparator: String
    var fieldSeparator: String

    /// 章节响应上的具名 JSONPath 捕获，作为模板变量暴露给 episodePage。
    var variables: [String: String]

    /// 用模板构造播放页地址，替代响应中的 URL。
    var episodePage: ApiEpisodePageConfig?

    init(
        request: ApiRequestConfig = ApiRequestConfig(),
        format: ApiChapterFormat = .nested,
        roadsPath: String = "$.data.roads[*]",
        roadNamePath: String = "$.name",
        episodesPath: String = "$.episodes[*]",
        episodeNamePath: String = "$.name",
        episodeUrlPath: String = "$.url",
        roadNamesPath: String = "",
        roadEpisodesPath: String = "",
        roadSeparator: String = "$$$",
        episodeSeparator: String = "#",
        fieldSeparator: String = "$",
        variables: [String: String] = [:],
        episodePage: ApiEpisodePageConfig? = nil
    ) {
        self.request = request
        self.format = format
        self.roadsPath = roadsPath
        self.roadNamePath = roadNamePath
        self.episodesPath = episodesPath
        self.episodeNamePath = episodeNamePath
        self.episodeUrlPath = episodeUrlPath
        self.roadNamesPath = roadNamesPath
        self.roadEpisodesPath = roadEpisodesPath
        self.roadSeparator = roadSeparator
        self.episodeSeparator = episodeSeparator
        self.fieldSeparator = fieldSeparator
        self.variables = variables
        self.episodePage = episodePage
    }

    init(json: JSONValue?) {
        let object = json?.objectValue ?? [:]
        var variables: [String: String] = [:]
        for (key, value) in object["variables"]?.objectValue ?? [:] {
            variables[key] = value.stringValue ?? ""
        }
        let page = object["episodePage"]?.objectValue != nil
            ? ApiEpisodePageConfig(json: object["episodePage"])
            : nil
        self.init(
            request: ApiRequestConfig(json: object["request"]),
            format: ApiChapterFormat.normalize(object["format"]),
            roadsPath: object["roadsPath"]?.stringValue ?? "$.data.roads[*]",
            roadNamePath: object["roadNamePath"]?.stringValue ?? "$.name",
            episodesPath: object["episodesPath"]?.stringValue ?? "$.episodes[*]",
            episodeNamePath: object["episodeNamePath"]?.stringValue ?? "$.name",
            episodeUrlPath: object["episodeUrlPath"]?.stringValue ?? "$.url",
            roadNamesPath: object["roadNamesPath"]?.stringValue ?? "",
            roadEpisodesPath: object["roadEpisodesPath"]?.stringValue ?? "",
            roadSeparator: object["roadSeparator"]?.stringValue ?? "$$$",
            episodeSeparator: object["episodeSeparator"]?.stringValue ?? "#",
            fieldSeparator: object["fieldSeparator"]?.stringValue ?? "$",
            variables: variables,
            episodePage: page
        )
    }

    /// nested 侧是否有任一字段偏离默认值。持久化会重写整张规则表，
    /// 因此未被选中的一侧只要自定义过就必须保留。
    var hasNestedConfig: Bool {
        roadsPath != "$.data.roads[*]" ||
            roadNamePath != "$.name" ||
            episodesPath != "$.episodes[*]" ||
            episodeNamePath != "$.name" ||
            episodeUrlPath != "$.url"
    }

    var hasDelimitedConfig: Bool {
        !roadNamesPath.isEmpty || !roadEpisodesPath.isEmpty
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "request": request.toJSON(),
            "format": .string(format.rawValue)
        ]
        if format == .nested || hasNestedConfig {
            object["roadsPath"] = .string(roadsPath)
            object["roadNamePath"] = .string(roadNamePath)
            object["episodesPath"] = .string(episodesPath)
            object["episodeNamePath"] = .string(episodeNamePath)
            object["episodeUrlPath"] = .string(episodeUrlPath)
        }
        if format == .delimited || hasDelimitedConfig {
            object["roadNamesPath"] = .string(roadNamesPath)
            object["roadEpisodesPath"] = .string(roadEpisodesPath)
            object["roadSeparator"] = .string(roadSeparator)
            object["episodeSeparator"] = .string(episodeSeparator)
            object["fieldSeparator"] = .string(fieldSeparator)
        }
        if !variables.isEmpty {
            object["variables"] = .object(variables.mapValues(JSONValue.string))
        }
        if let episodePage {
            object["episodePage"] = episodePage.toJSON()
        }
        return .object(object)
    }
}
