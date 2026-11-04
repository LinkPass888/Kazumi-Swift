//
//  PluginValidityTracker.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/plugin_validity_tracker.dart。
//  只追踪搜索有效性：本次启动后是否成功返回过搜索结果，
//  用于在规则列表里提示失效规则。
//

import Foundation

final class PluginValidityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var searchValidPlugins: Set<String> = []

    func markSearchValid(_ pluginName: String) {
        lock.lock()
        searchValidPlugins.insert(pluginNameKey(pluginName))
        lock.unlock()
    }

    func isSearchValid(_ pluginName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return searchValidPlugins.contains(pluginNameKey(pluginName))
    }

    func reset() {
        lock.lock()
        searchValidPlugins.removeAll()
        lock.unlock()
    }
}
