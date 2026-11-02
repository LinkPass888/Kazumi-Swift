//  Kazumi
//
//  解复用缓存大小（对齐 main 的 `lib/services/player/playback_cache_policy.dart`）。
//
//  main 的规则：常规 1500 MiB，进低内存模式就降到 2 MiB。低内存模式三档
//  （自动 / 始终开启 / 始终关闭），「自动」只在按流量计费的网络下开、Wi-Fi 下关，
//  本地文件永远不算（LP 5547：照 main 搬）。
//
//  之前我们一个缓存参数都没设，跑的是内核默认值，比这个小数倍。慢速源上缓存
//  很快被抽空，表现就是「一会儿停一下」（LP 5536 日志里「暂停=否 空闲=是」）。
//

import Foundation
import Network

/// 低内存模式（main 的 `LowMemoryMode`）。
///
/// 存的是字符串而不是布尔：main 那边老的 `lowMemoryMode` 是 Bool，后来改成三档，
/// 用 `lowMemoryPolicy` 存字符串；这里直接沿用同一个键与同一套取值，
/// 老用户的设置能被认出来。
enum LowMemoryMode: String, CaseIterable, Identifiable {
    case auto
    case always
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "跟随网络")
        case .always: String(localized: "始终开启")
        case .never: String(localized: "始终关闭")
        }
    }

    var detail: String {
        switch self {
        case .auto: String(localized: "移动数据自动开启，Wi-Fi 自动关闭")
        case .always: String(localized: "所有网络均减少缓存，降低内存占用")
        case .never: String(localized: "使用完整缓存，移动数据下也不自动开启")
        }
    }

    /// 设置页那一行右侧的状态话术（main 的 `statusDescription`）。
    func status(isMetered: Bool) -> String {
        switch self {
        case .auto:
            isMetered ? String(localized: "已自动开启 · 移动数据下减少缓存") : String(localized: "已自动关闭 · 非移动网络使用完整缓存")
        case .always:
            String(localized: "已手动开启 · 所有网络均减少缓存")
        case .never:
            isMetered ? String(localized: "已手动关闭 · 移动数据使用完整缓存") : String(localized: "已手动关闭 · 使用完整缓存")
        }
    }

    /// 这一档在当前网络下到底开不开（main 的 `isEnabled`）。
    func isEnabled(isMetered: Bool, isLocalPlayback: Bool) -> Bool {
        switch self {
        case .auto: isMetered && !isLocalPlayback
        case .always: true
        case .never: false
        }
    }
}

/// 当前网络是不是按流量计费（移动数据、个人热点这类）。
///
/// `NWPathMonitor` 的 `isExpensive` 就是这个意思；`isConstrained`（低数据模式）
/// 也算进来——用户在那儿明确要求省流量，缓存就该跟着小。
@MainActor
final class MeteredNetworkMonitor {
    static let shared = MeteredNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "kazumi.metered-network")
    private(set) var isMetered = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.isMetered != metered else { return }
                self.isMetered = metered
                self.onChange?()
            }
        }
        monitor.start(queue: queue)
    }

    /// 网络性质变了（Wi-Fi ↔ 移动数据）时叫一声，播放中好立刻换缓存大小。
    var onChange: (() -> Void)?
}

/// 按当前档位与网络算出解复用缓存该给多少字节。
enum PlaybackCachePolicy {
    /// main 的 `_defaultBufferSize`。
    static let fullBytes = 1500 * 1024 * 1024
    /// main 的 `_lowMemoryBufferSize`。
    static let lowMemoryBytes = 2 * 1024 * 1024

    /// 本地文件不受流量限制，低内存模式对它们没意义（与 main 的 `isLocalPlayback` 一致）。
    static func bytes(mode: LowMemoryMode, isMetered: Bool, isLocalPlayback: Bool) -> Int {
        mode.isEnabled(isMetered: isMetered, isLocalPlayback: isLocalPlayback)
            ? lowMemoryBytes
            : fullBytes
    }
}
