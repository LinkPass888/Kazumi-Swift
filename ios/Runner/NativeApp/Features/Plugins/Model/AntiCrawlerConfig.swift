//
//  AntiCrawlerConfig.swift
//  Kazumi
//
//  1:1 翻译 lib/plugins/anti_crawler_config.dart。
//

import Foundation

/// 反反爬虫验证类型。
enum CaptchaType: Int, Sendable {
    case imageCaptcha = 1
    case autoClickButton = 2
    case customJavaScript = 3
}

/// 验证页检测方式。
enum CaptchaDetectType: Int, Sendable {
    case xpath = 1
    case text = 2
    case regex = 3
}

/// 反反爬虫配置。
///
/// 仅当 XPath 搜索响应被判定为验证页时，才用 WebView 加载搜索页，
/// 按 captchaType 完成验证并保存 Cookie，随后重试 XPath 搜索。
struct AntiCrawlerConfig: Hashable, Sendable {
    var enabled: Bool
    var captchaType: CaptchaType
    var captchaImage: String
    var captchaInput: String
    var captchaButton: String
    var captchaDetectType: CaptchaDetectType
    var captchaDetectValue: String
    var captchaScript: String

    static let empty = AntiCrawlerConfig(
        enabled: false,
        captchaType: .imageCaptcha,
        captchaImage: "",
        captchaInput: "",
        captchaButton: "",
        captchaDetectType: .xpath,
        captchaDetectValue: "",
        captchaScript: ""
    )

    init(
        enabled: Bool,
        captchaType: CaptchaType,
        captchaImage: String,
        captchaInput: String,
        captchaButton: String,
        captchaDetectType: CaptchaDetectType = .xpath,
        captchaDetectValue: String = "",
        captchaScript: String = ""
    ) {
        self.enabled = enabled
        self.captchaType = captchaType
        self.captchaImage = captchaImage
        self.captchaInput = captchaInput
        self.captchaButton = captchaButton
        self.captchaDetectType = captchaDetectType
        self.captchaDetectValue = captchaDetectValue
        self.captchaScript = captchaScript
    }

    init(json: JSONValue?) {
        let object = json?.objectValue ?? [:]
        self.init(
            enabled: object["enabled"]?.boolValue ?? false,
            captchaType: CaptchaType(rawValue: object["captchaType"]?.intValue ?? 1) ?? .imageCaptcha,
            captchaImage: object["captchaImage"]?.stringValue ?? "",
            captchaInput: object["captchaInput"]?.stringValue ?? "",
            captchaButton: object["captchaButton"]?.stringValue ?? "",
            captchaDetectType: CaptchaDetectType(rawValue: object["captchaDetectType"]?.intValue ?? 1) ?? .xpath,
            captchaDetectValue: object["captchaDetectValue"]?.stringValue ?? "",
            captchaScript: object["captchaScript"]?.stringValue ?? ""
        )
    }

    func toJSON() -> JSONValue {
        .object([
            "enabled": .bool(enabled),
            "captchaType": .int(captchaType.rawValue),
            "captchaImage": .string(captchaImage),
            "captchaInput": .string(captchaInput),
            "captchaButton": .string(captchaButton),
            "captchaDetectType": .int(captchaDetectType.rawValue),
            "captchaDetectValue": .string(captchaDetectValue),
            "captchaScript": .string(captchaScript)
        ])
    }
}
