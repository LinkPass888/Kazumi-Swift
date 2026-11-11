# macOS 版

真正的 macOS target，**不是**「Designed for iPad」，也**不是** Mac Catalyst。

- 「Designed for iPad」已废弃：iOS target 交给 macOS SDK 编，UIKit 模块直接解析不了。
- Catalyst 不走：它把整套 UIKit 搬到 Mac 上，侧边栏、窗口、菜单栏这些 macOS 该有的东西
  全得另做，最后得到的是一个「能开两个窗口的 iPad App」；而 MPVKit 的二进制也没有
  Catalyst 切片。

## 目录

```
macos/
  project.yml                 XcodeGen 工程描述（唯一工程事实标准，别手改 .xcodeproj）
  Runner/
    KazumiMacApp.swift        @main：窗口 + Settings 场景
    MacRootView.swift         侧边栏（NavigationSplitView）与各栏占位说明
    Kazumi.entitlements       沙箱、出站网络、用户选择的文件读写
    Info.plist                xcodegen 生成，内容全在 project.yml 的 info.properties
```

共用源码不复制：`ios/Runner/NativeApp` 下的文件按层往 `project.yml` 的 `sources` 里加，
加一层 CI 编一遍。**加之前先 grep `UI[A-Z]`**——带 UIKit 的文件加进去必然编不过。

## 本地构建

```bash
brew install xcodegen
xcodegen generate --spec macos/project.yml --project macos
xcodebuild -project macos/Kazumi.xcodeproj -scheme Kazumi -configuration Debug \
  -destination "generic/platform=macOS" build
```

产物 `macos/build/.../Kazumi.app`（走 Xcode 的话在 DerivedData 里）。

## CI

`.github/workflows/macos.yaml`：`macos/**` 或那几块共用源码一改就编一次，
出不签名的 `Kazumi_macos_canary.zip`。**它只 build，不跑测试**——和 iOS 那条一样。

## 现在的进度

已经进 target 的共用源码（纯 Foundation，一行 UIKit 都没有）：

| 层 | 路径 |
| --- | --- |
| 规则模型 | `Features/Plugins/Model` |
| 规则引擎 | `Features/Plugins/Engine` |
| 规则网络层 | `Features/Plugins/Network` |
| Cookie 口袋 | `Features/Plugins/Service/PluginCookieStore.swift` |
| 日志 / 元信息 | `App/Support/KazumiLog.swift`、`KazumiAppInfo.swift` |

界面只有壳：侧边栏 + 各栏的移植说明 + 「关于」设置页。

## 移植顺序（按依赖从底往上）

1. **Design 层**：`KazumiPalette`（UIColor → NSColor 分支）、`KazumiThemeColor`、
   `KazumiWindowStyle`、`InAppBrowser`（WKWebView 的 NSViewRepresentable）、
   `KazumiSwipeBack`（macOS 无侧滑返回，整个文件 `#if os(iOS)` 掉）。
2. **App/State**：`AppEnvironment`（`UIScreen` → `NSScreen`，规则目录改到
   Application Support）、`LibraryStore`、`SettingsStore`、`AppRouter`。
3. **规则界面**：`Plugins/Views` + `Service`（`UIDocumentPicker` → `NSOpenPanel`，
   `UIPasteboard` → `NSPasteboard`，`presentationDetents` → 固定尺寸 sheet）。
4. **页面**：推荐 → 时间表 → 详情 → 搜索 → 历史 / 收藏 / 我的 → 设置。
5. **播放器**：MPVKit + MetalKit（`MTKView` 在 macOS 上照样能用），手势与 HUD 换成
   AppKit 的鼠标/键盘事件；`AVAudioSession` 在 macOS 上不存在，音量与中断处理要另写。
6. **iOS 独占功能**：画中画、投屏（AVRoutePickerView）、相册选图、后台播放、灵动岛。
   macOS 侧要么不做，要么换实现（例如选图用 `NSOpenPanel`）。

## 规模

`ios/Runner/NativeApp` 现在 196 个 Swift 文件、61,921 行，其中 **55 个文件**碰到
iOS 独占 API（UIKit / MediaPlayer / PhotosUI / AVAudioSession / `presentationDetents` 等），
141 个是纯 Foundation/SwiftUI、本身就能编到 macOS 上。移植的活儿主要就在这 55 个文件
和它们的调用方。

## 已知风险

- **MPVKit 的 macOS 切片**：`Package.swift` 声明了 `.macOS(.v12)`，但二进制是否真的带
  macOS 架构要 CI 第一轮解析 + 链接才知道。播放器能不能移植全看这个结论。
- **iOS 26 / macOS 26 那套液态玻璃**：`glassEffect`、`tabBarMinimizeBehavior` 之类是
  iOS 侧 API，macOS 有自己的一套（`NSGlassEffectView` / `.glassEffect` 在 macOS 26 上
  也有），但语义不完全一样，逐页对齐。
- **窗口与多栏**：iOS 版那套自适应多栏（§6.5）在 macOS 上要按窗口尺寸重算，不能照搬 iPad 的
  分档阈值。