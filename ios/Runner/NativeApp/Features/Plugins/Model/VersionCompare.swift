//
//  VersionCompare.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/version.dart 的 needUpdate。
//  Dart 版本对非数字段直接抛异常；这里把非数字段当作 0，避免坏规则数据让启动失败。
//

import Foundation

enum VersionCompare {
    /// 远端版本是否比本地新。
    static func needUpdate(local: String, remote: String) -> Bool {
        let localParts = local.split(separator: ".", omittingEmptySubsequences: false)
        let remoteParts = remote.split(separator: ".", omittingEmptySubsequences: false)
        let maxLength = max(localParts.count, remoteParts.count)
        for index in 0..<maxLength {
            let localSegment = index < localParts.count ? segment(localParts[index]) : 0
            let remoteSegment = index < remoteParts.count ? segment(remoteParts[index]) : 0
            if remoteSegment > localSegment { return true }
            if remoteSegment < localSegment { return false }
        }
        return false
    }

    private static func segment(_ value: Substring) -> Int {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
