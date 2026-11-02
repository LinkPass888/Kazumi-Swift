<div align=center>

<h1>Kazumi</h1>

<img src="assets/images/logo/logo_rounded.png" width=200></img>

<a href="https://t.me/KLGI66"><img src="https://img.shields.io/badge/Telegram-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white"></img></a>

<img src="https://img.shields.io/badge/Flutter-03A9F4?style=for-the-badge&logo=flutter&logoColor=white"></img>
<img src="https://img.shields.io/badge/Dart-00B4AB?style=for-the-badge&logo=Dart&logoColor=white"></img>

<a href="https://trendshift.io/repositories/11432"><img src="https://trendshift.io/api/badge/trendshift/repositories/11432/yearly?language=Dart"></img></a>
<a href="https://hellogithub.com/repository/Predidit/Kazumi" target="_blank"><img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=68d824ea55ee4b07aba6fe1dd61ac939&claim_uid=J9Qu6aDd8LT1nU0"/></img></a>

<p>使用 Flutter 开发的基于自定义规则的番剧采集与在线观看程序。使用最多五行基于 <code>Xpath</code> 语法的选择器构建自己的规则。支持规则导入与规则分享。支持基于 <code>Anime4K</code> 的实时超分辨率。绝赞开发中 (～￣▽￣)～</p>
</div>

## 支持平台

本仓库是 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 的 iOS 专用分支：在 2.3.0 的界面基础上做了 **iOS 26 液态玻璃（Liquid Glass）**适配，只提供 iOS 的未签名 ipa。

