//
//  RuleError.swift
//  Kazumi
//
//  规则引擎的错误与结果模型，1:1 对应 services/plugin/rule_engine_models.dart、
//  xpath_rule_strategy.dart、api_rule_strategy.dart 中的定义。
//

import Foundation

/// 对应 Dart 的 SearchItem（modules/search/plugin_search_module.dart）。
struct SearchItem: Hashable, Sendable {
    var name: String
    var src: String
}

/// 对应 Dart 的 PluginSearchResponse。
struct PluginSearchResponse: Hashable, Sendable {
    var pluginName: String
    var data: [SearchItem]
}

/// 对应 Dart 的 Road（modules/roads/road_module.dart）。
struct Road: Hashable, Sendable {
    var name: String
    var data: [String]
    var identifier: [String]
}

/// 对应 Dart 的 PluginSearchStatus：单条规则的搜索进度。
enum PluginSearchStatus: String, Sendable {
    case pending
    case success
    case error
    case noResult
    case captcha
}

/// 规则引擎错误，对应 CaptchaRequiredException / NoResultException /
/// SearchErrorException / ChapterErrorException。
enum RuleError: Error, LocalizedError, Sendable {
    case captchaRequired(plugin: String)
    case noResult(plugin: String)
    case searchFailed(plugin: String, cause: String?)
    case chapterFailed(plugin: String, cause: String?)

    var errorDescription: String? {
        switch self {
        case .captchaRequired(let plugin):
            String(localized: "\(String(describing: plugin)) 需要完成验证")
        case .noResult(let plugin):
            String(localized: "\(String(describing: plugin)) 没有搜索结果")
        // 上屏不带 cause：cause 是给日志看的，拿不到人话时就是 Swift 的类型转储，
        // 一长串机器话会压在播放页正中间（Camo 3285）。
        // 跟「详情没能加载」「推荐没能加载」「列表没能加载」同一家的说法。
        case .searchFailed(let plugin, _):
            String(localized: "\(String(describing: plugin)) 的检索没能加载")
        case .chapterFailed(let plugin, _):
            String(localized: "\(String(describing: plugin)) 的剧集没能加载")
        }
    }

    var pluginName: String {
        switch self {
        case .captchaRequired(let plugin), .noResult(let plugin),
             .searchFailed(let plugin, _), .chapterFailed(let plugin, _):
            plugin
        }
    }
}

/// 对应 XPathRuleFormatException 的 kind 枚举。
enum XPathRuleFormatKind: String, Sendable {
    case invalidUrl
    case invalidDocument
    case invalidSelector
}

/// 对应 XPathRuleField。
enum XPathRuleField: String, Sendable {
    case searchList
    case searchName
    case searchResult
    case chapterRoads
    case chapterResult
    case captchaDetectValue
    case captchaImage
    case captchaButton

    /// 与原项目 _fieldLabel 的中文措辞保持一致，错误提示可直接复用。
    var label: String {
        switch self {
        case .searchList: String(localized: "搜索结果列表")
        case .searchName: String(localized: "条目名称")
        case .searchResult: String(localized: "条目链接")
        case .chapterRoads: String(localized: "播放线路列表")
        case .chapterResult: String(localized: "剧集列表")
        case .captchaDetectValue: String(localized: "验证页检测")
        case .captchaImage: String(localized: "验证码图片")
        case .captchaButton: String(localized: "验证按钮")
        }
    }
}

/// XPath 规则格式错误（对应 XPathRuleFormatException）。
struct XPathRuleFormatError: Error, LocalizedError, Sendable {
    let message: String
    let kind: XPathRuleFormatKind
    var field: XPathRuleField?
    var expression: String?
    var cause: String?

    var errorDescription: String? {
        "XPathRuleFormat.\(kind.rawValue): \(message)\(cause.map { " (\($0))" } ?? "")"
    }
}

/// API 规则格式错误（对应 ApiRuleFormatException）。
struct ApiRuleFormatError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { "ApiRuleFormat: \(message)" }
}

/// 网络错误：对应 NetworkException 的 cancel / badResponse 分支。
enum NetworkError: Error, LocalizedError, Sendable {
    case cancelled
    case badResponse(status: Int, body: String, headers: [String: String])
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "请求已取消")
        case .badResponse(let status, _, _): String(localized: "服务器返回 HTTP \(String(describing: status))")
        case .transport(let message): message
        case .decoding(let message): message
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
