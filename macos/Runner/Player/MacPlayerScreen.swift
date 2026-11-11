//
//  MacPlayerScreen.swift
//  Kazumi (macOS)
//
//  macOS 侧的播放页：本地文件 / 直链，内核是 MacMPVEngine（mpv + gpu-next/MoltenVK）。
//
//  这一版只有「能看」这一圈：打开、播放/暂停、±10 秒、进度、音量、倍速、全屏。
//  弹幕叠加、选集、断流自愈、画中画这些等 macOS 页面移植到对应阶段再接——
//  它们都长在 iOS 那套 PlayerScreen（5400 行）里，硬搬过来只会把 UIKit 一起搬进来。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacPlayerScreen: View {
    @State private var engine = MacMPVEngine()
    @State private var isShowingURLSheet = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var hint: String?

    private static let speedChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ZStack {
            Color.black

            MacVideoSurface { layer in engine.attach(layer) }
                .ignoresSafeArea()

            if engine.currentTitle == nil {
                emptyState
            }

            if let message = engine.state.message {
                errorState(message)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if engine.currentTitle != nil {
                    controlBar
                }
            }
            .padding(16)
        }
        .navigationTitle("播放器")
        .sheet(isPresented: $isShowingURLSheet) {
            MacPlayerURLSheet { text in
                openURL(text)
            }
        }
        .onDisappear { engine.stop() }
    }

    // MARK: - 空状态 / 报错

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text("还没有打开视频")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("拖入本地文件、选一个文件，或者贴一条直链。")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 12) {
                Button("打开文件…") { openFile() }
                    .buttonStyle(.borderedProminent)
                Button("打开链接…") { isShowingURLSheet = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这一段没播起来", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 10) {
                Button("打开文件…") { openFile() }
                Button("打开链接…") { isShowingURLSheet = true }
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("打开文件…") { openFile() }
            Button("打开链接…") { isShowingURLSheet = true }
            Spacer(minLength: 12)
            if let title = engine.currentTitle {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 12)
            if engine.currentTitle != nil {
                Button("停止") {
                    engine.stop()
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(.white.opacity(0.18))
        .foregroundStyle(.white)
    }

    // MARK: - 控制条

    private var controlBar: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : engine.state.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(engine.state.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = engine.state.position
                        isScrubbing = true
                    } else {
                        engine.seek(to: scrubPosition)
                        isScrubbing = false
                    }
                }
            )
            .tint(.white)

            HStack(spacing: 18) {
                Button { engine.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .help("后退 10 秒")

                Button { engine.togglePause() } label: {
                    Image(systemName: engine.state.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 26)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(engine.state.isPaused ? "播放（空格）" : "暂停（空格）")

                Button { engine.skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .help("前进 10 秒")

                Text("\(Self.clock(displayPosition)) / \(Self.clock(engine.state.duration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))

                if engine.state.isBuffering && !engine.state.isPaused {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Slider(value: Binding(get: { engine.volume }, set: { engine.volume = $0 }), in: 0...100)
                    .frame(width: 110)
                    .tint(.white)

                Menu(engine.speed == 1 ? "1x" : String(format: "%gx", engine.speed)) {
                    ForEach(Self.speedChoices, id: \.self) { speed in
                        Button(String(format: "%gx", speed)) {
                            engine.speed = speed
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 62)

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("全屏")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(14)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var displayPosition: Double {
        isScrubbing ? scrubPosition : engine.state.position
    }

    // MARK: - 打开

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .audio]
        panel.message = "选一个本地视频文件"
        panel.prompt = "播放"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        hint = nil
        engine.play(MacPlaybackRequest(url: url))
    }

    private func openURL(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            hint = "地址要以 http(s) 开头"
            return
        }
        hint = nil
        engine.play(MacPlaybackRequest(url: url))
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// 打开直链的小表单。
private struct MacPlayerURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onPlay: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开链接")
                .font(.headline)
            TextField("https://example.com/video.m3u8", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("播放") {
                    onPlay(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}