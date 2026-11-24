//
//  KazumiLogBuffer.swift
//  Kazumi
//
//  os.Logger 的写入无法被 App 自身读回，而「运行日志」页需要可复制的文本，
//  因此在关键路径（规则检索、选源、播放）额外写一份环形缓冲。
//  使用 OSAllocatedUnfairLock 保护，Sendable 且不阻塞主线程。
//

import Foundation
import os

final class KazumiLogBuffer: Sendable {
    static let shared = KazumiLogBuffer()

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case plugin
        case network
        case player
        case storage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plugin: String(localized: "规则")
            case .network: String(localized: "网络")
            case .player: String(localized: "播放")
            case .storage: String(localized: "存储")
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let category: Category
        let timestamp: Date
        let message: String
    }

    /// 固定容量的环形桶：写满后原地覆盖最旧槽位，避免每次插入都 `removeFirst` 搬移整个数组。
    private struct RingBucket: Sendable {
        private var buffer: [Entry] = []
        private var nextWriteIndex: Int = 0

        mutating func append(_ entry: Entry, capacity: Int) {
            if buffer.count < capacity {
                buffer.append(entry)
            } else {
                buffer[nextWriteIndex] = entry
                nextWriteIndex = (nextWriteIndex + 1) % capacity
            }
        }

        func entriesInOrder() -> [Entry] {
            guard nextWriteIndex > 0, !buffer.isEmpty else { return buffer }
            var ordered: [Entry] = []
            ordered.reserveCapacity(buffer.count)
            ordered.append(contentsOf: buffer[nextWriteIndex...])
            ordered.append(contentsOf: buffer[..<nextWriteIndex])
            return ordered
        }
    }

    /// 每个分类最多保留的条数，超出后丢弃最旧的记录。
    private static let capacity = 200

    private let storage = OSAllocatedUnfairLock(initialState: [Category: RingBucket]())

    func append(_ message: String, category: Category) {
        let entry = Entry(category: category, timestamp: Date(), message: message)
        storage.withLock { buckets in
            var bucket = buckets[category] ?? RingBucket()
            bucket.append(entry, capacity: Self.capacity)
            buckets[category] = bucket
        }
    }

    func snapshot() -> [Entry] {
        storage.withLock { buckets in
            buckets.values
                .flatMap { $0.entriesInOrder() }
                .sorted { $0.timestamp < $1.timestamp }
        }
    }

    func clear(_ category: Category) {
        storage.withLock { $0[category] = nil }
    }

    func clearAll() {
        storage.withLock { $0.removeAll() }
    }
}

/// Pure text export of a chronological snapshot (or a category-filtered snapshot).
/// Build one formatter per export, shared by all entries, without mutable global state.
enum KazumiLogExport {
    static func text(from entries: [KazumiLogBuffer.Entry], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"

        // Keep snapshot order, including entries with equal timestamps. Prefix every
        // physical line, including blank lines, so multiline messages remain traceable.
        return entries.flatMap { entry in
            let prefix = "[\(formatter.string(from: entry.timestamp))] "
            return entry.message
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: .newlines)
                .map { prefix + $0 }
        }.joined(separator: "\n")
    }
}

extension KazumiLogBuffer {
    /// 记录规则检索结果（与 os.Logger 的输出并行写入缓冲）。
    static func plugin(_ message: String) {
        KazumiLog.plugin.info("\(message, privacy: .public)")
        shared.append(message, category: .plugin)
    }

    static func network(_ message: String) {
        KazumiLog.network.info("\(message, privacy: .public)")
        shared.append(message, category: .network)
    }

    static func player(_ message: String) {
        KazumiLog.player.info("\(message, privacy: .public)")
        shared.append(message, category: .player)
    }

    static func storage(_ message: String) {
        KazumiLog.storage.info("\(message, privacy: .public)")
        shared.append(message, category: .storage)
    }
}
