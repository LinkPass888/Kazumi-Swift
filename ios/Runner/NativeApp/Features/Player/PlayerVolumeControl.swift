//
//  PlayerVolumeControl.swift
//  Kazumi
//

import SwiftUI
import MediaPlayer
import AVFoundation

/// 一次竖滑浮层要显示的内容：调的是亮度还是音量，现在到多少。
struct GestureHUDValue: Equatable {
    enum Kind { case brightness, volume }

    var kind: Kind
    var value: Double

    /// 横条左边那颗 15pt 图标，**跟着档位换**（LP 4876）：
    /// 音量 0 是静音，往上依次加一道声波；亮度低半颗小太阳、高半颗大太阳。
    var symbol: String {
        // 先夹到 0–1 再分档（Colo 4879）：拖到负数会落进最大那档。
        let level = max(0, min(1, value))
        switch kind {
        // 亮度两档，对半。
        case .brightness:
            return level <= 0.5 ? "sun.min.fill" : "sun.max.fill"
        // 音量四档，分界 1/3、2/3。
        case .volume:
            if level <= 0 { return "speaker.slash.fill" }
            if level <= 1.0 / 3.0 { return "speaker.wave.1.fill" }
            if level <= 2.0 / 3.0 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    /// 这颗符号自己的颜色（LP 4876 给的色）：音量 #00C0E8、亮度 #FFCC00，
    /// 轨道和数值仍是白的。
    var symbolColor: Color {
        switch kind {
        case .brightness: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .volume: return Color(red: 0.0, green: 0.7529, blue: 0.9098)
        }
    }
}

/// 画面这一次拖动调的是哪一路（起手时定死，中途不改）。
enum DragAxis {
    case seek
    case brightness
    case volume
    /// 贴着左边缘往右拖：这是侧滑返回，画面手势这一路什么都不做。
    case ignored
}

/// 系统音量：改音量时 iOS 自己会在屏幕边上弹那条音量浮条，所以这里只负责换算，
/// 不再画第二条（两条叠在一起是原版被吐槽的地方）。
@MainActor
final class PlayerVolumeControl {
    static let shared = PlayerVolumeControl()

    /// MPVolumeView 内部的音量滑杆；拿到之后系统音量就能直接写。
    weak var slider: UISlider?

    /// 刚由我们写下去的那一拍：这期间观察到的音量变化是回声，不是按了键。
    private(set) var isWriting = false

    var current: Double {
        if let slider = liveSlider() { return Double(slider.value) }
        return Double(AVAudioSession.sharedInstance().outputVolume)
    }

    /// 给「音量键浮层」KVO 用的滑杆：现找一个活着的，找不到就按需挂宿主（只挂一次）。
    /// 加载 / 缓冲 / 暂停时系统把音量键记在媒体音量上，会话音量不一定报变化，
    /// 这条才是那几个阶段唯一能看到按键的地方（LP 2026-11-08）。
    func sliderForKeys() -> UISlider? {
        liveSlider()
    }

    func set(_ value: Double) {
        guard let slider = liveSlider() else { return }
        let clamped = Float(min(1, max(0, value)))
        slider.value = clamped
        isWriting = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isWriting = false
        }
        // 两种事件都发：不同 iOS 版本认的不一样，只发一种常常写了不生效。
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
    }

    /// **每次都现找一个活着的滑杆**（LP 2026-10-28 实机「调过一次之后上下都滑不动」）：
    /// MPVolumeView 内部的滑杆会随着系统音量浮层、视图重建被换掉，早先缓存的
    /// 那个 weak 引用一旦是旧对象，写进去既不改音量也不报错——表现就是第一下能调、
    /// 之后两个方向都没反应。这里只认「还挂在窗口上」的那一个。
    private func liveSlider() -> UISlider? {
        if let slider, slider.window != nil { return slider }
        slider = nil
        guard let found = Self.searchSlider() else { return nil }
        slider = found
        return found
    }

    /// 在窗口里找 MPVolumeView 的滑杆；一个都没有就自己挂一个再找（**只挂一次**）。
    static func searchSlider() -> UISlider? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let view = findVolumeView(in: window), let slider = findSlider(in: view) {
                return slider
            }
        }
        // 视图树里没有：往 key window 上挂一个（1×1、几乎透明），下次就能找到。
        //
        // 只挂一次（LP 2026-11-08）：这个函数会被页面出现、手势起手、音量键观察
        // 反复调用，每失败一次就再加一个 MPVolumeView，窗口里的视图会越堆越多
        // ——那既吃内存，也会让主线程在每次布局时多走几百个子视图。
        guard !didInstallFallbackView else { return nil }
        for window in windows where window.isKeyWindow {
            didInstallFallbackView = true
            let view = MPVolumeView(frame: CGRect(x: -20, y: -20, width: 1, height: 1))
            view.alpha = 0.01
            window.addSubview(view)
            return findSlider(in: view)
        }
        return nil
    }

    /// 上面那个兜底宿主只挂一次就够，标记留在进程里。
    private static var didInstallFallbackView = false

    private static func findVolumeView(in view: UIView) -> MPVolumeView? {
        if let volume = view as? MPVolumeView { return volume }
        for child in view.subviews {
            if let found = findVolumeView(in: child) { return found }
        }
        return nil
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let found = findSlider(in: child) { return found }
        }
        return nil
    }
}

/// 把 MPVolumeView 塞进视图树（1×1、几乎全透明），只为拿到它的音量滑杆。
struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        // 滑杆不一定直接是第一层子视图，交给统一的递归查找（可能晚一两拍才装上，重试几次）。
        for delay in [0, 0.15, 0.4, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = PlayerVolumeControl.searchSlider()
            }
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
