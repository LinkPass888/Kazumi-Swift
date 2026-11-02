//
//  JSONValue.swift
//  Kazumi
//
//  规则文件中的 body / query / headers 可以是任意 JSON 结构，Codable 的固定结构
//  无法覆盖，因此用一个轻量 JSON 树承载，并提供与 Dart jsonDecode/jsonEncode
//  等价的解析与序列化。
//

import Foundation

indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        case let dictionary as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                object[String(describing: key)] = JSONValue(any: item)
            }
            self = .object(object)
        case let number as NSNumber:
            self = JSONValue(number: number)
        default:
            self = .string(String(describing: value))
        }
    }

    /// 数字要分清是布尔还是整数。
    ///
    /// 这里不能用 `case let bool as Bool`：JSONSerialization 交回来的是 NSNumber，
    /// 而 NSNumber 桥到 Bool 永远成功、`NSNumber(1)` 也会变成 `true`。
    /// 踩过一次：规则里 `"page": 1` 发出去成了 `page=true`，服务端直接报
    /// `strconv.ParseInt: parsing "true": invalid syntax`，搜不出东西（LP 3422 抓包）。
    private init(number: NSNumber) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        let value = number.doubleValue
        if value == value.rounded(), abs(value) <= 9_007_199_254_740_992 {
            self = .int(number.intValue)
        } else {
            self = .double(value)
        }
    }

    /// 按「键值对数组」构造对象字面量（后写的键覆盖先写的键）。
    /// 注意：不能与 case `.object([String: JSONValue])` 同名，否则调用点会触发
    /// `ambiguous use of 'object'`，因此单独命名为 `dictionary`。
    static func dictionary(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(pairs, uniquingKeysWith: { _, latest in latest }))
    }

    /// 与 Dart `value == null` 对齐。
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 与 Dart `value.toString()` 对齐（null 视为空串），用于模板与查询参数。
    var toStringValue: String {
        stringValue ?? ""
    }

    /// 与 Dart `value.toString()` 对齐：数字不带无意义的尾零，null 为空串由调用方决定。
    var stringValue: String? {
        switch self {
        case .null: nil
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value):
            value == value.rounded()
                ? (intValue.map { String($0) } ?? String(value))
                : String(value)
        case .string(let value): value
        case .array, .object:
            JSONValue.serialize(self, pretty: false)
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value):
            value.isFinite && value >= -9_223_372_036_854_775_808 && value < 9_223_372_036_854_775_808
                ? Int(value) : nil
        case .string(let value): Int(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        case .string(let value): value.lowercased() == "true"
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue {
        guard case .object(let object) = self, let value = object[key] else { return .null }
        return value
    }

    /// 数组下标：越界返回 `.null`。
    subscript(index: Int) -> JSONValue {
        guard case .array(let array) = self, array.indices.contains(index) else { return .null }
        return array[index]
    }

    /// 与 Dart 的 `value as double?` 对齐；整型与数字字符串同样可以取到。
    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        case .string(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    /// 与 Dart 的 `json.containsKey(key)` 语义对齐。
    var exists: Bool {
        if case .null = self { return false }
        return true
    }

    /// 把 JSON 树转换为对象字典（非对象返回空字典）。
    var dictionaryValue: [String: JSONValue] {
        objectValue ?? [:]
    }

    static func decode(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    static func decode(_ string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw ApiRuleFormatError(message: "JSON 文本不是有效 UTF-8")
        }
        return try decode(data)
    }

    func serialized(pretty: Bool = false) -> String {
        JSONValue.serialize(self, pretty: pretty)
    }

    static func serialize(_ value: JSONValue, pretty: Bool) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationObject, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 转回 Foundation 对象，供 JSONSerialization / URLSession 使用。
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundationObject)
        case .object(let value): value.mapValues(\.foundationObject)
        }
    }
}


