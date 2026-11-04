//
//  KazumiAppInfo.swift
//  Kazumi
//
//  运行时元信息。数值全部来自 Info.plist / Build Settings，
//  与原 pubspec.yaml 的 `version: 2.4.8+20408` 保持同步。
//

import Foundation

enum KazumiAppInfo {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Kazumi"
    }

    static var bundleName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "kazumi"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.example.kazumi"
    }

    /// 对应原工程 ApiEndpoints.version（用于规则 API 级别与 Bangumi 请求 UA）。
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var fullVersion: String {
        "\(version)+\(buildNumber)"
    }

    /// 对应 ApiEndpoints.apiLevel：规则 JSON 的 apiLevel 字段用于判断兼容性。
    static let ruleAPILevel = 9

    static let projectURL = URL(string: "https://kazumi.app/")!
    static let sourceURL = URL(string: "https://github.com/LinkPass888/Kazumi-LiquidGlass-iOS")!
    static let issuesURL = URL(string: "https://github.com/LinkPass888/Kazumi-LiquidGlass-iOS/issues")!
    static let releasesURL = URL(string: "https://github.com/LinkPass888/Kazumi-LiquidGlass-iOS/releases")!
    /// 官方频道（原版的 Telegram 入口）。
    static let telegramURL = URL(string: "https://t.me/linkpass666")!
    static let iconAuthorURL = URL(string: "https://www.pixiv.net/users/66219277")!
    static let dandanIndexURL = URL(string: "https://www.dandanplay.com/")!
    static let traceMoeURL = URL(string: "https://trace.moe")!
    static let bangumiIndexURL = URL(string: "https://bangumi.tv/")!
    static let bangumiDataIndexURL = URL(string: "https://github.com/bangumi-data/bangumi-data")!
    static let bangumiMALIndexURL = URL(string: "https://github.com/LinkPass888/bangumi-mal")!
    static let bangumiExtLinkerURL = URL(string: "https://github.com/Rhilip/BangumiExtLinker")!
    static let aniSkipIndexURL = URL(string: "https://github.com/aniskip")!
    static let aniListIndexURL = URL(string: "https://anilist.co")!
    /// 播放内核（LP 3671–3673：KSPlayer → mpv）。
    static let mpvKitURL = URL(string: "https://github.com/mpvkit/MPVKit")!
    static let mpvURL = URL(string: "https://mpv.io")!
    static let fuziURL = URL(string: "https://github.com/cezheng/Fuzi")!
    static let anime4KURL = URL(string: "https://github.com/bloc97/Anime4K")!
    static let licenseURL = URL(string: "https://github.com/LinkPass888/Kazumi-LiquidGlass-iOS/blob/main/LICENSE")!
    /// 原版「开源」一节里的「贡献指南」，指向仓库里的 CONTRIBUTING.md（static/doc/CONTRIBUTING.md）。
    static let contributingURL = URL(string: "https://github.com/LinkPass888/Kazumi-LiquidGlass-iOS/blob/main/static/doc/CONTRIBUTING.md")!
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/LinkPass888/Kazumi-LiquidGlass-iOS/releases/latest")!
}
