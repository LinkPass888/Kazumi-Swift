//
//  KazumiLog.swift
//  Kazumi
//
//  统一日志出口（对照 services/logging/logger.dart）。
//  Logger 为值类型、Sendable，可安全地在 main actor 之外使用。
//

import Foundation
import os

enum KazumiLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.kazumi"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let plugin = Logger(subsystem: subsystem, category: "Plugin")
    static let player = Logger(subsystem: subsystem, category: "Player")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
    static let webdav = Logger(subsystem: subsystem, category: "WebDAV")
    static let danmaku = Logger(subsystem: subsystem, category: "Danmaku")
    static let sync = Logger(subsystem: subsystem, category: "SyncPlay")
    static let cast = Logger(subsystem: subsystem, category: "Cast")
}
