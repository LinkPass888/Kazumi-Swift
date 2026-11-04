//
//  ImageSearchModels.swift
//  Kazumi
//
//  1:1 翻译 lib/modules/search/image_search_module.dart：
//  trace.moe 的响应结构（frameCount / error / result）与 anilist 元数据。
//  解析规则与 Dart 版逐条对齐：
//  * episode 可能是 num、List<num> 或 null，非数字一律视为空；
//  * 数值字段既接受整数也接受浮点（JSON 里 1 与 1.0 都可能出现）。
//

import Foundation

/// 对应 ImageSearchItem。
struct ImageSearchItem: Sendable {
    let frameCount: Int?
    let error: String?
    let result: [TraceResultItem]?

    static nonisolated func fromJSON(_ json: JSONValue) -> ImageSearchItem {
        ImageSearchItem(
            frameCount: json["frameCount"].intValue,
            error: json["error"].stringValue,
            result: json["result"].arrayValue?.map(TraceResultItem.fromJSON)
        )
    }
}

/// 对应 ResultItem：一帧匹配画面。
struct TraceResultItem: Identifiable, Sendable {
    /// 结果没有稳定 id（同一番剧可能命中多帧），用「文件名 + 时间点」拼一个。
    let id: String
    let anilist: AnilistInfo?
    let filename: String?
    /// 对应 Dart 的 `dynamic episode`：单集号是数字，合集可能是多个数字。
    let episode: [Double]
    let from: Double?
    let at: Double?
    let to: Double?
    let duration: Double?
    let similarity: Double?
    let video: String?
    let image: String?

    static nonisolated func fromJSON(_ json: JSONValue) -> TraceResultItem {
        let episodes: [Double]
        switch json["episode"] {
        case .array(let values):
            episodes = values.compactMap(\.doubleValue).filter(\.isFinite)
        case .int(let value):
            episodes = [Double(value)]
        case .double(let value):
            episodes = value.isFinite ? [value] : []
        default:
            episodes = []
        }
        let filename = json["filename"].stringValue
        let from = json["from"].doubleValue
        let at = json["at"].doubleValue
        return TraceResultItem(
            id: "\(filename ?? "")#\(from ?? at ?? -1)",
            anilist: json["anilist"].isNull ? nil : AnilistInfo.fromJSON(json["anilist"]),
            filename: filename,
            episode: episodes,
            from: from,
            at: at,
            to: json["to"].doubleValue,
            duration: json["duration"].doubleValue,
            similarity: json["similarity"].doubleValue,
            video: json["video"].stringValue,
            image: json["image"].stringValue
        )
    }

    /// 番剧标题：与原版一致，优先中文名，其次原名 / 罗马音 / 英文 / 文件名。
    var displayTitle: String {
        let title = anilist?.title
        for value in [title?.chinese, title?.native, title?.romaji, title?.english, filename] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(localized: "未知番剧")
    }

    /// 集数文案：对应 _episode(episode)。
    var episodeText: String {
        guard !episode.isEmpty else { return String(localized: "集数未知") }
        let numbers = episode.map { value -> String in
            value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
        }
        // 带序号的集数用「话」，与播放器、历史页一致（不带序号的指代才用「集」）。
        let numberList = numbers.joined(separator: " / ")
        return String(localized: "第 \(numberList) 集")
    }

    /// 相似度文案：对应 _similarity(result)。
    var similarityText: String {
        guard let similarity, similarity.isFinite else { return "未知" }
        return String(format: "%.1f%%", min(max(similarity, 0), 1) * 100)
    }

    /// 相似度偏低（原版阈值 0.87），需要提示用户对照画面。
    var isLowSimilarity: Bool {
        guard let similarity, similarity.isFinite else { return true }
        return similarity < 0.87
    }

    /// 时间区间文案：对应 _timeRange(result)，无 from 时回退到 at。
    var timeRangeText: String {
        func time(_ value: Double) -> String {
            let seconds = Int(value.rounded(.down))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        let start = from ?? at
        let end = to
        guard let start, start.isFinite, start >= 0 else { return String(localized: "时间未知") }
        guard let end, end.isFinite, end >= start else { return time(start) }
        return "\(time(start)) – \(time(end))"
    }

    /// 「预览片段」按钮的目标地址。
    var previewURL: URL? {
        guard let video else { return nil }
        return ImageSearchURL.httpURL(from: video)
    }

    /// 匹配画面缩略图。
    var frameURL: URL? {
        guard let image else { return nil }
        return ImageSearchURL.httpURL(from: image)
    }
}

/// 对应 Anilist，只保留界面展示所需字段。
struct AnilistInfo: Sendable {
    let id: Int?
    let idMal: Int?
    let title: AnilistTitleInfo?
    let format: String?
    let genres: [String]?
    let status: String?
    let seasonYear: Int?
    let episodes: Int?
    let coverImage: CoverImageInfo?
    let synonymsChinese: [String]?

    static nonisolated func fromJSON(_ json: JSONValue) -> AnilistInfo {
        AnilistInfo(
            id: json["id"].intValue,
            idMal: json["idMal"].intValue,
            title: json["title"].isNull ? nil : AnilistTitleInfo.fromJSON(json["title"]),
            format: json["format"].stringValue,
            genres: json["genres"].arrayValue?.compactMap(\.stringValue),
            status: json["status"].stringValue,
            seasonYear: json["seasonYear"].intValue,
            episodes: json["episodes"].intValue,
            coverImage: json["coverImage"].isNull ? nil : CoverImageInfo.fromJSON(json["coverImage"]),
            // 响应里是下划线命名，与 Dart 的 `synonyms_chinese` 一致。
            synonymsChinese: json["synonyms_chinese"].arrayValue?.compactMap(\.stringValue)
        )
    }
}

/// 对应 AnilistTitle。
struct AnilistTitleInfo: Sendable {
    let native: String?
    let romaji: String?
    let chinese: String?
    let english: String?

    static nonisolated func fromJSON(_ json: JSONValue) -> AnilistTitleInfo {
        AnilistTitleInfo(
            native: json["native"].stringValue,
            romaji: json["romaji"].stringValue,
            chinese: json["chinese"].stringValue,
            english: json["english"].stringValue
        )
    }
}

/// 对应 CoverImage。
struct CoverImageInfo: Sendable {
    let color: String?
    let large: String?
    let medium: String?
    let extraLarge: String?

    static nonisolated func fromJSON(_ json: JSONValue) -> CoverImageInfo {
        CoverImageInfo(
            color: json["color"].stringValue,
            large: json["large"].stringValue,
            medium: json["medium"].stringValue,
            extraLarge: json["extraLarge"].stringValue
        )
    }
}

enum ImageSearchURL {
    /// 对应 _parseHttpUrl：只接受 http / https 且必须有 host。
    static func httpURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}
