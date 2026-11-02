//
//  CommentRowView.swift
//  Kazumi
//
//  一条吐槽（评论）：头像 + 昵称 + 正文，正文里带的图一张一行竖着排。
//
//  回复跟主楼同款（也画头像），左边缘对齐主楼正文，就靠缩进表示从属于哪条 ——
//  不画竖线、不做卡片、不画分隔线（Colo 3366）。
//  回复默认全不显示，只留一行主题色的「展开显示 N 个回复」；展开后回复全出来，
//  那行换成底下灰色的「收起」。
//  昵称用 App 自己的主题色 —— 工程里没有 AccentColor 资源，Color.accentColor 会掉回系统蓝。
//  被删掉的评论正文是空的：不显示成一片空白，改显示「该评论已被删除」（Colo 3356）。
//

import SwiftUI

struct CommentRowView: View {
    let comment: BangumiCommentItem

    /// 详情页那版多一行日期，播放页不显示。
    var showsDate = false
    /// 评分：1…10，画成五颗星（每颗 2 分，奇数分半颗）。0 或 nil 不画。
    var score: Int?

    /// 展开回复时喊外面一声：这条在屏幕下半部的话，往下展开会跑出屏幕外，
    /// 外面把列表滚一滚（Colo 3366）。
    var onExpand: (() -> Void)?

    /// 回复默认收着。
    @State private var expanded = false

    /// 星星跟昵称一起随动态字体缩放（Colo 6165）：昵称是 footnote，调大时昵称会长。
    @ScaledMetric(relativeTo: .footnote) private var starSize: CGFloat = 13

    private let avatarSize: CGFloat = 32
    private let gap: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                header
                content
                if !comment.replies.isEmpty { replies }
            }
            // 铺满并靠左：不铺满的话整行（连头像）只到内容那么宽，
            // 外层一居中就被摆到屏幕中间（LP 3389 / Colo 3390）。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 主楼

    private var avatar: some View {
        KazumiAvatar(url: comment.userAvatar, size: avatarSize, focus: 0.2)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(comment.userName.isEmpty ? "匿名用户" : comment.userName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .lineLimit(1)
            if let score, score > 0 {
                ratingStars(score)
            }
            if showsDate {
                Spacer(minLength: 0)
                Text(Self.dateText(comment.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 五颗星，每颗 2 分，奇数分半颗（Colo 6158）。固定 59 宽，右边日期才不跟着分数跳。
    private func ratingStars(_ score: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0 ..< 5, id: \.self) { index in
                let filled = score - index * 2
                Image(systemName: filled >= 2 ? "star.fill" : (filled == 1 ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: starSize, weight: .semibold))
                    .foregroundStyle(filled > 0
                                     ? AnyShapeStyle(KazumiPalette.accent(for: colorScheme))
                                     : AnyShapeStyle(Color.secondary.opacity(0.35)))
            }
        }
        .frame(width: starSize * 5 + 4, alignment: .leading)
        // 五颗合成一句，不让 VoiceOver 逐颗念。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(score) 分，满分 10 分")
    }

    @ViewBuilder
    private var content: some View {
        if comment.isDeleted {
            Text("该评论已被删除")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // 正文可能带图（`[img]…[/img]`）：文字照排，图另起一块（Colo 3299）。
            CommentBodyView(text: comment.comment)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 回复

    private var replies: some View {
        VStack(alignment: .leading, spacing: 10) {
            if expanded {
                ForEach(comment.replies) { reply in
                    replyRow(reply)
                }
                Button {
                    expanded = false
                } label: {
                    Text("收起")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    expanded = true
                    onExpand?()
                } label: {
                    Text("展开显示 \(comment.replies.count) 个回复")
                        .font(.caption)
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func replyRow(_ reply: BangumiCommentReply) -> some View {
        HStack(alignment: .top, spacing: gap) {
            KazumiAvatar(url: reply.userAvatar, size: avatarSize, focus: 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.userName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    .lineLimit(1)
                if reply.isDeleted {
                    Text("该评论已被删除")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    CommentBodyView(text: reply.content)
                }
            }
        }
    }

    /// 吐槽时间是 Unix 秒。
    private static func dateText(_ epoch: Int) -> String {
        guard epoch > 0 else { return "" }
        return SystemDateText.date(
            Date(timeIntervalSince1970: TimeInterval(epoch)),
            includeYear: true
        )
    }

    @Environment(\.colorScheme) private var colorScheme
}
