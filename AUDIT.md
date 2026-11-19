# Kazumi-Swift 全项目走查报告

全项目走查完毕。按**「交互流程精简」「功能链路断层」「起播与主线程性能」「工程与 CI/发版」**四大类整理如下，方便按编号挑要做的项：

---

## 一、交互流程繁琐（可显著减少点击步数与页面跳转）

| 编号 | 模块 / 涉及文件 | 当前繁琐流程 | 建议简化方案 | 收益 |
| :--- | :--- | :--- | :--- | :--- |
| **U1** | 观看历史 / 详情页续播<br>LibraryStore.swift、PlayerController.swift、BangumiInfoScreen.swift | 1）`WatchRecord` 未存 `detailURL`，每次从历史/个人页续播都要重新联网跑一次规则搜索，且用别名搜到的番或同名多结果会直接报「没找到播放源」；<br>2）详情页即使已有观看记录，右下角仍固定是「开始观看 → 弹出选源面板重新全源搜索」（至少 3 步）。 | 1）`WatchRecord` 向后兼容保存 `detailURL`，历史/个人页直带 `PlaybackSource` 秒进章节解析；<br>2）详情页有可用历史记录时主按钮升级为「继续观看 · 第 N 集」（旁留紧凑「换源」入口）。 | 续播省掉整轮搜索等待（快 1–5s），详情页 1 键续播 |
| **U2** | 看完返回自动重弹选源面板<br>BangumiInfoScreen.swift、PopularHero.swift | 从详情页或推荐大图进播放器无条件设 `returnToSourcesAfterPlayer = true`，正常看完退出播放页也会强行把选源半屏再弹出来，每次都要多点一下关闭。 | 仅在播放失败页主动点「返回选源」时才回弹 `SourceSheet`，正常返回直接回到详情/推荐页（播放器内已有换源菜单）。 | 每次看完退出少关一次弹窗 |
| **U3** | 播放页切源重复全量搜索<br>PlayerScreen.swift、InfoController.swift | 详情页刚跑完全规则搜索，进播放器点「全部规则源对比…」又新建空 `InfoController` 把所有规则重搜一遍，且丢失了番剧别名（`alias`）。 | 在 `SourceSheetCoordinator` 按 `bangumiID` 复用刚搜好的 `InfoController` 与缓存条目别名。 | 播放内切源 0 等待秒开，保留别名检索 |
| **U4** | 规则更新与剪贴板导入<br>PluginListView.swift、PluginShopView.swift、PluginImportSheet.swift | 1）进「规则管理」不会拉取目录导致「更新全部」置灰，必须先去「规则仓库」转一圈再退回来才能点；且「规则仓库 → 可更新」页反而没有「更新全部」按钮；<br>2）点「从剪贴板导入」打开的是空输入框，还要再手动点一次「从剪贴板粘贴」。 | 1）`PluginListView` 进入时自动静默刷新目录，「规则仓库 → 可更新」补上「更新全部」，个人页「规则管理」显示可更新数角标；<br>2）`PluginImportSheet` 打开自动读取剪贴板并预览，1 键确认导入。 | 剪贴板导规则 6 步变 2 步，规则批量更新免来回跳页 |
| **U5** | 手动匹配弹幕每集重搜<br>PlayerScreen.swift、PlayerController.swift | 打开「弹幕检索」只填词不自动搜索，点进番剧不自动滚到当前集，且手动匹配结果只管当前这一集——切下一集又失效，得每集重复搜一遍。 | 弹窗打开自动搜索、展开后自动定位高亮当前集，并在同一部番会话内记住手动匹配的 `danDanAnimeID` 供后续切集自动复用。 | 未映射番剧每季只需手配 1 次而非每集重配 |
| **U6** | 追番页同步 / 历史页跳转与清理<br>LibraryScreen.swift、WatchHistoryScreen.swift | 1）追番页点「同步」需跳 3 层页面才能点「立即同步追番」，且不支持下拉刷新同步；<br>2）观看历史卡片无法跳「番剧详情」，且只能单条长按删或「清空全部」，无多选删除与搜索。 | 1）追番页支持下拉直接同步（已配好 Token 时「同步」直接原地执行）；<br>2）历史页长按菜单补「查看番剧详情」，顶栏补搜索与多选删除。 | 追番同步 5 步变 1 下拉；历史页补齐看详情与批量清理 |
| **U7** | 以图搜番与搜索历史栈堆积<br>ImageSearchScreen.swift、SearchHistoryScreen.swift、SearchScreen.swift | 1）以图搜番选完图还要再点一次「识别」，点「搜索这部番」返回时 `.onDisappear` 清空了识别列表，搜不到时得重新传图；<br>2）搜索历史点词会再 push 一层新 `SearchScreen`，反复点会堆多层返回栈；空搜索页打开未自动弹键盘。 | 1）选图后自动开始识别，跳转搜索保留识别结果；<br>2）搜索历史选中后回填当前搜索页并 pop，空搜索页进入自动聚焦输入框。 | 省掉每次选图后的多余确认，消除套娃返回栈 |
| **U8** | WebDAV / Bangumi 首次配置与自定义规则仓切换<br>WebDAVScreen.swift、BangumiSyncScreen.swift、RulesRepositoryScreen.swift | 1）WebDAV「保存并测试」成功后总开关和 3 个内容开关仍全关，还需连开 4 个开关才能点同步；Bangumi 验证 Token 后必须开「自动同步」才允许点手动「立即同步」；<br>2）自定义规则仓无法点击切换回内置仓，必须删掉自定义仓才能切回。 | 1）WebDAV 首次测试成功自动开启同步与默认内容项；Bangumi 绑好 Token 即可手动单次同步；<br>2）规则仓列表支持点击任意仓库切换为当前生效仓，免删除。 | 首次配置同步从 7 步缩至 2 步，规则仓无损切换 |
| **U9** | 播放页加入下载后的反馈与入口<br>PlayerScreen.swift | 选集点「下载 N 集」后无提示气泡，要去查看进度需连退多层切到「我的 → 离线下载」，且入队时 `coverURL` 传了空串导致下载页缺封面。 | 入队时补传番剧封面与标准标题，弹出「已加入下载队列」提示并在下载按钮菜单提供直达「下载管理」入口。 | 补齐下载记录封面，1 键直达下载管理 |

