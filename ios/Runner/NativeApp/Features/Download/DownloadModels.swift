//
//  DownloadModels.swift
//  Kazumi
//
//  离线缓存的数据模型（对应 lib/modules/download/download_module.dart）。
//  一份 DownloadRecord 是「一部番 + 一条线路」，里面按集数存 DownloadEpisode。
//  存到 Application Support 的一个 JSON 里，与设置备份分开（下载记录是这台设备的
//  真实文件，拷到别的机器上没有意义）。
//

import Foundation

/// 单集的下载状态。`resolving` 与 `downloading` 分开：前者是在那层隐藏网页里
/// 嗅真实视频地址，可能要好几十秒，进度条这时候不该动。
enum DownloadStatus: String, Codable, Sendable {
    case pending
    case resolving
    case downloading
    case paused
    case completed
    case failed

    /// 还在跑（用来判断要不要在启动时把状态打回暂停）。
    var isActive: Bool {
        self == .pending || self == .resolving || self == .downloading
    }

    var isFinished: Bool {
        self == .completed
    }
}

/// 一集。
struct DownloadEpisode: Codable, Identifiable, Sendable, Hashable {
    /// 集数（从 1 起）。
    var number: Int
    /// 剧集标题，下载列表里显示用；空的话显示「第 N 集」。
    var title: String
    /// 规则抓到的剧集页地址：同一集的身份主键（播放 / 下载 / 历史共用）。
    var pageURL: String
    /// 嗅出来的真实媒体地址。没解析出来时为空。
    var mediaURL: String
    var status: DownloadStatus
    /// 0…1。未知总大小时按已收到的字节估个大概（见 DownloadEngine）。
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    /// 失败原因，界面上说人话。
    var errorMessage: String?
    /// 落盘后的相对文件名（相对这条记录的目录）。
    var fileName: String?
    var directoryPath: String?
    var updatedAt: Date

    var id: Int { number }

    var displayTitle: String {
        // 有些规则根本不发集名，`episodes` 里就是那集的网页地址：
        // 直接贴出来是一串又长又没用的 URL，退回「第 N 集」（LP 5112）。
        if title.isEmpty || title.hasPrefix("http://") || title.hasPrefix("https://") {
            return "第 \(number) 集"
        }
        return title
    }

    /// 下完并且文件还在才算「可离线播」。
    ///
    /// 只看记录不够：换过目录、或者文件被清掉之后，记录还停在「下完」，
    /// 但盘上什么都没有。那时下载管理页会算它已下完（勾还在）、点进去放不了
    /// （`localURL` 查了文件，返回 nil，退回在线解析）、想重下又被这里挡住。
    /// 所以加载记录时就把文件不在的集清成「没下过」（见 `DownloadCenter.load`），
    /// 让这里重新变成真话。
    var isPlayableOffline: Bool {
        status == .completed && fileName != nil
    }

    init(
        number: Int,
        title: String = "",
        pageURL: String,
        mediaURL: String = "",
        status: DownloadStatus = .pending,
        progress: Double = 0,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        errorMessage: String? = nil,
        fileName: String? = nil,
        directoryPath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.number = number
        self.title = title
        self.pageURL = pageURL
        self.mediaURL = mediaURL
        self.status = status
        self.progress = progress
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.errorMessage = errorMessage
        self.fileName = fileName
        self.directoryPath = directoryPath
        self.updatedAt = updatedAt
    }
}

/// 一部番在一条线路下的下载记录。
struct DownloadRecord: Codable, Identifiable, Sendable {
    var bangumiID: Int
    var title: String
    var coverURL: String
    /// 规则名：换规则以后地址口径不一样，用来说明这份是从哪个源下的。
    var pluginName: String
    var road: Int
    var episodes: [DownloadEpisode]
    var createdAt: Date
    /// 这条记录在规则里的「条目身份」（搜索结果的 src / item id）。
    ///
    /// 接口模式的规则拿它当 `vod_id` 用，站点要的是数字 id，不是剧集地址
    /// （LP 5508 抓包：`get_detail?vod_id=<m3u8 地址>` → 1001 参数错误）。
    /// 旧记录没有这个字段，解码出来是空串，回放时退回老样子。
    var itemSource: String = ""

    init(
        bangumiID: Int,
        title: String,
        coverURL: String,
        pluginName: String,
        road: Int,
        episodes: [DownloadEpisode],
        createdAt: Date,
        itemSource: String = ""
    ) {
        self.bangumiID = bangumiID
        self.title = title
        self.coverURL = coverURL
        self.pluginName = pluginName
        self.road = road
        self.episodes = episodes
        self.createdAt = createdAt
        self.itemSource = itemSource
    }

    private enum CodingKeys: String, CodingKey {
        case bangumiID, title, coverURL, pluginName, road, episodes, createdAt, itemSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bangumiID = try container.decode(Int.self, forKey: .bangumiID)
        title = try container.decode(String.self, forKey: .title)
        coverURL = try container.decode(String.self, forKey: .coverURL)
        pluginName = try container.decode(String.self, forKey: .pluginName)
        road = try container.decode(Int.self, forKey: .road)
        episodes = try container.decode([DownloadEpisode].self, forKey: .episodes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        itemSource = try container.decodeIfPresent(String.self, forKey: .itemSource) ?? ""
    }

    /// 记录主键：同一部番、同一条规则、同一条线路算一份。
    var id: String { Self.key(bangumiID: bangumiID, pluginName: pluginName, road: road) }

    static func key(bangumiID: Int, pluginName: String, road: Int) -> String {
        "\(bangumiID)|\(pluginName)|\(road)"
    }

    /// 这份记录里已经下完的集数，升序。
    var completedNumbers: [Int] {
        episodes.filter(\.isPlayableOffline).map(\.number).sorted()
    }

    /// 总占用空间。只算文件还在的：记录说下完、文件却不在的集不占地方，
    /// 算进去只会让存储页显示一个永远清不掉的数。
    var totalBytes: Int64 {
        episodes.filter { $0.status == .completed && $0.fileName != nil }
            .reduce(0) { $0 + $1.totalBytes }
    }
}
