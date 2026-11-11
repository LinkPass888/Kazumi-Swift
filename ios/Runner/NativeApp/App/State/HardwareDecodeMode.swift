//
//  HardwareDecodeMode.swift
//  Kazumi
//
//  硬件解码档位。搬出 SettingsStore.swift 是因为播放内核要读它，
//  而 SettingsStore 本身带 iOS 侧的存储与界面依赖。
//

import Foundation

/// 硬件解码档位：直通（解码帧留在 GPU 侧）/ 非直通（可复制帧）。
enum HardwareDecodeMode: String, CaseIterable, Identifiable, Sendable {
    case videotoolbox
    case videotoolboxCopy = "videotoolbox-copy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videotoolbox: String(localized: "直通")
        case .videotoolboxCopy: String(localized: "非直通")
        }
    }
}
