# 启动页图片

原生启动页 `ios/Runner/Base.lproj/LaunchScreen.storyboard` 使用本目录的 `LaunchImage` 图片资源。

从仓库根目录生成并打开 Xcode 工程：

```bash
xcodegen generate --spec ios/project.yml --project ios
open ios/Runner.xcodeproj
```

在 Xcode 中选择 `Runner/Assets.xcassets/LaunchImage`，替换对应缩放比例的浅色、深色图片。
直接替换文件时，保持文件名与本目录 `Contents.json` 的引用一致；调整启动页布局则修改 `LaunchScreen.storyboard`。
