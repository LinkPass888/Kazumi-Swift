//
//  HTTPHeaders.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/http_headers.dart + lib/utils/constants.dart 中的
//  userAgentsList / acceptLanguageList，用于规避站点对固定 UA 的封锁。
//

import Foundation

enum HTTPHeaders {
    /// 与 constants.dart 的 `userAgentsList` 逐条一致（共 10 条）。
    static let userAgents: [String] = [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.1",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0"
    ]

    /// 与 constants.dart 的 `acceptLanguageList` 逐条一致（共 3 条）。
    static let acceptLanguages: [String] = [
        "zh-CN,zh;q=0.9",
        "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
        "zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6"
    ]

    static func randomUserAgent() -> String {
        userAgents.randomElement() ?? userAgents[0]
    }

    static func randomAcceptLanguage() -> String {
        acceptLanguages.randomElement() ?? acceptLanguages[0]
    }

    /// 网页抓取（XPath 规则）默认头。
    static func browserHeaders(referer: String?) -> [String: String] {
        var headers: [String: String] = [
            "user-agent": randomUserAgent(),
            "accept-language": randomAcceptLanguage(),
            "connection": "keep-alive"
        ]
        if let referer, !referer.isEmpty {
            headers["referer"] = referer
        }
        return headers
    }

    /// Bangumi API 文档要求的 UA（constants.dart 的 bangumiiHTTPHeader）。
    static func bangumiHeaders() -> [String: String] {
        [
            "user-agent": "Predidit/Kazumi/\(KazumiAppInfo.version) (Android) (https://github.com/Predidit/Kazumi)",
            "content-type": "application/json"
        ]
    }
}