---

## 二、走查发现的功能链路断层（建议优先修）- ✅ 全部已完成

| 编号 | 模块 / 涉及文件 | 现象与根因 | 修复方案 | 状态 |
| :--- | :--- | :--- | :--- | :--- |
| **B1** | 播放器内点「关键词屏蔽」会直接杀掉播放 & 屏蔽词实际未生效<br>SettingsDetailScreens.swift、DanmakuOverlayView.swift、DanmakuShieldScreen.swift | 1）播放器弹幕设置弹窗内点「关键词屏蔽」调用了 `router.push(.danmakuShield)`，跳到了底下主导航栈盖住 `PlayerScreen`，触发 `PlayerScreen.onDisappear` 直接销毁 `MPVEngine` 停播；<br>2）`DanmakuOverlayView.apply` 只按来源和去重过滤，**完全没读取 `danmakuFilterRules`**，屏蔽词与正则实际未生效。 | 1）`DanmakuSettingsScreen` 改用 `NavigationLink { DanmakuShieldScreen() }` 在当前栈内推入，不断流；<br>2）在 `DanmakuOverlayView.apply` 接入字面量与 `/正则/` 屏蔽词实时过滤，并通过 `SettingsStore` 同步更新。 | ✅ 已完成 |
| **B2** | 离线下载页断网点播放卡 15–30 秒<br>DownloadScreen.swift、PlayerController.swift | `PlayerController.start()` 的离线秒开快径限制了 `if source == nil`，而 `DownloadScreen` 传了非空 `source`，导致飞行模式/弱网下点已下完剧集仍先联网跑 `queryChapters` 等超时后才回退本地文件。 | 只要 `localFile?(currentEpisode) != nil && episodes.isEmpty`，无论 `source` 是否为空均立即本地起播、章节列表改后台静默刷新。 | ✅ 已完成 |
| **B3** | 「规则仓库加速」重启失效 & 备份恢复 23+ 项设置需重启才生效<br>SettingsStore.swift、SettingsStore+Backup.swift | 1）`rulesMirror` 写入带 `kazumi.settings.` 前缀，`init` 读取漏了前缀，每次冷启动重置回 `gh-proxy`；<br>2）`applyBackup` 漏同步 15 项弹幕样式及硬解/低内存/AniSkip 等共 23+ 个内存属性，恢复备份后界面不刷新。 | 1）补齐 `Self.read` 前缀；<br>2）`applyBackup` 写完 `UserDefaults` 后统一刷新 `SettingsStore` 内存属性。 | ✅ 已完成 |
| **B4** | `kazumi://` 规则分享链接打不开 & 规则管理拖拽排序失效<br>KazumiAppDelegate.swift、AppRouter.swift、PluginListView.swift | 1）系统外点击 `kazumi://<base64>` 规则深链会被 `KazumiLink.parse` 静默丢弃；<br>2）`PluginListView` 删了上下移菜单却没绑 `.editMode`，多选态无拖拽手柄，且在「可更新」筛选下移动会错位；<br>3）推荐大图 `PopularHero` 对「想看/看过」番点按钮会误删收藏，详情页改状态会把 `currentEpisode` 覆写成 `0`。 | 1）`openURL` 识别规则深链直接弹导入确认框；<br>2）绑定 `editMode` 并在筛选态禁用拖拽；<br>3）统一追番状态修改入口，保留已有集数进度。 | ✅ 已完成 |

