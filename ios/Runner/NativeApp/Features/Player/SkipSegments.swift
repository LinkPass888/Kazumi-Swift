//
//  SkipSegments.swift
//  Kazumi
//
//  一集里片头 / 片尾的位置。原生实现，对应
//  lib/services/skip/skip_segments.dart（结构、相等语义、区间判定都照搬，
//  免得两边的「同一段」判断走偏）。
//

import Foundation

/// 这一段是谁给的时间轴。目前只有 AniSkip 一条来源（指纹那条 main 里有，
/// iOS 这边还没接）。
enum SkipSource: String, Codable, Sendable, Equatable {
    case aniskip
}

/// 片头还是片尾。
enum SkipKind: String, Codable, Sendable, Equatable {
    case opening
    case ending

    /// 播放器上给用户看的叫法。
    var label: String { self == .opening ? String(localized: "片头") : String(localized: "片尾") }
}

/// 一条可跳过的区间（秒）。
struct SkipRange: Codable, Sendable, Equatable {
    /// 区间开始，相对这一集的开头。
    let start: Double
    let end: Double
    let source: SkipSource

    var length: Double { end - start }

    func contains(_ seconds: Double) -> Bool {
        seconds >= start && seconds < end
    }

    /// main 那边用 0.05 秒容差判「同一段」：弹窗状态、取消 / 跳过记录都按它比对。
    func isSame(_ other: SkipRange) -> Bool {
        abs(other.start - start) < 0.05 && abs(other.end - end) < 0.05 && other.source == source
    }
}

/// 一集的片头 + 片尾。
struct SkipSegments: Sendable, Equatable {
    var opening: SkipRange?
    var ending: SkipRange?

    static let empty = SkipSegments()

    var isEmpty: Bool { opening == nil && ending == nil }

    /// 这一秒落在哪一段里。
    func activeAt(_ seconds: Double) -> (kind: SkipKind, range: SkipRange)? {
        if let opening, opening.contains(seconds) { return (.opening, opening) }
        if let ending, ending.contains(seconds) { return (.ending, ending) }
        return nil
    }

    /// 在 `seconds` 之后 `lead` 秒内就要开始的那一段。
    func upcomingAt(_ seconds: Double, lead: Double) -> (kind: SkipKind, range: SkipRange)? {
        func startsSoon(_ range: SkipRange?) -> Bool {
            guard let range else { return false }
            return seconds < range.start && range.start - seconds <= lead
        }
        if startsSoon(opening) { return (.opening, opening!) }
        if startsSoon(ending) { return (.ending, ending!) }
        return nil
    }
}
