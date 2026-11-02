//
//  StorageScreen.swift
//  Kazumi
//
//  存储与日志，对应 lib/pages/settings/storage_settings.dart：
//  * 缓存：显示图片缓存占用，可一键清除（下次加载重新下载）；
//  * 诊断：进入运行日志。
//
//  原版的「清除图片缓存」在清完后会重新统计一次大小，这里同样在清空后
//  重算，避免界面停在旧的 MB 数上。
//

import SwiftUI

struct StorageScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var cacheBytes: Int?
    /// 离线下载占用与集数（设置页那颗红色清除按钮用）。
    @State private var offlineBytes: Int64 = 0
    @State private var offlineEpisodes: Int = 0
    /// 更新时间缓存（放送时刻按季度缓存）。
    @State private var airTimeCache: (directory: String, fileCount: Int, bytes: Int) = ("", 0, 0)
    @State private var isClearing = false
    @State private var isConfirmingClear = false
    @State private var isConfirmingClearOffline = false
    /// 旧版本留下的下载占多少。没检测到东西就是 nil，那一行不出现。
    @State private var legacyBytes: Int64?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Group {
                    Button {
                        isConfirmingClear = true
                    } label: {
                        labelValueRow("清除图片缓存", symbol: "photo.on.rectangle.angled", value: cacheDescription)
                    }
                    .disabled(isClearing)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("图片缓存")
            } footer: {
                Text("图片会在下次加载时重新下载。视频、记录与设置不会删除。")
            }

            Section {
                Group {
                    // LP 5200：红字危险动作，问一句再删。
                    Button(role: .destructive) {
                        isConfirmingClearOffline = true
                    } label: {
                        labelValueRow("清除所有离线下载", symbol: "trash", value: offlineDescription, tint: .red)
                    }
                    .disabled(offlineEpisodes == 0)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("离线下载")
            } footer: {
                Text("删掉下载记录和已经下好的视频文件，不能恢复。")
            }

            // LP 5280：旧位置里留的东西不搬（两个版本的落盘形状和记录都对不上），
            // 检测到才给一行清除。
            if let legacyBytes {
                Section {
                    Group {
                        // LP 5284：旧格式本来就不能播，删它们不用再问一句。
                        Button(role: .destructive) {
                            Task { await clearLegacy() }
                        } label: {
                            labelValueRow("清除旧版本离线下载", symbol: "trash", value: formattedSize(legacyBytes), tint: .red)
                        }
                        .disabled(isClearing)
                    }
                    .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                } header: {
                    Text("旧版本")
                } footer: {
                    Text("旧版本下载的格式无法兼容。")
                }
            }

            Section {
                Group {
                    labelValueRow("更新时间缓存", symbol: "clock.arrow.circlepath", value: airTimeCacheDescription)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("更新时间")
            } footer: {
                Text("放送时刻按季度缓存 7 天，离线时用旧数据。")
            }

            Section {
                Group {
                    Button {
                        router.push(.logs)
                    } label: {
                        HStack {
                            Label("运行日志", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("诊断")
            }

            if let message {
                Section {
                    Group {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                }
            }
        }
        .navigationTitle("存储与日志")
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        // Colo 3532：二级页统一用分组页底。
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .kazumiSettingsNavBacking()
        .task { await refreshSize() }
        .confirmationDialog("清除图片缓存？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清除图片缓存", role: .destructive) {
                Task { await clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("图片会在下次加载时重新下载。视频、记录和设置不会删除。")
        }
        .confirmationDialog(
            "清除所有离线下载？",
            isPresented: $isConfirmingClearOffline,
            titleVisibility: .visible
        ) {
            Button("清除所有离线下载", role: .destructive) {
                Task { await clearOffline() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已经下好的视频文件和下载记录会一起删掉，不能恢复。")
        }
    }

    /// 一行「图标＋标题」加右侧数值。大字号下两者并排装不下时上下排，
    /// 标题占满一行、数值落到下一行——否则标题在半行宽里会被碎折成
    /// 「清 / 除圖片 / 快取」，一个字占一行（Ato 6592）。
    @ViewBuilder
    private func labelValueRow(
        _ title: LocalizedStringKey,
        symbol: String,
        value: String,
        tint: Color? = nil
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .foregroundStyle(tint ?? Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                Label(title, systemImage: symbol)
                    .foregroundStyle(tint ?? Color.primary)
                Spacer()
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cacheDescription: String {
        if isClearing { return String(localized: "正在清除…") }
        guard let cacheBytes else { return String(localized: "正在统计…") }
        return String(format: "%.2f MB", Double(cacheBytes) / (1024 * 1024))
    }

    /// 离线下载那一行右侧的占用与集数，比如「518.3 MB · 2 集」。
    private var offlineDescription: String {
        guard offlineEpisodes > 0 else { return formattedSize(offlineBytes) }
        return String(localized: "\(String(describing: formattedSize(offlineBytes))) · \(String(describing: offlineEpisodes)) 集")
    }

    /// 旧版本下载那一行右侧只写占用（Camo 5289）：跟「更新时间缓存」那行一个样子。

    private func formattedSize(_ raw: Int64) -> String {
        let bytes = Double(raw)
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        }
        if bytes > 0 {
            return String(format: "%.0f KB", bytes / 1024)
        }
        return "—"
    }

    /// 更新时间缓存只显示占用大小。原来的「N 个季度」读起来像在数番剧季度，
    /// 而且目录没有上限时那个数只会一直涨。空目录写「—」。
    private var airTimeCacheDescription: String {
        guard airTimeCache.bytes > 0 else { return "—" }
        let bytes = Double(airTimeCache.bytes)
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        }
        return String(format: "%.0f KB", max(1, bytes / 1024))
    }

    private func refreshSize() async {
        cacheBytes = await KazumiImageLoader.shared.diskSizeInBytes()
        airTimeCache = BangumiAirTimeService.shared.cacheDiagnostics()
        offlineBytes = environment.downloads.totalBytes()
        offlineEpisodes = environment.downloads.records.reduce(0) {
            $0 + $1.episodes.filter(\.isPlayableOffline).count
        }
        // 旧目录可能几百 MB，别在主线程上扫。
        legacyBytes = await Task.detached(priority: .utility) {
            AppEnvironment.legacyDownloadUsage()
        }.value
    }

    /// 删掉旧版本留在旧目录里的下载。现在的下载和记录都不动。
    private func clearLegacy() async {
        isClearing = true
        defer { isClearing = false }
        await Task.detached(priority: .userInitiated) {
            AppEnvironment.clearLegacyDownloads()
        }.value
        await refreshSize()
        message = String(localized: "已清除旧版本离线下载。")
    }

    /// 清掉全部离线下载：记录和文件一起走（DownloadCenter.removeAllRecords）。
    private func clearOffline() async {
        isClearing = true
        defer { isClearing = false }
        await MainActor.run {
            environment.downloads.removeAllRecords()
        }
        try? await Task.sleep(for: .milliseconds(300))
        await refreshSize()
        message = String(localized: "已清除全部离线下载。")
    }

    private func clear() async {
        isClearing = true
        defer { isClearing = false }
        KazumiImageLoader.shared.clear()
        // 清空是异步的（后台删文件），等一会儿再统计，避免读到旧值。
        try? await Task.sleep(for: .milliseconds(300))
        await refreshSize()
        message = String(localized: "图片缓存已清除")
    }
}
