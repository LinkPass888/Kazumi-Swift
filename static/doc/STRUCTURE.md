# 仓库结构

本页供开发者查找源码、资源与构建配置。构建和提交流程见
[CONTRIBUTING.md](CONTRIBUTING.md)，安装说明见 [README.md](../../README.md)。

应用使用 **Swift 6 + SwiftUI**，不依赖 Flutter / Dart 工具链。
应用 target `Runner` 共用于 iOS / iPadOS 26+ 和 macOS 26+（Mac Catalyst，仅 Apple Silicon）；
单元测试另有 `RunnerTests` target，没有独立的 macOS 工程。
工程、依赖、资源与 Info.plist 配置以 `ios/project.yml` 为准，`ios/Runner.xcodeproj` 由 XcodeGen 生成，不入库。

## 顶层

```text
Kazumi/
├── ios/                    # 原生应用、单元测试与 XcodeGen 配置
├── assets/                 # 着色器、图片、使用约定文本
├── licenses/               # 随 App 打包的第三方许可证与署名
├── static/                 # 文档和截图，不参与构建
│   ├── doc/                # CONTRIBUTING.md、STRUCTURE.md
│   └── screenshot/         # README 引用的界面截图
├── testdata/               # kazumi-seed-rules.json：规则样例，不随 App 打包
├── .github/                # CI 工作流、Issue / PR 模板
├── .vscode/                # 共享编辑器设置，不配置 Flutter 调试器
├── CHANGELOG.md            # 按发行版排列的更新日志
├── README.md
├── LICENSE
├── .gitignore
└── .gitattributes
```

## 应用工程与测试

```text
ios/
├── project.yml             # target、scheme、构建设置、SPM 依赖及 Info.plist 配置
├── .gitignore              # 忽略生成工程、Xcode 本机状态与依赖缓存
├── Runner/
│   ├── Info.plist          # 由 project.yml 的 info.properties 生成
│   ├── Localizable.xcstrings   # 简体中文 / 繁体中文字符串目录
│   ├── Assets.xcassets     # App 图标、启动页图片等资源
│   ├── Base.lproj/         # LaunchScreen.storyboard
│   └── NativeApp/          # Swift 应用源码，见下一节
└── RunnerTests/            # Swift Testing 测试源码
    └── Fixtures/           # 测试资源，单独作为 folder reference 打包
```

`Runner` scheme 的测试动作包含 `RunnerTests`。当前 CI 只构建、打包应用，
**不运行测试，也不编译测试 bundle**；旧的 `MPVRendererTests.swift` 被 `project.yml` 显式排除。

Mac Catalyst 使用同一套 UIKit / SwiftUI 界面与 mpv 内核，没有 `macos/` 目录。
需要区分 iOS 与 Catalyst 的 API 时使用 `#if targetEnvironment(macCatalyst)`；
不能单靠 `#if os(iOS)` 区分，因为 Catalyst 也满足该条件。

## Swift 源码分层

```text
ios/Runner/NativeApp/
├── App/                    # 入口、Tab 外壳、全局状态与启动流程
│   ├── Onboarding/         # 首次引导与使用约定
│   ├── State/              # AppEnvironment、SettingsStore、LibraryStore、AppRouter
│   └── Support/            # 元信息、日志、存储路径、网络策略等
├── Design/                 # 配色、玻璃材质、布局、通用控件与动效
└── Features/
    ├── Bangumi/            # Bangumi / AniList 元数据、模型与卡片
    ├── Collect/            # 收藏列表与收藏状态
    ├── Danmaku/            # 弹幕屏蔽设置
    ├── Download/           # 离线下载与下载目录访问
    ├── History/            # 观看历史
    ├── Info/               # 番剧详情、评论、播放源选择
    ├── Player/             # 播放器、mpv、弹幕、画中画、AniSkip、截图
    │   ├── Cast/           # DLNA 投屏
    │   └── Views/          # 播放器内的评论等子视图
    ├── Plugins/            # 规则系统
    │   ├── Model/          # 规则、JSON 树、错误及结果模型
    │   ├── Engine/         # XPath / API 规则执行策略
    │   ├── Network/        # HTTP 请求与规则仓库接口
    │   ├── Service/        # 安装、导入导出、搜索、Cookie 与仓库管理
    │   └── Views/          # 规则列表、商店、编辑器及测试页面
    ├── Popular/            # 推荐
    ├── Profile/            # 「我的」
    ├── Search/             # 关键词搜索与以图搜番
    ├── Settings/           # 设置、账号、备份、WebDAV、日志与关于
    ├── Timeline/           # 时间表
    └── WebView/            # 视频源嗅探与验证码处理
```

`project.yml` 自动收录 `Runner/NativeApp` 与 `RunnerTests` 内的源码（测试排除项除外）。
新增文件放进相应功能目录即可；新增外部源码路径、资源或依赖时再修改 `project.yml`，不要直接改生成的 xcodeproj。

## 打包资源与依赖

| 路径 | 用途 |
| --- | --- |
| `assets/shaders/` | Anime4K GLSL 着色器 |
| `assets/images/` | 界面图片与 Logo |
| `assets/statements/` | 使用约定正文，由首次引导读取 |
| `licenses/` | 第三方许可证文本，由 `ThirdPartyLicensesScreen` 枚举展示 |

这些目录在 `Runner.sources` 中以 `type: folder`、`buildPhase: resources` 引入，保留目录结构。
`Localizable.xcstrings`、`Assets.xcassets` 与 `Base.lproj` 也分别进入资源构建阶段。
SPM 依赖在 `project.yml` 的 `packages` 中声明：**Fuzi** 用于 XHTML / XPath，**MPVKit** 提供播放器内核。

## CI 与发布

```text
.github/workflows/
├── pr.yaml                 # PR / 手动构建：build-ios、build-catalyst
└── release.yaml            # tag 发布流程（也支持手动触发）：build-ios、build-catalyst、release
```

两个平台都使用 `ios/project.yml` 生成同一个工程；CI 使用 `xcode-27` runner。
iOS 产物为 `Kazumi_ios_*_no_sign.ipa`，Mac Catalyst 产物为 `Kazumi_catalyst_*_no_sign.dmg`，Mac 构建限定 `arm64`。
PR 自动构建会忽略只改 `static/**`、`**.md`、`.gitignore` 或 Issue 模板的变更；手动构建和 tag 发布不受该路径过滤限制。

## 保留的上游溯源与兼容层

源码里的 `lib/...dart` 路径指向上游 Flutter 版实现，是行为对照用的**溯源注释**，不是本仓库的源码入口。
以下内容也不是待删除的 Flutter 工程依赖：

- `HiveBox.swift`、`WebDAVLegacy.swift`：读写旧版云盘数据所需的格式兼容。
- `SettingsBackup.swift` 及设置存储层：保留旧版键名，让 JSON 设置备份可以互相导入。
- `CaptchaWebView.swift`、`VideoSourceWebView.swift` 中的 `window.flutter_inappwebview`：复用上游脚本的 JavaScript 接口名，实际由 `WKScriptMessageHandler` 接收，不加载 Flutter SDK。
- `CHANGELOG.md` 的旧版本记录、`licenses/` 中的上游许可说明：保留历史与署名，不改写成当前实现。
