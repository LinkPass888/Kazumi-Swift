//
//  BangumiInfoModels.swift
//  Kazumi
//
//  详情页分标签用的数据模型，逐条对照 Dart 侧实现：
//    * 关联条目 —— lib/modules/bangumi/bangumi_relation.dart 的 BangumiRelation；
//    * 角色     —— lib/modules/characters/character_item.dart 的 CharacterItem；
//    * 声优     —— lib/modules/characters/actor_item.dart 的 ActorItem；
//    * 制作人员 —— lib/modules/staff/staff_response.dart 的 StaffResponse；
//    * 吐槽     —— lib/modules/comments/comment_item.dart 的 CommentItem。
//

import Foundation

/// 关联条目（对应 BangumiRelation）。
struct BangumiRelationItem: Identifiable, Hashable, Sendable {
    var id: Int { item.id }
    /// 关系名：前传 / 续集 / 角色 / 音乐 等。
    var relation: String
    var item: BangumiItem

    static func fromJSON(_ json: JSONValue) -> BangumiRelationItem? {
        // 对应 bangumi_relation.dart：id 缺失直接丢弃这一条。
        guard json["id"].intValue != nil else { return nil }
        return BangumiRelationItem(
            relation: json["relation"].stringValue ?? "",
            item: BangumiItem.fromJSON(json)
        )
    }
}

/// 声优（对应 ActorItem）。
struct BangumiActorItem: Identifiable, Hashable, Sendable {
    var id: Int
    var type: Int
    var name: String
    var images: [String: String]

    var largeImage: String {
        images["large"] ?? images["medium"] ?? images["small"] ?? ""
    }

    static func fromJSON(_ json: JSONValue) -> BangumiActorItem {
        BangumiActorItem(
            id: json["id"].intValue ?? 0,
            type: json["type"].intValue ?? 0,
            name: json["name"].stringValue ?? "",
            images: BangumiInfoModels.parseImages(json["images"])
        )
    }
}

/// 角色（对应 CharacterItem）。
struct BangumiCharacterItem: Identifiable, Hashable, Sendable {
    var id: Int
    var type: Int
    var name: String
    /// 角色定位：主角 / 女主 / 配角 等。
    var relation: String
    var images: [String: String]
    var actors: [BangumiActorItem]

    var largeImage: String {
        images["large"] ?? images["medium"] ?? images["small"] ?? ""
    }

    /// 声优名字拼成一行。
    var actorNames: String {
        actors.map(\.name).filter { !$0.isEmpty }.joined(separator: " / ")
    }

    static func fromJSON(_ json: JSONValue) -> BangumiCharacterItem {
        BangumiCharacterItem(
            id: json["id"].intValue ?? 0,
            type: json["type"].intValue ?? 0,
            name: json["name"].stringValue ?? "",
            relation: json["relation"].stringValue ?? "未知",
            images: BangumiInfoModels.parseImages(json["images"]),
            actors: (json["actors"].arrayValue ?? []).map(BangumiActorItem.fromJSON)
        )
    }
}

/// 制作人员（对应 StaffFullItem）。
struct BangumiStaffItem: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var nameCN: String
    /// 同一个人可能担多个职务，按优先级排好。
    var relations: [String]
    /// 头像。对应 Dart 的 Staff.images，卡片里取的是 grid 那一档。
    var images: [String: String]

    init(
        id: Int,
        name: String,
        nameCN: String,
        relations: [String],
        images: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.nameCN = nameCN
        self.relations = relations
        self.images = images
    }

    /// 头像地址：与原版 StaffCard 一致，优先 grid。
    var avatarURL: String {
        images["grid"] ?? images["medium"] ?? images["small"] ?? images["large"] ?? ""
    }

    var displayName: String {
        let translated = nameCN.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? name : translated
    }

    /// 列表里展示的主职务。
    var primaryRelation: String {
        relations.first ?? ""
    }

    /// 对应 StaffResponse.fromJson：把「人 × 职务」的扁平列表按人合并，
    /// 再按职务优先级排序（原作 / 导演 / 脚本 这类关键职务排在最前）。
    static func merge(_ list: [JSONValue]) -> [BangumiStaffItem] {
        var staffById: [Int: BangumiStaffItem] = [:]
        var relationsById: [Int: [String]] = [:]
        for entry in list {
            let id = entry["id"].intValue ?? 0
            if staffById[id] == nil {
                staffById[id] = BangumiStaffItem(
                    id: id,
                    name: entry["name"].stringValue ?? "",
                    nameCN: entry["nameCN"].stringValue ?? entry["name_cn"].stringValue ?? "",
                    relations: [],
                    images: BangumiInfoModels.parseImages(entry["images"])
                )
            }
            relationsById[id, default: []].append(entry["relation"].stringValue ?? "")
        }
        return relationsById.map { element -> BangumiStaffItem in
            let id = element.key
            let relations = element.value.sorted { priority(of: $0) < priority(of: $1) }
            var item = staffById[id] ?? BangumiStaffItem(id: id, name: "", nameCN: "", relations: [])
            item.relations = relations
            return item
        }
        .sorted { priority(of: $0.primaryRelation) < priority(of: $1.primaryRelation) }
    }

    /// 职务优先级表，与 Dart 的 _staffRelationPriority 一致。
    private static let relationPriority = [
        String(localized: "动画制作"), String(localized: "原作"), String(localized: "总导演"), String(localized: "导演"), String(localized: "系列构成"), String(localized: "脚本"), String(localized: "人物设定"),
        String(localized: "总作画监督"), String(localized: "作画监督"), String(localized: "美术监督"), String(localized: "色彩设计"), String(localized: "音乐"), String(localized: "音响监督"), String(localized: "摄影监督"),
    ]

    private static func priority(of relation: String) -> Int {
        relationPriority.firstIndex(of: relation) ?? relationPriority.count
    }
}

