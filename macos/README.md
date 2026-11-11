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

没有单独的 macOS 工作流，macOS 的构建直接并进现有两条：

- `.github/workflows/pr.yaml` → 作业 `Build for macOS`，PR 一推就编，产出
  `Kazumi_macos_canary.dmg`（免签名、免公证）。
- `.github/workflows/release.yaml` → 作业 `Release for macOS`，打 tag 时和 iOS 一起出包，
  产出 `Kazumi_macos_<tag>_no_sign.dmg` 挂到同一个 Release。

dmg 用 `hdiutil create -srcfolder <Kazumi.app + Applications 软链> -format UDZO` 生成，
是标准的拖拽安装盘；不签名所以首次打开要右键「打开」或 `xattr -dr com.apple.quarantine`。

包体现在 36 MB 上下：播放内核 MPVKit 真的被符号引用了（之前只有壳的时候是 1.4 MB，
链接期整个被 dead-strip）。

两条都**只 build，不跑测试**——和 iOS 那条一样。

## 现在的进度

已经进 target 的共用源码（纯 Foundation，一行 UIKit 都没有）：

| 层 | 路径 |
| --- | --- |
| 规则模型 | `Features/Plugins/Model` |
| 规则引擎 | `Features/Plugins/Engine` |
| 规则网络层 | `Features/Plugins/Network` |
| 规则控制器 | `Features/Plugins/Service/PluginsController.swift`（读盘 / 安装 / 删除 / 目录刷新） |
| Cookie 口袋 | `Features/Plugins/Service/PluginCookieStore.swift` |
| 存储目录 | `App/Support/AppStoragePaths.swift`（从 `AppEnvironment` 拆出来的纯路径段，两边共用） |
| 日志 / 元信息 | `App/Support/KazumiLog.swift`、`KazumiAppInfo.swift` |

界面：

- **规则**（`Runner/Rules/`）：本机装了哪些规则；从规则仓库装新的、更新、删除都走共用的
  `PluginsController`，落盘路径与 iOS 同一条（Application Support/Kazumi/rules/v2/plugins.json）。
- **搜索**（`Runner/Search/`）：拿本机全部规则并发搜一次，结果按规则分组。没复制 iOS 的
  `PluginSearchService`——那个类带着验证码 WebView 流程；这里用 generation 丢掉过期结果。
- **详情**（`Runner/Detail/`）：规则引擎拉章节，按线路列剧集；点一集把地址连同规则的
  UA / referer / 登录 cookie 递给播放器。只有直链线路能直接播——网页地址要在
  `VideoSourceWebView` 里捞 m3u8/mp4，那条路还没移植。
- **播放器**（`Runner/Player/`）：本地文件、直链，以及上面那条「搜索 → 剧集 → 播」的路。
- 推荐 / 时间表 / 历史 / 收藏 / 我的仍是占位说明。

播放器**没有另写一份内核**：`ios/Runner/NativeApp/Features/Player` 下的
`MPVEngine.swift`、`MPVMetalView.swift`、`PlayerSurfaceModel.swift` 等直接进 macOS target，
两边共用。内核里 iOS 独占的只有 4 处（`UIWindowScene`、画中画探测、`UIImage` 截图 PNG、
`setNeedsLayout`），都按 `os(iOS)` / `os(macOS)` 分开了；`MPVMetalView` 同一个文件里
是 UIView 与 NSView 两套宿主。macOS 因此直接继承缓冲判断、断流原位重连、首帧、
进度与截图逻辑，只补了自己缺的：内核音量（这边没有 `AVAudioSession`）、输入。

输入按「触屏 + 鼠标键盘」两套给：单击唤出/收起控制条、双击播放暂停、横拖找进度、
竖拖调音量、播放中 4 秒自动收起；同时保留按钮、空格暂停、全屏这些鼠标/键盘路子
（macOS 26 起带触屏的机器把触摸事件送进 SwiftUI 的 gesture，两边同一套代码）。

还没接：播放器里的选集面板（详情页有线路/剧集列表，播放器内没有）、弹幕叠加、
画中画、投屏、WebView 抓地址。

## 移植顺序（按依赖从底往上）

1. **Design 层**：`KazumiPalette`（UIColor → NSColor 分支）、`KazumiThemeColor`、
   `KazumiWindowStyle`、`InAppBrowser`（WKWebView 的 NSViewRepresentable）、
   `KazumiSwipeBack`（macOS 无侧滑返回，整个文件 `#if os(iOS)` 掉）。
2. **App/State**：`AppEnvironment`（`UIScreen` → `NSScreen`，规则目录改到
   Application Support）、`LibraryStore`、`SettingsStore`、`AppRouter`。
3. **规则界面**：`Plugins/Views` + `Service`（`UIDocumentPicker` → `NSOpenPanel`，
   `UIPasteboard` → `NSPasteboard`，`presentationDetents` → 固定尺寸 sheet）。
   已完成的部分：规则列表 / 仓库安装 / 删除（`Runner/Rules/`）；规则编辑器与导入导出没搬。
4. **页面**：推荐 → 时间表 → 详情 → 搜索 → 历史 / 收藏 / 我的 → 设置。
5. **播放器**（已共享内核）：ios 那份 `MPVEngine` / `PlayerSurfaceModel` 就是 macOS 的
   内核，不再有平行实现。剩下没搬的是长在 iOS 界面里的东西：选集面板、弹幕叠层
   （`DanmakuOverlayView` 是 UIKit 画的）、画中画、投屏。音频走 coreaudio，
   `AVAudioSession` 那套不需要。
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