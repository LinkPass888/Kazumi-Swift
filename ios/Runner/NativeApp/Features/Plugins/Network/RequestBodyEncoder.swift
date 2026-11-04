//
//  RequestBodyEncoder.swift
//  Kazumi
//
//  API 规则的请求体编码：
//  * JSON：把 JSONValue 直接序列化为 JSON 文本（不会被二次转义成字符串）；
//  * form：对应 Dio 的 FormData，数组展开为同名重复字段，对象值转成字符串。
//

import Foundation

enum JsonBodyEncoder {
    static func encode(_ value: JSONValue) throws -> Data {
        let text = value.serialized(pretty: false)
        guard let data = text.data(using: .utf8) else {
            throw NetworkError.decoding(String(localized: "请求体无法编码为 UTF-8"))
        }
        return data
    }
}

enum FormBodyEncoder {
    static func encode(_ value: JSONValue) -> String {
        var pairs: [String] = []
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                guard let item = object[key] else { continue }
                append(name: key, value: item, into: &pairs)
            }
        case .array(let array):
            for item in array {
                append(name: "", value: item, into: &pairs)
            }
        case .null:
            break
        default:
            pairs.append(scalar(value, name: nil))
        }
        return pairs.joined(separator: "&")
    }

    private static func append(name: String, value: JSONValue, into pairs: inout [String]) {
        switch value {
        case .array(let items):
            for item in items {
                pairs.append(scalar(item, name: name))
            }
        case .object, .null, .bool, .int, .double, .string:
            pairs.append(scalar(value, name: name))
        }
    }

    private static func scalar(_ value: JSONValue, name: String?) -> String {
        let text = value.stringValue ?? value.serialized(pretty: false)
        let encoded = encodeComponent(text)
        guard let name else { return encoded }
        return "\(encodeComponent(name))=\(encoded)"
    }

    /// 表单编码：空格应为 `+`（与 Dart Uri.encodeQueryComponent 一致）。
    private static func encodeComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~*!'()")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}