/// 吐槽（对应 CommentItem）。
struct BangumiCommentItem: Identifiable, Hashable, Sendable {
    /// 用户 id。
    var userID: Int
    var userName: String
    var userAvatar: String
    /// 评分 0...10。
    var rate: Int
    var comment: String
    var updatedAt: Int
    /// 对这条吐槽的回复（单集吐槽接口里在 `replies` 下）。
    var replies: [BangumiCommentReply] = []

    /// 同一位用户可能有多条吐槽，用「用户 + 更新时间」做唯一标识。
    var id: String { "\(userID)-\(updatedAt)" }

    /// 被删掉的吐槽，接口给回来的正文是空的：不显示成一片空白，
    /// 改显示「该评论已被删除」（Colo 3356）。
    var isDeleted: Bool { comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 两种形状都吃：
    /// - 整部番的吐槽（/p1/subjects/{id}/comments）：正文在 `comment`。
    /// - 单集的吐槽（/p1/episodes/{id}/comments）：正文在 `content`，没有评分，
    ///   时间是 `createdAt`。只读 `comment` 的话单集评论就只剩头像和昵称（LP 3293）。
    static func fromJSON(_ json: JSONValue) -> BangumiCommentItem {
        let user = json["user"]
        let avatar = user["avatar"]
        return BangumiCommentItem(
            userID: user["id"].intValue ?? json["creatorID"].intValue ?? 0,
            userName: user["nickname"].stringValue ?? user["username"].stringValue ?? "",
            userAvatar: avatar["large"].stringValue ?? avatar["medium"].stringValue ?? "",
            rate: json["rate"].intValue ?? 0,
            comment: json["comment"].stringValue ?? json["content"].stringValue ?? "",
            updatedAt: json["updatedAt"].intValue ?? json["createdAt"].intValue ?? 0,
            replies: (json["replies"].arrayValue ?? []).map { BangumiCommentReply.fromJSON($0) }
        )
    }
}

/// 一条吐槽下面的回复。
struct BangumiCommentReply: Identifiable, Hashable, Sendable {
    var id: Int
    var userName: String
    var content: String
    /// 回复也画头像（跟主楼同款，Colo 3344）：地址在 `user.avatar` 下，跟主楼同一个地方。
    var userAvatar: String

    /// 回复被删掉时正文同样是空的，按同一条规矩显示。
    var isDeleted: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func fromJSON(_ json: JSONValue) -> BangumiCommentReply {
        let user = json["user"]
        let avatar = user["avatar"]
        return BangumiCommentReply(
            id: json["id"].intValue ?? 0,
            userName: user["nickname"].stringValue ?? user["username"].stringValue ?? "",
            content: json["content"].stringValue ?? json["comment"].stringValue ?? "",
            userAvatar: avatar["large"].stringValue ?? avatar["medium"].stringValue ?? ""
        )
    }
}

/// 吐槽分页（对应 CommentResponse）。
struct BangumiCommentPage: Hashable, Sendable {
    var items: [BangumiCommentItem]
    var total: Int
}

/// 详情页几个模型共用的解析工具。
enum BangumiInfoModels {
    /// images 字段解析成字典，缺失时给空字典（与 Dart 的 Images.fromJson 一致）。
    static func parseImages(_ json: JSONValue) -> [String: String] {
        guard let object = json.objectValue else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            result[key] = value.stringValue ?? ""
        }
        return result
    }
}