---

## 三、网络、起播与主线程性能优化 - ✅ 全部已完成

| 编号 | 模块 / 涉及文件 | 当前瓶颈 | 优化方案 | 收益 | 状态 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **P1** | 起播弹幕串行等待 & 弹弹play 映射重复请求<br>PlayerController.swift、DanmakuAPI.swift、VideoSourceWebView.swift | 1）弹幕要等章节解析 + WebView 嗅探出视频地址（3–8s）后才开始拉取；<br>2）每切一集都重新请求 `bgmID → danDanAnimeID` 映射；<br>3）WebView 注释写 `didFinish` 后等 4s 重试，实际只睡 2s 会打断慢站点嗅探。 | 1）确定集数后立即并行拉弹幕，首帧即有弹幕；<br>2）内存缓存 `[bgmID: danDanAnimeID]`；<br>3）恢复 `didFinish` 4s 重试窗口并并发注入登录 Cookie。 | 首帧弹幕提早 3–8s 就绪，连看时弹幕请求减半 | ✅ 已完成 |
| **P2** | 追番页封面逐张串行加载 + 150 次全网格重排<br>LibraryScreen.swift、BangumiSync.swift | 1）`LibraryScreen` 禁用了卡片自身并发加载，改用单循环逐张串行拉封面，且命中缓存也每次 `coverLoadRevision += 1` 触发整张网格重绘；<br>2）首次同步 300 部 Bangumi 追番时在主线程循环 `upsert`，触发 300 次全量 JSON 编码与写盘。 | 1）交回 `KazumiImageLoader` 6 路并发按可视区加载，删掉循环刷版本号；`loadUpdateTimes` 改调已有的批量并发接口；<br>2）`BangumiSync` 内存合并后一次性 `library.replace` 落盘。 | 追番封面加载快约 6 倍，百部追番同步不卡主线程 | ✅ 已完成 |
| **P3** | 播放页空转轮询与定时关闭每秒整页重绘<br>PlayerScreen.swift、LibraryStore.swift | 1）`menuOpen == false` 时仍有 300ms 死循环常驻唤醒主线程；<br>2）开启定时关闭后每秒改 `@State sleepTimerRemaining`，触发 6200 行 `PlayerScreen` 每秒全量重算；<br>3）每 12s 保存进度在主线程同步编码整份 `library.json` 写盘。 | 1）改为 `.task(id: menuOpen)` 仅开菜单时探测；<br>2）定时关闭改为记录 `endDate` 单次 `sleep`，仅展开菜单时算剩余分秒；<br>3）`LibraryStore.save()` 改为防抖后台写盘（退后台/退页立即冲刷）。 | 消除播放期后台空转与掉帧隐患 | ✅ 已完成 |
| **P4** | 镜像模式漏写条目缓存、存储页主线程扫盘、WebDAV 重复往返<br>BangumiAPI.swift、StorageScreen.swift、WebDAVSync.swift、DLNABrowser.swift | 1）`mirrorPopular` / `listByTag` 未写入 `BangumiSubjectCache`，开镜像点热门卡片进详情无秒开缓存；<br>2）`StorageScreen` 在主线程同步遍历计算所有 HLS 分片体积且清理后硬睡 `300ms`；<br>3）WebDAV 每次无变更也重传并整包重下校验；<br>4）DLNA 投屏忽略上次电视地址，等扫完 254 个 IP（约 6s）才一次性出列表且硬截断前 4 台。 | 1）镜像接口补写 `BangumiSubjectCache`；<br>2）存储统计与整批删除移至后台线程并支持 GB 单位显示；<br>3）WebDAV 并发读取、无变更跳过上传；<br>4）DLNA 优先探测上次地址（<200ms）并分批渐进刷新设备列表。 | 详情秒开、清理缓存不卡顿、WebDAV 与投屏显著提速 | ✅ 已完成 |

