//
//  KazumiRuleLink.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/encoding.dart 的 kazumi:// 规则链接编解码。
//
//  链接形如 `kazumi://<base64(utf8(json))>`，可能被聊天软件换行包裹或被 URI
//  handler 百分号编码，因此解码时先 percent-decode、去空白，再兼容 URL-safe
//  Base64 与缺失的 padding。
//

import Foundation

struct KazumiRuleLinkSegment: Sendable {
    var scheme: String
    var rawPayload: String
}

enum KazumiRuleLinkError: Error, LocalizedError, Sendable {
    case invalidLink
    case invalidEncoding
    case empty
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidLink: "Invalid Kazumi rule link"
        case .invalidEncoding: "Invalid encoding in Kazumi rule link"
        case .empty: "Kazumi rule link is empty"
        case .invalidPayload: "Invalid Kazumi rule link payload"
        }
    }
}

enum KazumiRuleLink {
    /// 与 Dart 的 `RegExp(r'kazumi:(?://)?', caseSensitive: false)` 一致。
    private static let schemePattern = try! NSRegularExpression(
        pattern: "kazumi:(?://)?",
        options: [.caseInsensitive]
    )

    static func encode(json: String) -> String {
        "kazumi://" + Data(json.utf8).base64EncodedString()
    }

    /// 找出输入中所有规则链接片段（payload 到下一个链接或字符串末尾）。
    static func segments(in input: String) -> [KazumiRuleLinkSegment] {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = schemePattern.matches(in: input, options: [], range: range)
        var segments: [KazumiRuleLinkSegment] = []
        for (index, match) in matches.enumerated() {
            guard let schemeRange = Range(match.range, in: input),
                  let endRange = Range(match.range, in: input) else { continue }
            let payloadEnd: String.Index
            if index + 1 < matches.count,
               let nextStart = Range(matches[index + 1].range, in: input)?.lowerBound {
                payloadEnd = nextStart
            } else {
                payloadEnd = input.endIndex
            }
            segments.append(KazumiRuleLinkSegment(
                scheme: String(input[schemeRange]),
                rawPayload: String(input[endRange.upperBound..<payloadEnd])
            ))
        }
        return segments
    }

    /// 解码 `kazumi://...` 形式的链接为 JSON 文本。
    ///
    /// 为了兼容聊天软件把 `+` 转成空格、或把链接换行包裹的情况，先做
    /// percent-decode，再在一次扫描中去掉空白并把空格还原为 `+`。
    static func decode(_ link: String) throws -> String {
        let input = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = schemePattern.firstMatch(
            in: input,
            options: [.anchored],
            range: NSRange(input.startIndex..<input.endIndex, in: input)
        ), let schemeRange = Range(match.range, in: input),
           schemeRange.lowerBound == input.startIndex else {
            throw KazumiRuleLinkError.invalidLink
        }

        let payload = String(input[schemeRange.upperBound...])
        guard let percentDecoded = payload.removingPercentEncoding else {
            throw KazumiRuleLinkError.invalidEncoding
        }
        var normalizedCharacters = ""
        normalizedCharacters.reserveCapacity(percentDecoded.count)
        for char in percentDecoded {
            if char == " " {
                normalizedCharacters.append("+")
            } else if !char.isWhitespace {
                normalizedCharacters.append(char)
            }
        }
        guard !normalizedCharacters.isEmpty else { throw KazumiRuleLinkError.empty }

        let normalized = normalizedCharacters
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = normalizeBase64(normalized).flatMap({ Foundation.Data(base64Encoded: $0) }),
              let json = String(data: data, encoding: .utf8) else {
            throw KazumiRuleLinkError.invalidPayload
        }
        return json
    }

    /// 对应 Dart 的 `base64.normalize`：补齐 padding，非法长度直接判失败。
    private static func normalizeBase64(_ value: String) -> String? {
        var normalized = value
        if normalized.count % 4 != 0 {
            guard normalized.count % 4 != 1 else { return nil }
            normalized += String(repeating: "=", count: 4 - normalized.count % 4)
        }
        return normalized
    }
}
