//
//  SettingsBackup.swift
//  Kazumi
//
//  设置备份的编解码，1:1 对应 lib/services/storage/settings_backup.dart。
//  备份是一段 JSON 文本：
//    {"app":"Kazumi","version":1,"exportedAt":"...","settings":{"键":"值"}}
//  「键」用原版 Hive 设置箱的键名，于是旧版（Flutter）导出的备份能原样导入，
//  这边导出的备份旧版也认。
//

import Foundation

/// 设置备份的编解码。
enum SettingsBackup {
    /// 备份格式版本。与原版一致：字段不兼容时递增，导入端据此拒绝。
    static let version = 1
    /// 备份文件的应用标识。
    static let appIdentifier = "Kazumi"

    /// 凭据类键（键名用的是原版 Hive 键名）：包含追番、WebDAV、代理和自定义弹幕接口。
    /// 对应原版 backup_settings.dart 的
    /// `_credentialKeys` ——「不含账号与密码」的导出会跳过这些键，
    /// 恢复前的确认弹窗也据它提示用户重新确认凭据。
    ///
    /// 原版这份清单里写的是 `webDavPassword`，而设置箱里实际的键名是
    /// `webDavPasswd`（见 lib/services/storage/settings_keys.dart:760），
    /// 于是原版那句「备份包含账号或代理密码」的提示永远不会触发。
    /// 这边按真实键名列出，提示才真的有用；导出的范围仍与原版一致。
    static let credentialKeys: Set<String> = [
        "bangumiAccessToken",
        "webDavUsername",
        "webDavPasswd",
        "webDavURL",
        "proxyUrl",
        "proxyTestUrl",
        "danmakuAPIURL",
        "danmakuAPIRequestHeaders",
    ]

    /// 解析后的备份内容。
    struct Payload {
        /// 键名 -> 设置值。
        var settings: [String: JSONValue]
        /// 备份创建时间；备份里没写或格式不对时为 nil。
        var exportedAt: Date?
        /// 可恢复的设置项数量。
        var count: Int { settings.count }
    }

    /// 备份格式不对时抛出，消息可直接展示给用户。
    enum BackupError: LocalizedError {
        case invalidJSON
        case notKazumiBackup
        case unknownVersion
        case futureVersion
        case emptySettings

        var errorDescription: String? {
            switch self {
            case .invalidJSON: String(localized: "备份内容不完整，可能复制或导出时被截断了")
            case .notKazumiBackup: String(localized: "这不是 Kazumi 的设置备份")
            case .unknownVersion: String(localized: "备份版本无法识别")
            case .futureVersion: String(localized: "备份来自更新版本的 Kazumi，请先升级应用")
            case .emptySettings: String(localized: "备份里没有设置内容")
            }
        }
    }

    /// 解析备份文本。格式不对时抛出 [BackupError]。
    static func decode(_ text: String) throws -> Payload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw BackupError.invalidJSON
        }
        let json: JSONValue
        do {
            json = try JSONValue.decode(data)
        } catch {
            throw BackupError.invalidJSON
        }
        guard json["app"].stringValue == appIdentifier else {
            throw BackupError.notKazumiBackup
        }
        guard let fileVersion = json["version"].intValue, fileVersion >= 1 else {
            throw BackupError.unknownVersion
        }
        if fileVersion > version {
            throw BackupError.futureVersion
        }
        guard let rawSettings = json["settings"].objectValue else {
            throw BackupError.emptySettings
        }
        var settings: [String: JSONValue] = [:]
        for (key, value) in rawSettings where isSupportedValue(value) {
            settings[key] = value
        }
        return Payload(settings: settings, exportedAt: parseDate(json["exportedAt"].stringValue ?? ""))
    }

    /// 把设置编码成备份文本。
    static func encode(_ settings: [String: JSONValue], exportedAt: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = JSONValue.dictionary([
            ("app", .string(appIdentifier)),
            ("version", .int(version)),
            ("exportedAt", .string(formatter.string(from: exportedAt))),
            ("settings", .object(settings)),
        ])
        return payload.serialized(pretty: false)
    }

    /// 只保留标量与字符串列表（与原版 _encodeValue / _decodeValue 一致）。
    private static func isSupportedValue(_ value: JSONValue) -> Bool {
        switch value {
        case .bool, .int, .double, .string:
            return true
        case .array(let items):
            return items.allSatisfy { item in
                if case .string = item { return true }
                return false
            }
        case .null, .object:
            return false
        }
    }

    /// 解析导出时间。Dart 的 toIso8601String 带毫秒，ISO8601DateFormatter
    /// 的默认格式不带，两种都要认。
    private static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
