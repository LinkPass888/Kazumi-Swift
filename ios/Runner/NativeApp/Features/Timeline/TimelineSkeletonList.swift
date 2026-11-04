//
//  TimelineSkeletonList.swift
//  Kazumi
//
//  时间表的占位列表（LP 5051）。
//
//  第一次装 / 缓存被清掉时，时间表拿不到任何东西可画。原来这里是一块灰底加一个
//  居中转圈，整页空着。现在画几条与真卡片同尺寸的灰块：封面一块、三条文字块，
//  卡片本身的圆角、内边距、高度都照 `BangumiTimelineCard` 那套常量来，
//  等真数据到了直接换上去，位置不会跳。
//

import SwiftUI

struct TimelineSkeletonList: View {
    /// 与 `BangumiTimelineCard` 对齐的尺寸：内边距 12、圆角 28、最小高 160。
    private static let contentPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 28
    private static let minHeight: CGFloat = 160
    private static let coverWidth: CGFloat = 92

    @Environment(\.colorScheme) private var colorScheme
    /// 灰块的呼吸：只有一条时间线，所有块一起明暗，避免各自乱闪。
    @State private var pulse = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { index in
                    card
                        // 往下越来越淡，像内容还在往上长。
                        .opacity(1 - Double(index) * 0.12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间表加载中")
        .onAppear {
            // 只做一次呼吸，不无限循环：无限动画在省电和「减弱动态效果」下都得再处理。
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 16) {
            block(width: Self.coverWidth, height: 118, radius: 18)
            VStack(alignment: .leading, spacing: 10) {
                block(width: 150, height: 17, radius: 6)
                block(width: 110, height: 12, radius: 5)
                HStack(spacing: 6) {
                    block(width: 54, height: 18, radius: 9)
                    block(width: 46, height: 18, radius: 9)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(Self.contentPadding)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .top)
        .background(
            KazumiPalette.contentCardShape(
                cornerRadius: Self.cornerRadius,
                scheme: colorScheme
            )
        )
    }

    private func block(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(KazumiPalette.secondaryText(for: colorScheme).opacity(pulse ? 0.16 : 0.09))
            .frame(width: width, height: height)
    }
}
