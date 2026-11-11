# 贡献指引

欢迎您提交 Pull Request 来一起建设这个项目！

在开始之前, 请先阅读这份指引, 以保障审阅者和您之间的协作效率。

## 这个仓库是什么

Kazumi 的 iOS 原生客户端, Swift 与 SwiftUI 写的, 不做 Android / Windows / macOS, 也不是 Flutter 工程。番剧内容由「规则」决定: 每个站点一条规则, 规则可导入、分享或从规则仓库安装, 所以站点改版通常不用改代码。

## 开发环境设置

### 前置需求

- macOS 与 **Xcode 27.1**（iOS 27.1 SDK）。版本请对齐: CI 就用这一套, 用别的 Xcode 编, 顶栏模糊这类系统边缘效果会和发布出去的包不一样。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 与 [xcbeautify](https://github.com/cpisciotta/xcbeautify):

```bash
brew install xcodegen xcbeautify
```

- 最低支持 iOS 26.0, 语言版本 Swift 6。
- 真机调试需要自备 Apple ID 签名, 但编译本身不需要签名。

### 基本配置

```bash
# 克隆仓库
git clone https://github.com/LinkPass888/Kazumi-Swift.git
cd Kazumi-Swift

# 生成 Xcode 工程
xcodegen generate --spec ios/project.yml --project ios

# 用 Xcode 打开, 选自己的 Team 后跑模拟器或真机
open ios/Runner.xcodeproj
```

**工程文件是生成物**: `ios/Runner.xcodeproj` 由 `ios/project.yml` 生成, 不要直接改 xcodeproj, 下次 generate 会把您的改动覆盖掉。要加文件、加编译参数、加链接库, 改 `project.yml` 再重新生成。

命令行构建（与 CI 相同的做法, 不签名）:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

跑单元测试:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

### 自查后再推

界面、播放、下载这类改动, 请自己在模拟器或真机上跑一遍再推 PR, 确认走通了再提交。只靠读代码判断界面效果很容易漏。

## CI 何时跑

- Pull Request 打开、更新、重新打开时会跑一次 iOS 构建检查, 编不过就是红的。
- **草稿 PR 不跑**, 标成 Ready for review 之后才开始。
- **只改文档不跑**: `static/**`、`**.md`、`.gitignore` 和 issue 模板改动被排除在触发路径之外, 这类 PR 不会有构建检查, 别等着绿灯。
- 弹幕接口那对密钥是仓库 secret, 外部 fork 拿不到, 构建参数留空也能过, 不用担心要去申请。

## 代码质量

更改应当能编过、能跑起来:

- 编不过的 PR 不会合并。
- 有测试覆盖的模块（规则解析、播放器状态等）改动行为时, 请补上或更新测试。
- 有的修改不需要测试, 推送 PR 后按审查者意见处理。

## 编写规范

项目大多数功能都遵循 `抽象 -> 调用` 的实现。不同组件按职责分类存放, 互不混写:

```
ios/Runner/NativeApp/
├── App/          # 入口、Tab 外壳、全局状态、日志与支持代码
├── Design/       # 配色、排版、通用控件与动效
└── Features/     # 每块功能一个目录: Bangumi、Popular、Search、
                  # Collect、Timeline、Player、Danmaku、Download、
                  # History、Settings、Plugins、Profile、Info、WebView
ios/RunnerTests/  # 单元测试
testdata/         # 规则与解析样例数据
licenses/         # 第三方许可证文本
static/           # 文档、例图与规则说明
```

开发过程中, 您应该**慎重考虑**新增外部库、会导致包体积大量膨胀的实现和其它不安全的行为。

- 如果要引入新的外部库 - 考虑一下是否有更轻便的实现方法？项目已经带了 MPV、Fuzi 这类重组件, 再加一层要保持克制。
- 如果功能会导致包体积巨增 - 也许这个功能目前不应该实现？
- 日志用 `KazumiLog.app` / `.network` / `.player` 等分类出口, 不要用 `print`。
- 界面上的文字一律走 `ios/Runner/Localizable.xcstrings`, 新增文案要同时有简体与繁体中文。
- 如果性能表现大打折扣 - 当前功能的思路是不是需要重新考虑？

## 更改与 Commits

建议使用 [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(theme): 增加新的主题设计
fix(player): 修复横屏时选集面板错位的问题
refactor: 重构规则解析
chore: 用 KazumiLog 替换 print
docs: 更新文档 Q&A
```

**不建议您使用模糊不清的 commits**, 反之, 上述建议能够使 commits 准确简洁地说明您做出的工作, 为审查提供便利。

## 推送与 Pull Requests

### 限制

您的 PR 至少应该符合以下基本要求:

- **一个 PR 只解决一件事情**。比起把多个功能、调整和修复都堆在一个 PR 中, 把它们拆开并分别创建 PR, 分别提交是正确的选择。
- **一个 PR 更改的代码量不应太多**。1000 行甚至更多的更改是不建议的, 可以分成几个 PR 分别提交, 利于审查和修改。
- **提交 PR 时的描述部分必须由您亲自填写**。您可以利用 AI 润色措辞, 但不得让 AI 直接生成整个描述, 也不得完全依赖 AI 撰写。

### 类型

在推送 PR 时, 根据类型不同可以分为:

- Bug 修复 - 您应当打开 Issue 并确认所描述的 Bug 已修复, 然后在 PR 中引用该 Issue。
- 新功能 - 编写代码和推送前, 请确认这个新功能已经被维护者批准, 以防您的贡献因为不在计划中而拒绝合并。
- 功能重构 - 重构和新功能应当清楚分开。在重构功能时, 不要加入新功能。

### PR 标题

您的 PR 标题应该遵循 [Conventional Commits](https://www.conventionalcommits.org/) 的格式:

```
refactor: 重构 WebDAV 同步功能
feat(danmaku): 为弹幕添加了新的屏蔽方法
fix(network): fix proxy issues
```

同样, 遵循该规范能够使标题准确、简洁地说明您做出的工作。

### 推送 PR 之后

PR 会先跑一次 iOS 构建检查。如果出现了问题, 您需要进行修复。当检查通过、没有合并冲突且审查者没有其他意见时, PR 会被合并。

如果最终 PR 未被接受合并, 通常可能是因为该实现有以下问题之一:

- 这个实现的性能开销无法接受。
- 这个实现会导致安全或隐私问题。
- 这个实现过于臃肿, 可能有更好的方法。
- 这个实现只有部分设计比较好, 其它的部分有更好的方法。
- 这个实现不在计划中。
- 其它...

一般情况下都会解释为什么您的 PR 没有被接受。**这并非对您工作的否定, 只是因为您的贡献可能并不适合项目当前的情况。我们感谢您所做的付出！**

## AI 参与辅助开发

我们欢迎您使用 AI 辅助开发工作, 这可以为您带来便利。然而, 我们无法接受的是直接让 AI 生成代码, 却不加检查就直接提交, 根本没有处理 AI 产物中的冗余和问题 (Vibe Coding -> AI Slop)。这不仅严重降低审查者和您之间的协作效率, 还不利于 PR 处理。

因此, 当您使用了 AI 参与开发工作时, 您必须遵守以下规则。

### 规则

1. **如果您使用了 AI 辅助开发, 您不应该隐瞒。**
2. 您应当理解 AI 写出的每行代码, 了解 AI 做了什么。
3. 当审查者询问某处改动的原因, 您需要作出解释, 不论这是您写的还是 AI 写的。
4. 您的 PR 中不应该出现 `AI 生成 -> 修复 -> 修复 -> 修复` 多次这样的循环, 这可能显示您并没有审查 AI 生成的代码, 而是在出现问题后再让 AI 自己修复, 循环往复。

### 提交

Pull Request 模板中有关于 AI 辅助的部分。如果您使用了 AI 辅助开发, 您需要说明所使用的**确切模型**, 例如 `OpenAI GPT-5.6 Sol` 或 `Claude Fable 5`。

```
AI 辅助模型: Kimi-K3
```

某些模型在辅助开发方面的性能不足, 而这种信息能够帮助我们更好地判断代码质量。

审查 AI 生成的代码有时会比审查人类所写的代码更耗时耗力。我们制定这样的规则, 是为了维护 Pull Request 秩序, 避免被繁杂无效的纯 AI 生成产物干扰。**因此, 如果您的 Pull Request 违反了上述规则, 您的 Pull Request 可能被延后处理或直接关闭。**

## 发版（维护者）

版本号写在 `ios/project.yml` 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`, 并在 `CHANGELOG.md` 顶部加一节 `## 版本号 (日期)`。推一个与版本号同名的 tag（例如 `3.0.0`)会触发发布流程: 不签名打包、按该 tag 自动建 Release, 说明文字取 `CHANGELOG.md` 里同版本那一节。

## 许可证

本项目基于 [GNU 通用公共许可证第 3 版（GPL-3.0）](../../LICENSE)授权。参与贡献即说明您同意您的代码以此许可证进行许可。