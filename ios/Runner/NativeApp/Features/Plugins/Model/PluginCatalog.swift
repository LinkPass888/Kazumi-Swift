//
//  PluginCatalog.swift
//  Kazumi
//
//  1:1 翻译 lib/modules/plugin/plugin_http_module.dart 与
//  lib/request/apis/plugin_catalog_api.dart 的解析结果类型。
//

import Foundation

/// 规则商店列表项。
struct PluginHTTPItem: Hashable, Sendable, Identifiable {
    var name: String
    var version: String
    var useNativePlayer: Bool
    var author: String
    var lastUpdate: Int
    var antiCrawlerEnabled: Bool

    var id: String { pluginNameKey(name) }

    init(
        name: String,
        version: String,
        useNativePlayer: Bool,
        author: String,
        lastUpdate: Int,
        antiCrawlerEnabled: Bool = false
    ) {
        self.name = name
        self.version = version
        self.useNativePlayer = useNativePlayer
        self.author = author
        self.lastUpdate = lastUpdate
        self.antiCrawlerEnabled = antiCrawlerEnabled
    }

    init(json: [String: JSONValue]) throws {
        guard let name = json["name"]?.stringValue,
              let version = json["version"]?.stringValue,
              let useNativePlayer = json["useNativePlayer"]?.boolValue,
              let author = json["author"]?.stringValue else {
            throw CatalogError.invalidItem
        }
        // antiCrawlerConfig 优先：它比旧字段 antiCrawlerEnabled 更可信。
        let antiCrawlerEnabled: Bool
        if let config = json["antiCrawlerConfig"]?.objectValue {
            antiCrawlerEnabled = config["enabled"]?.boolValue ?? false
        } else {
            antiCrawlerEnabled = json["antiCrawlerEnabled"]?.boolValue ?? false
        }
        self.init(
            name: name,
            version: version,
            useNativePlayer: useNativePlayer,
            author: author,
            lastUpdate: json["lastUpdate"]?.intValue ?? 0,
            antiCrawlerEnabled: antiCrawlerEnabled
        )
    }
}

extension PluginHTTPItem {
    /// 规则仓库里的更新时间。引导页的规则行和规则仓库那屏共用这一份写法，
    /// 免得两处各写一套、以后改一处另一处跟着飘。
    /// 用手机自己的日期格式（LP 6109），今年的不印年份（LP 6113）。
    var updatedDateText: String? {
        guard let updateDate else { return nil }
        let isThisYear = Calendar.current.component(.year, from: updateDate)
            == Calendar.current.component(.year, from: Date())
        return SystemDateText.date(updateDate, includeYear: !isThisYear)
    }

    private var updateDate: Date? {
        guard lastUpdate > 0 else { return nil }
        // 仓库里的 lastUpdate 是毫秒，按量级先换算成秒。
        var seconds = lastUpdate
        if seconds > 100_000_000_000 { seconds /= 1000 }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

struct PluginCatalogParseResult: Sendable {
    var items: [PluginHTTPItem]
    var skippedItems: Int
}

enum CatalogError: Error, LocalizedError, Sendable {
    case rootMustBeArray
    case invalidItem
    case noValidItems

    var errorDescription: String? {
        switch self {
        case .rootMustBeArray: "Rule catalog root must be a JSON array"
        case .invalidItem: "Invalid rule catalog item"
        case .noValidItems: "Rule catalog contains no valid items"
        }
    }
}

enum PluginCatalogParser {
    /// 对应 PluginCatalogApi.parsePluginList：逐条容错，若一条都没解析成功则报错。
    static func parse(_ raw: String) throws -> PluginCatalogParseResult {
        let root = try JSONValue.decode(raw)
        guard let list = root.arrayValue else { throw CatalogError.rootMustBeArray }
        var items: [PluginHTTPItem] = []
        var skipped = 0
        for value in list {
            guard let object = value.objectValue else {
                skipped += 1
                continue
            }
            do {
                items.append(try PluginHTTPItem(json: object))
            } catch {
                skipped += 1
            }
        }
        if !list.isEmpty && items.isEmpty {
            throw CatalogError.noValidItems
        }
        return PluginCatalogParseResult(items: items, skippedItems: skipped)
    }
}
