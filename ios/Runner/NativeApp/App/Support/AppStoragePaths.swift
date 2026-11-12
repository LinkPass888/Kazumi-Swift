//
//  AppStoragePaths.swift
//  Kazumi
//
//  存储目录的唯一出处。iOS 的 `AppEnvironment` 与 macOS target 都读这一份。
//
//  为什么要单独拆出来：macOS target 只带底层（规则模型 / 引擎 / 网络层），
//  而 `PluginsController.defaultFileURL` 要 `rulesRoot`；`AppEnvironment` 整个类
//  又带着 SettingsStore、LibraryStore、DownloadCenter 这些界面/业务依赖，搬不动。
//  这里只留纯 Foundation 的几个路径，两边各取所需。
//
//  目录形状与 iOS 侧一致：Application Support/Kazumi/{rules,cache,images,snapshots}。
//

import Foundation

enum AppStoragePaths {
    /// 系统给的 Application Support 目录。
    static var applicationSupportRoot: URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
    }

    /// 存储根目录：Application Support/Kazumi。
    static var storageRoot: URL {
        applicationSupportRoot.appending(path: "Kazumi", directoryHint: .isDirectory)
    }

    /// 规则目录（内置规则与订阅规则）。
    static var rulesRoot: URL {
        storageRoot.appending(path: "rules", directoryHint: .isDirectory)
    }

    /// 图片缓存目录。
    static var imagesRoot: URL {
        storageRoot.appending(path: "images", directoryHint: .isDirectory)
    }

    /// 通用缓存目录。
    static var cacheRoot: URL {
        storageRoot.appending(path: "cache", directoryHint: .isDirectory)
    }

    /// 建好存储根与它下面的固定几个子目录（幂等）。
    ///
    /// 下载目录不在这里：那个开在 Documents 里，只有 iOS 需要，
    /// 由 `AppEnvironment.prepareStorageDirectories` 自己补。
    @discardableResult
    static func prepareDirectories() throws -> URL {
        let manager = FileManager.default
        let root = storageRoot
        for directory in [root, rulesRoot, cacheRoot, imagesRoot] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }
}