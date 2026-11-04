//
//  MediaUtility.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/media.dart 中与解析相关的部分。
//
//  decodeVideoSource 用于旧版解析器：iframe 的 src 常常是一个中转页，
//  真正的媒体地址藏在它的 query 参数里，需要在参数值中搜索 m3u8 / mp4。
//

import Foundation

enum MediaUtility {
    /// 对应 Dart 的 `(http[s]?://.*?\.m3u8)|(http[s]?://.*?\.mp4)`，忽略大小写，非贪婪。
    private static let mediaPattern = try! NSRegularExpression(
        pattern: "(http[s]?://.*?\\.m3u8)|(http[s]?://.*?\\.mp4)",
        options: [.caseInsensitive]
    )

    static func decodeVideoSource(_ iframeUrl: String) -> String {
        let decoded = iframeUrl.removingPercentEncoding ?? iframeUrl
        var matched = iframeUrl
        if let components = URLComponents(string: decoded) {
            for item in components.queryItems ?? [] {
                let value = item.value ?? ""
                if isMediaURL(value) {
                    matched = value
                    break
                }
            }
        }
        return encodeFull(matched)
    }

    static func isMediaURL(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return mediaPattern.firstMatch(in: value, options: [], range: range) != nil
    }

    /// 对应 Dart 的 Uri.encodeFull：保留 URL 中合法的保留字符，只编码不合法字符。
    static func encodeFull(_ url: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "#%[]")
        return url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
    }

    /// 对应 extractEpisodeNumber：匹配 `第?(\d+)[话集]?`，无法识别时返回 0。
    static func extractEpisodeNumber(_ input: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: String(localized: "第?(\\d+)[话集]?"))
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = pattern.firstMatch(in: input, options: [], range: range),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: input) else {
            return 0
        }
        return Int(input[numberRange]) ?? 0
    }
}
