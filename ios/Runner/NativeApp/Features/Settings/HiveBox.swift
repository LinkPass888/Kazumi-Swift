//
//  HiveBox.swift
//  Kazumi
//
//  原版（Flutter）留在云盘上的 `collectibles.tmp` / `collectchanges.tmp` 是
//  Hive 的箱体文件，二进制，没有现成的解。这里只实现够用的一小层：
//  把箱子读成「键 → 值」，值按类型编号解成限定的几种。
//
//  格式是按 LP 云盘上那份真实文件（1,190,084 字节、718 条收藏）逐字节验出来的，
//  不是照文档猜的。详细结论记在 notes/hive-format-findings.md，要点：
//
//  ```
//  帧：  [u32 LE 帧总长 L，含这 4 字节][body，L-4 字节]
//  body：[u8 帧类型，恒 0][u32 LE 键][值...][4 字节校验，跳过]
//  ```
//
//  值的前一字节是类型编号：
//   0   null
//   1   double（8 字节）      2   double（8 字节，评分用它）
//   4   String：u32 长度 + UTF-8
//   6   纯数字表：u32 个数 + 每个 8 字节 double（不带各自类型编号）
//   9   纯字符串表：u32 个数 + 每项 u32 长度 + UTF-8
//   10  普通列表：u32 个数 + 每项（类型编号 + 值）
//   11  映射：u32 对数 + 每对（类型编号 + 键，类型编号 + 值）
//   18  DateTime：8 字节 double 毫秒数 + 1 字节标志
//   ≥32 自定义对象：类型编号 = 适配器 typeId + 32，
//        内容为 u8 字段数 + 每字段（u8 字段号，类型编号 + 值）
//  ```
//
//  718 帧全部解通、每帧尾部正好 4 字节校验——这条是解对了的判据。
//

import Foundation

enum HiveBox {
    /// 解出来的值。只需要这几种：原版的收藏、变更队列用到的都在里面。
    indirect enum Value {
        case null
        case number(Double)
        case string(String)
        case list([Value])
        /// 映射保留插入顺序，键也是解出来的值（原版写的是字符串键）。
        case map([(key: Value, value: Value)])
        case object(type: Int, fields: [Int: Value])

        var numberValue: Double? {
            switch self {
            case .number(let value): value
            case .string(let text): Double(text)
            default: nil
            }
        }

        var intValue: Int? { numberValue.map { Int($0) } }

        var stringValue: String? {
            switch self {
            case .string(let text): text
            case .number(let value): String(Int(value))
            default: nil
            }
        }

        var listValue: [Value]? {
            if case .list(let items) = self { return items }
            return nil
        }

        var objectFields: [Int: Value]? {
            if case .object(_, let fields) = self { return fields }
            return nil
        }

        /// 映射里按字符串键取值。
        func mapValue(_ key: String) -> Value? {
            guard case .map(let pairs) = self else { return nil }
            for pair in pairs where pair.key.stringValue == key { return pair.value }
            return nil
        }
    }

    struct Entry {
        var key: Int
        var value: Value
    }

    /// 遇到没见过的类型编号 / 文件被截断：这一条读不出来，交给上层当「没有」。
    struct DecodeError: Error, CustomStringConvertible {
        var description: String
    }

    static func read(_ data: Data) throws -> [Entry] {
        var reader = Reader(bytes: [UInt8](data))
        var entries: [Entry] = []
        while reader.remaining >= 4 {
            let frameStart = reader.offset
            let length = Int(try reader.u32())
            // 帧长含这 4 字节；小于 4 或越过文件末尾就是坏文件，停在这里。
            guard length >= 4, reader.offset + length - 4 <= reader.bytes.count else {
                throw DecodeError(description: String(localized: "帧长越界（偏移 \(String(describing: frameStart))，帧长 \(String(describing: length))）"))
            }
            let frameEnd = reader.offset + length - 4
            _ = try reader.u8() // 帧类型，实测恒为 0
            let key = Int(try reader.u32())
            let value = try reader.value()
            entries.append(Entry(key: key, value: value))
            // 帧尾 4 字节校验（原版不校验，我们也不校验，只是跳过）。
            reader.offset = frameEnd
        }
        return entries
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int = 0

        var remaining: Int { bytes.count - offset }

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodeError(description: String(localized: "读越界")) }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw DecodeError(description: "读越界") }
            let value = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            offset += 4
            return value
        }

        mutating func f64() throws -> Double {
            guard offset + 8 <= bytes.count else { throw DecodeError(description: "读越界") }
            var bits: UInt64 = 0
            for index in 0..<8 {
                bits |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
            }
            offset += 8
            return Double(bitPattern: bits)
        }

        mutating func text() throws -> String {
            let length = Int(try u32())
            guard offset + length <= bytes.count else { throw DecodeError(description: String(localized: "字符串越界")) }
            let slice = bytes[offset..<(offset + length)]
            offset += length
            return String(decoding: slice, as: UTF8.self)
        }

        mutating func value() throws -> Value {
            let typeOffset = offset
            let type = Int(try u8())
            switch type {
            case 0:
                return .null
            case 1, 2:
                return .number(try f64())
            case 4:
                return .string(try text())
            case 6:
                let count = Int(try u32())
                var items: [Value] = []
                guard count <= remaining else { throw DecodeError(description: "读越界") }
                items.reserveCapacity(count)
                for _ in 0..<count { items.append(.number(try f64())) }
                return .list(items)
            case 9:
                let count = Int(try u32())
                var items: [Value] = []
                guard count <= remaining else { throw DecodeError(description: "读越界") }
                items.reserveCapacity(count)
                for _ in 0..<count { items.append(.string(try text())) }
                return .list(items)
            case 10:
                let count = Int(try u32())
                var items: [Value] = []
                guard count <= remaining else { throw DecodeError(description: "读越界") }
                items.reserveCapacity(count)
                for _ in 0..<count { items.append(try value()) }
                return .list(items)
            case 11:
                let count = Int(try u32())
                var pairs: [(key: Value, value: Value)] = []
                guard count <= remaining else { throw DecodeError(description: "读越界") }
                pairs.reserveCapacity(count)
                for _ in 0..<count {
                    let key = try value()
                    let item = try value()
                    pairs.append((key: key, value: item))
                }
                return .map(pairs)
            case 18:
                let milliseconds = try f64()
                _ = try u8() // 时区标志：原版写的一直是 0
                return .number(milliseconds)
            case let custom where custom >= 32:
                let count = Int(try u8())
                var fields: [Int: Value] = [:]
                for _ in 0..<count {
                    let fieldNumber = Int(try u8())
                    fields[fieldNumber] = try value()
                }
                return .object(type: custom - 32, fields: fields)
            default:
                throw DecodeError(description: String(localized: "没见过的类型编号 \(String(describing: type))（偏移 \(String(describing: typeOffset))）"))
            }
        }
    }
}