---

## 四、工程架构与 CI / 发版流程精简 - ✅ 全部已完成

| 编号 | 模块 / 涉及文件 | 当前繁琐点 | 优化方案 | 状态 |
| :--- | :--- | :--- | :--- | :--- |
| **E1** | PR / Release 工作流缺少并发取消、SPM 缓存与发版校验<br>pr.yaml、release.yaml、README.md | 1）`pr.yaml` 无 `concurrency` 自动取消，连续 push 会并跑多套 macOS 任务；<br>2）每次构建都无缓存重装 `xcodegen/xcbeautify` 并双份重下数百 MB 的 `MPVKit`；<br>3）发版需手改 4 处版本号，`release.yaml` 手动 `workflow_dispatch` 时 `${tag}` 含 `/` 会打包失败，且未校验/注入 Tag 版本号。 | 1）`pr.yaml` 加 `concurrency: cancel-in-progress: true` 并缓存 SPM 产物；<br>2）`release.yaml` 从 Tag 自动校验/注入版本号并修复手动触发分支，README.md 改动态 Release 徽章免手改。 | ✅ 已完成 |
| **E2** | 清理未使用的死代码与窄屏/宽屏设置页宽度统一<br>KazumiSyncClient.swift、KazumiSyncHistory.swift、SettingsDetailScreens.swift、LogScreen.swift | 1）`KazumiSyncClient.swift` 与 `KazumiSyncHistory.swift`（共 562 行）全工程零引用；播放器菜单「一起看」目前只是空壳表单；启动检查的 `pluginUpdateCount` 算完无人读取；<br>2）`WebDAV / Bangumi同步 / 存储 / 日志 / 更新日志` 在 iPad / Mac 上未套统一的 `maxWidth: 700`；日志页缺「全部」分类与搜索，复制日志只复制了当前单页。 | 1）移除零引用死文件，`SettingsStore` 清理重复旧属性对；<br>2）二级设置页统一复用 `700pt` 居中容器；日志页补「全部 + 搜索 + 带环境头一键导出」。 | ✅ 已完成 |
| **E3** | 拆分 6200+ 行单文件 PlayerScreen.swift | 单个文件塞了 10+ 个独立视图/布局与 65+ 个 `@State`，多次触发 Swift 编译器类型检查超时，且选源/追番菜单逻辑与详情页重复三份。 | 将 `PlayerVolumeControl`、`PlayerStageLayout`、`DanmakuSourceSheet`、液态玻璃组件及通用追番/选源协调抽成独立文件，保持行为 100% 不变。 | ✅ 已完成 |