- iOS 26 及以上（需要 [侧载](https://kazumi.app/docs/misc/how-to-install-in-ios)）
- **液态玻璃界面**：iOS 26 上标签栏是原生 `UITabBar`，按钮、菜单、浮层用原生 `UIGlassEffect`；系统的「降低透明度」「增强对比度」「透明度」滑块会自动生效
- 因设备有限，仅在iPhone 17Pro上测试通过，其它设备未验证

## 屏幕截图

<table>
  <tr>
    <td><img alt="推荐" src="static/screenshot/img_1.jpg"></td>
    <td><img alt="时间表" src="static/screenshot/img_2.jpg"></td>
    <td><img alt="追番" src="static/screenshot/img_3.jpg"></td>
  <tr>
  <tr>
    <td><img alt="番剧详情" src="static/screenshot/img_4.jpg"></td>
    <td><img alt="搜索" src="static/screenshot/img_5.jpg"></td>
    <td><img alt="我的" src="static/screenshot/img_6.jpg"></td>
  <tr>
</table>

## 本仓库新增

- [X]  iOS原生液态玻璃界面
- [X]  自动跳过片头片尾(由[AniSkip](https://github.com/aniskip)提供时间,[bangumi-mal](https://github.com/LinkPass888/bangumi-mal)提供条目映射)
- [X]  Bangumi自动标记集看过
- [X]  更新时间展示与排序（时间表 / 详情页 / 追番）
- [X]  手动设置放送星期并添加到时间表
- [X]  更新提醒
- [X]  设置备份
- [X]  针对原版部分界面优化

## 下载

通过本仓库 [Releases](https://github.com/LinkPass888/Kazumi-iOS/releases/latest) 选项卡下载：

<a href="https://github.com/LinkPass888/Kazumi-iOS/releases">
  <img src="static/svg/get_it_on_github.svg" alt="Get it on Github" width="200"/>
</a>

发布的是**未签名 ipa**，需要使用 [AltStore](https://altstore.io/)、[Sideloadly](https://sideloadly.io/) 等工具侧载，并自备 Apple ID 进行签名。

## 贡献

欢迎向我们的 [规则仓库](https://github.com/Predidit/KazumiRules) 提交您的自定义规则。您可以自由选择是否在规则中留下您的ID。详细的规则编写教程可以参考 [规则开发文档](https://kazumi.app/docs/rules/develop-rules)

## Q&A

<details>
<summary>使用者 Q&A</summary>

#### Q: 为什么少数番剧中有广告？

A: 本项目未插入任何广告。广告来自视频源, 请不要相信广告中的任何内容, 并尽量选择没有广告的视频源观看。

#### Q: 为什么我启用超分辨率功能后播放卡顿？

A: 超分辨率功能对 GPU 性能要求较高, 如果没有在高性能独立显卡上运行 Kazumi, 尽量选择效率档而非质量档。对低分辨率视频源而非高分辨率视频源使用超分也可以降低性能消耗。

#### Q: 为什么播放视频时内存占用较高？

A: 本程序在视频播放时, 会尽可能多地缓存视频到内存, 以提供较好的观看体验。如果您的内存较为紧张, 可以在播放设置选项卡启用低内存模式, 这将限制缓存。

#### Q: 为什么少数番剧无法通过外部播放器观看？

A: 部分视频源的番剧使用了反盗链措施, 这可以被 Kazumi 解决, 但无法被外部播放器解决。

</details>

<details>
<summary>规则编写者 Q&A</summary>

#### Q: 为什么我的自定义规则无法实现检索？

A: 目前我们对 `Xpath` 语法的支持并不完整, 我们目前只支持以 `//` 开头的选择器。建议参照我们给出的示例规则构建自定义规则。

#### Q: 为什么我的自定义规则可以实现检索, 但不能实现观看？

A: 尝试关闭自定义规则的使用内置播放器选项, 这将尝试使用 `webview` 进行播放, 提高兼容性。但在内置播放器可用时, 建议启用内置播放器, 以获得更加流畅并带有弹幕的观看体验。

</details>

<details>
<summary>开发者 Q&A</summary>

#### Q: 我在尝试自行编译该项目, 但编译没有成功。

A: 本项目编译需要良好的网络环境, 除了由 Google 托管的 Flutter 相关依赖外, 本项目同样依赖托管在 CocoaPods/Github 上的资源。如果您位于中国大陆, 可能需要设置恰当的镜像地址。

</details>

## 开发

欢迎您提交 PR！在开始之前, 请阅读 [贡献指引](static/doc/CONTRIBUTING.md) 以了解我们对 PR 和 AI 参与辅助开发的规定。

## 美术资源

本项目图标来自 [Yuquanaaa](https://www.pixiv.net/users/66219277) 发表在 [Pixiv](https://www.pixiv.net/artworks/116666979) 上的作品。

此图标由其原作者 [Yuquanaaa](https://www.pixiv.net/users/66219277) 拥有版权。我们已获得原作者的授权和许可, 可以在本项目中使用这一图标。这一图标不是自由使用的, 未经原作者明确授权, 任何人不得擅自使用、复制、修改或分发这一图标。

## 免责声明

本项目基于 GNU 通用公共许可证第 3 版（GPL-3.0）授权。我们不对其适用性、可靠性或准确性作出任何明示或暗示的保证。在法律允许的最大范围内, 作者和贡献者不承担任何因使用本软件而产生的直接、间接、偶然、特殊或后果性的损害赔偿责任。

使用本项目需遵守所在地法律法规, 不得进行任何侵犯第三方知识产权的行为。因使用本项目而产生的数据和缓存应在24小时内清除, 超出 24 小时的使用需获得相关权利人的授权。

## 隐私政策

我们不收集任何用户数据, 不使用任何遥测组件。

## 赞助

| 赞助方 | 说明 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| <img src="https://kilo.ai/favicon/favicon.svg" width="50">                                                                                                                      | **Automatic PR review provided by [Kilo Code](https://kilo.ai/), sponsored by the [Kilo OSS Program](https://kilo.ai/oss)**                   |
| <a href="https://m.do.co/c/0062035db3e4"><img src="https://opensource.nyc3.cdn.digitaloceanspaces.com/attribution/assets/SVG/DO_Logo_icon_blue.svg" width="50" height="50"></a> | **Cloud infrastructure is supported by [DigitalOcean](https://m.do.co/c/0062035db3e4)**                                                       |

## 致谢

特别感谢 [XpathSelector](https://github.com/simonkimi/xpath_selector) 这个优秀的项目是本项目的基石。

特别感谢 [弹弹play](https://www.dandanplay.com/) 本项目使用了 弹弹play开放平台 以提供弹幕交互。

特别感谢 [Bangumi](https://bangumi.tv/) 本项目使用了 Bangumi 开放 API 以提供番剧元数据。

特别感谢 [Anime4K](https://github.com/bloc97/Anime4K) 本项目使用 Anime4K 进行实时超分。

特别感谢 [SyncPlay](https://github.com/Syncplay/syncplay) 本项目使用 SyncPlay 协议并通过 SyncPlay 公共服务器实现一起看功能。

特别感谢 [所有贡献者](https://github.com/LinkPass888/Kazumi-iOS/graphs/contributors) 本项目因为你们变得更好。

特别感谢 [trace.moe](https://trace.moe) 本项目使用了 trace.moe 提供的图片识别番剧功能。

特别感谢 [BangumiExtLinker](https://github.com/Rhilip/BangumiExtLinker) 本项目使用其 bangumi ↔ MAL 条目映射（CC BY 4.0）。

特别感谢 [bangumi-data](https://github.com/bangumi-data/bangumi-data) 本项目使用其番剧播出时间数据（CC BY 4.0）。

特别感谢 [bangumi-mal](https://github.com/LinkPass888/bangumi-mal) 本项目使用其合并后的映射表与按季播出数据（CC BY 4.0）。

感谢 [AniList](https://anilist.co) 本项目通过其公开 GraphQL API 获取实测播出时刻与集数。

感谢 [AniSkip](https://github.com/aniskip) 本项目使用 AniSkip 社区提供的片头片尾时间轴。

感谢 [media-kit](https://github.com/media-kit/media-kit) 本项目跨平台媒体播放能力来自 media-kit。

感谢 [avbuild](https://github.com/wang-bin/avbuild) 本项目使用了来自 avbuild 的树外补丁实现非标准视频流播放。

感谢 [hive](https://github.com/isar/hive) 本项目持久化储存能力来自 hive。
