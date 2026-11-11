//
//  MacPlayerScreen.swift
//  Kazumi (macOS)
//
//  macOS 侧的播放页。内核用的是 iOS 那份共享的 MPVEngine + PlayerSurfaceModel，
//  所以缓冲判断、首帧、断流自愈、进度、截图都和手机上一个逻辑；
//  这里只有 macOS 自己的一圈交互：打开文件 / 直链、鼠标拖进度、空格暂停、全屏。
//
//  还没接的部分（等 macOS 页面按阶段移植过去）：选集、弹幕叠加、画中画、投屏。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacPlayerScreen: View {
    @State private var model = MacPlayerModel()
    @State private var isShowingURLSheet = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var inputHint: String?

    private static let speedChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var surface: PlayerSurfaceModel { model.surface }

    var body: some View {
        ZStack {
            Color.black

            MacPlayerContainer(model: model)
                .ignoresSafeArea()

            if model.title == nil {
                emptyState
            }

            if let message = surface.errorMessage {
                errorState(message)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if model.title != nil {
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
        .onDisappear { model.stop() }
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
            Text("选一个本地文件，或者贴一条直链。播放内核和手机上同一套。")
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
            VStack(spacing: 2) {
                if let title = model.title {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let note = inputHint ?? model.hint {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer(minLength: 12)
            if model.title != nil {
                Button("停止") { model.stop() }
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
                    get: { isScrubbing ? scrubPosition : surface.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(surface.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = surface.currentTime
                        isScrubbing = true
                    } else {
                        surface.seek(to: scrubPosition)
                        isScrubbing = false
                    }
                }
            )
            .tint(.white)

            HStack(spacing: 18) {
                Button { surface.skipForward(seconds: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .help("后退 10 秒")

                Button { surface.togglePlay() } label: {
                    Image(systemName: surface.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 26)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(surface.isPlaying ? "暂停（空格）" : "播放（空格）")

                Button { surface.skipForward(seconds: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .help("前进 10 秒")

                Text("\(Self.clock(displayPosition)) / \(Self.clock(surface.duration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))

                if surface.isStalled || surface.isLoadingFirstFrame {
                    ProgressView()
                        .controlSize(.small)
                }
                if surface.downloadSpeed > 1 {
                    Text(Self.speedText(surface.downloadSpeed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer(minLength: 8)

                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Slider(value: Binding(get: { model.volume }, set: { model.volume = $0 }), in: 0...100)
                    .frame(width: 110)
                    .tint(.white)

                Menu(model.speed == 1 ? "1x" : String(format: "%gx", model.speed)) {
                    ForEach(Self.speedChoices, id: \.self) { choice in
                        Button(String(format: "%gx", choice)) {
                            model.speed = choice
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 62)

                Button {
                    Task { await captureFrame() }
                } label: {
                    Image(systemName: "camera")
                }
                .help("截一张当前帧")

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
        isScrubbing ? scrubPosition : surface.currentTime
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
        inputHint = nil
        model.open(url: url)
    }

    /// 截图走共享的引擎（screenshot-raw → 临时 PNG），打开 Finder 定位到那一张。
    private func captureFrame() async {
        let (url, note) = await surface.captureFrame()
        if let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        inputHint = note
    }

    private func openURL(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            inputHint = "地址要以 http(s) 开头"
            return
        }
        inputHint = nil
        model.open(url: url)
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

    private static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
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
