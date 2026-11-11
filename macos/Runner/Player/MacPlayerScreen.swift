//
//  MacPlayerScreen.swift
//  Kazumi (macOS)
//
//  macOS 侧的播放页。内核用的是 iOS 那份共享的 MPVEngine + PlayerSurfaceModel，
//  所以缓冲判断、首帧、断流自愈、进度、截图都和手机上一个逻辑。
//
//  输入按「触屏 + 鼠标键盘」两套来：单击唤出/收起控制条，双击播放暂停，
//  横拖找进度、竖拖调音量；同时保留了按钮、空格暂停、全屏这些鼠标/键盘的路子
//  （macOS 26 起带触屏的机器把手势当触摸事件送进来，SwiftUI 的 gesture 两边通吃）。
//
//  还没接的部分（等 macOS 页面按阶段移植过去）：选集、弹幕叠加、画中画、投屏。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacPlayerScreen: View {
    @Environment(MacAppModel.self) private var app

    @State private var model = MacPlayerModel()
    @State private var isShowingURLSheet = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var inputHint: String?

    // 触屏/鼠标手势
    @State private var controlsVisible = true
    @State private var dragAxis: Axis?
    @State private var dragStartTime: Double = 0
    @State private var dragStartVolume: Double = 100
    @State private var dragPreviewTime: Double?
    @State private var dragPreviewVolume: Double?
    /// 原生菜单这会儿开着没：`NSMenu.popUp` 是阻塞式的，前后正好一对。
    /// 开着的时候控制条不自动收（不然菜单跟着一起没了）。
    @State private var isNativeMenuOpen = false

    private static let speedChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var surface: PlayerSurfaceModel { model.surface }

    var body: some View {
        ZStack {
            Color.black

            MacPlayerContainer(model: model)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            gestureLayer

            if model.title == nil {
                emptyState
            }

            if let message = surface.errorMessage {
                errorState(message)
            }

            if let time = dragPreviewTime {
                seekHUD(time)
            } else if let volume = dragPreviewVolume {
                volumeHUD(volume)
            }

            VStack(spacing: 0) {
                if controlsVisible || model.title == nil {
                    topBar
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if model.title != nil, controlsVisible {
                    controlBar
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
        // 从搜索/详情页递过来的那一条：视图刚出现时这一条已经在，也会在 id 变化时再来。
        .task(id: app.playRequest?.id) {
            guard let request = app.playRequest else { return }
            model.open(
                url: request.url,
                title: request.title,
                referer: request.referer,
                userAgent: request.userAgent,
                cookie: request.cookie
            )
            controlsVisible = true
            // 取走就清掉：同一栏再回来不会重复起播。
            app.playRequest = nil
        }
        // 播着的时候控制条自己收起来，鼠标/手指一动再出来。
        .task(id: hideToken) {
            guard controlsVisible, surface.isPlaying, model.title != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard controlsVisible, surface.isPlaying, dragAxis == nil, !isScrubbing,
                  !isShowingURLSheet, !isNativeMenuOpen else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
        .onDisappear { model.stop() }
    }

    private var hideToken: String {
        "\(controlsVisible)-\(surface.isPlaying)-\(model.title == nil)-\(isNativeMenuOpen)"
    }

    // MARK: - 手势层

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                surface.togglePlay()
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if dragAxis == nil {
                            dragAxis = abs(value.translation.width) >= abs(value.translation.height)
                                ? .horizontal
                                : .vertical
                            dragStartTime = surface.currentTime
                            dragStartVolume = model.volume
                        }
                        if dragAxis == .horizontal {
                            // 400 点的拖动铺满整段视频，短片子也不会手抖跳太远。
                            let span = max(surface.duration, 1)
                            let delta = Double(value.translation.width) / 400 * span
                            dragPreviewTime = min(max(0, dragStartTime + delta), max(surface.duration, 0))
                        } else if dragAxis == .vertical {
                            let next = min(max(0, dragStartVolume - Double(value.translation.height) * 0.35), 100)
                            dragPreviewVolume = next
                            model.volume = next
                        }
                    }
                    .onEnded { _ in
                        if dragAxis == .horizontal, let target = dragPreviewTime {
                            surface.seek(to: target)
                        }
                        dragAxis = nil
                        dragPreviewTime = nil
                        dragPreviewVolume = nil
                    }
            )
    }

    private func seekHUD(_ time: Double) -> some View {
        Text("\(Self.clock(time)) / \(Self.clock(surface.duration))")
            .font(.system(size: 16, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.6), in: Capsule())
            .allowsHitTesting(false)
    }

    private func volumeHUD(_ volume: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Text("\(Int(volume.rounded()))")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .allowsHitTesting(false)
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

                // 倍速走原生 NSMenu（iOS 那边是 UIButton + UIMenu）：菜单对象
                // 活在 SwiftUI 之外，250ms 的状态刷新不会把它换成旧副本。
                MacSelectionMenu(
                    model: SelectionMenuModel(
                        options: Self.speedChoices.map { choice in
                            SelectionMenuModel.Option(
                                title: String(format: "%gx", choice),
                                isSelected: abs(model.speed - choice) < 0.001
                            ) {
                                model.speed = choice
                            }
                        }
                    ),
                    title: model.speed == 1 ? "1x" : String(format: "%gx", model.speed),
                    minWidth: 52,
                    onOpenChanged: { isNativeMenuOpen = $0 }
                )
                .frame(width: 66)
                .help("倍速")

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
        controlsVisible = true
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
        controlsVisible = true
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
