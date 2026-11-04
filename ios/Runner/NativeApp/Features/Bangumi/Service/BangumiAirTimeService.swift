//
//  BangumiAirTimeService.swift
//  Kazumi
//
//  放送时刻（「每周六 20:00」里的 20:00）。
//
//  对应原版 lib/services/bangumi_update_times.dart 的一部分：原版从
//  bangumi-mal 的季度 JSON（https://github.com/LinkPass888/bangumi-mal，CC BY 4.0）
//  取每部番的开播时刻与播出周期，再换算成本地时间。季度文件地址形如
//  `data/seasons/{年}/{季首月}.json`，季首月只可能是 1 / 4 / 7 / 10，
//  items 以 bangumi id 为键，含 `begin`（ISO UTC）与 `broadcast`（`R/<ISO>/P7D`）。
//
//  这里只做详情页需要的那一件事：算出「几点播」，格式化成 HH:mm。
//  取不到就返回 nil，详情页那一行只显示星期，不显示时刻。
//

import Foundation
import Observation

/// 某部番的放送时刻表（对应 Dart 的 BangumiUpdateEntry 子集）。
struct BangumiAirSchedule: Hashable, Sendable {
    /// 首播时刻（本地时区，含具体钟点）。
    var first: Date
    /// 播出周期（秒），即 `R/<ISO>/P7D` 里的 7 天。
    var period: TimeInterval

    /// 已经播出到第几集（1-based）；尚未开播返回 nil。
    ///
    /// 与 Dart 的 `currentEpisode` 同一套算式：`((now - first) ~/ period) + 1`。
    func currentEpisode(now: Date = Date()) -> Int? {
        guard period > 0 else { return nil }
        let elapsed = now.timeIntervalSince(first)
        guard elapsed >= 0 else { return nil }
        return Int(elapsed / period) + 1
    }
}


@MainActor
@Observable
final class BangumiAirTimeService {
    static let shared = BangumiAirTimeService()

    /// bangumi id -> "20:00"
    private(set) var times: [Int: String] = [:]
    /// bangumi id -> 首播时刻 + 周期（时间表卡片的「第 N 话」用它推算）。
    private(set) var schedules: [Int: BangumiAirSchedule] = [:]
    /// bangumi id -> MAL id，AniList 查询要用（它的接口只认 MAL id）。
    private(set) var malIDs: [Int: Int] = [:]
    private(set) var isLoading = false

    /// 已经成功加载过的季度（"2025-10"）。
    private var loadedSeasons = Set<String>()
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// 季度数据 7 天更新一次，与原版 _maxAge 一致。
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// 缓存文件保留一年：目录原来只写不删，季度一多就会无限长下去。
    private static let cacheMaxAge: TimeInterval = 365 * 24 * 60 * 60

    private let directory: URL
    private let sessionProvider: ProxyAwareURLSession
    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private var session: URLSession { sessionProvider.session }

    private init() {
        // 和 main 一样落在 Application Support：Caches 会被系统在存储紧张时整目录
        // 清掉，清掉之后每次冷启动都要重新拉季度数据，卡片上的「HH:mm 更新」
        // 就会慢一拍才出现。
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = support
            .appendingPathComponent("Kazumi", isDirectory: true)
            .appendingPathComponent("update_times", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // 建不出来就只在内存里用这一份，下次启动重新拉。
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        sessionProvider = ProxyAwareURLSession {
            KazumiNetworkPolicy.applyProxy(to: configuration)
            return configuration
        }
    }

    // MARK: - 查询

    /// 下一次更新的时刻（epoch 毫秒），没有数据返回 nil。
    ///
    /// 与 main 的 `nextUpdateEpoch` 同一条链路：AniList 实测优先，
    /// 取不到再用 bangumi-mal 的季度表推算。
    /// - AniList 缓存新鲜（还没到那一集）：airingAt 就是下一次；
    /// - 已过期（那一集已经播了）：airingAt 加一个周期才是下一次；
    /// - 完播的番 AniList 没有下一集，交给季度表。
    func nextUpdateEpoch(for subjectID: Int, now: Date = Date()) -> Int? {
        if let airing = AniListClient.shared.staleCached(subjectID, now: now), !airing.finished {
            if airing.isFresh(at: now) { return airing.airingAt }
            if let period = schedules[subjectID]?.period, period > 0 {
                return airing.airingAt + Int(period * 1000)
            }
        }
        return nextUpdateEpochFromSeason(subjectID: subjectID, now: now)
    }

    /// 只用季度表推算下一次更新：首播时刻加若干个周期。
    private func nextUpdateEpochFromSeason(subjectID: Int, now: Date) -> Int? {
        guard let schedule = schedules[subjectID], schedule.period > 0 else { return nil }
        let elapsed = now.timeIntervalSince(schedule.first)
        guard elapsed >= 0 else { return nil }
        let period = schedule.period
        let periods = (elapsed / period).rounded(.down) + 1
        return Int((schedule.first.timeIntervalSince1970 + periods * period) * 1000)
    }

    /// 某部番的播出时刻（本地时间 "HH:mm"），没有数据返回 nil。
    func airTime(for subjectID: Int) -> String? {
        guard let epoch = nextUpdateEpoch(for: subjectID) else { return nil }
        return Self.timeText(Date(timeIntervalSince1970: Double(epoch) / 1000))
    }

    /// 已经播出到第几集（1-based），没有数据返回 nil。
    ///
    /// 与 main 的 `currentEpisode` 一致：AniList 新鲜时「下一集」还没播，
    /// 已播到 episode − 1；缓存过期说明那一集已经播了，已播到 episode 本身。
    func currentEpisode(for subjectID: Int, now: Date = Date()) -> Int? {
        if let airing = AniListClient.shared.staleCached(subjectID, now: now), !airing.finished {
            return airing.isFresh(at: now) ? airing.currentEpisode : airing.episode
        }
        return schedules[subjectID]?.currentEpisode(now: now)
    }

    /// 批量补齐 AniList 的播出时刻。
    ///
    /// 只发「需要重查」的番，按 25 部一批合并请求（见 AniListClient）。
    /// 失败不影响调用方：读的时候自动退回季度表。
    func ensureAniListLoaded(_ subjectIDs: [Int]) async {
        let known = malIDs
        guard !known.isEmpty else { return }
        await AniListClient.shared.ensureLoaded(subjectIDs, malIDs: known)
    }

    /// 某部番的首播时刻与周期（更新提醒按它推算下一集），没有数据返回 nil。
    func schedule(for subjectID: Int) -> BangumiAirSchedule? {
        schedules[subjectID]
    }

    /// 加载这部番所属季度（以及当前季度，兼顾跨季番）的时刻表。
    func ensureLoaded(subjectID: Int, airDate: String) async {
        guard times[subjectID] == nil else { return }

        var seasons = Self.season(of: airDate).map { [$0] } ?? []
        seasons.append(Self.currentSeason())
        for season in Set(seasons.map(\.id)) where !loadedSeasons.contains(season) {
            await loadSeason(id: season)
        }
    }

    /// 加载某个日期所属季度（以及当前季度）的时刻表。
    ///
    /// 时间表页整季展示时会一次性需要几十部番的时刻，逐部调用
    /// `ensureLoaded(subjectID:airDate:)` 会重复建任务；这里按季度去重，
    /// 一个季度只发一次请求。
    func ensureLoaded(forSeasonOf date: Date) async {
        let target = Self.season(of: date)
        let current = Self.currentSeason()
        for season in [target, current] where !loadedSeasons.contains(season.id) {
            await loadSeason(id: season.id)
        }
    }

    /// 缓存诊断：缓存目录、文件数、占用字节。设置页「存储与日志」显示它。
    func cacheDiagnostics() -> (directory: String, fileCount: Int, bytes: Int) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var bytes = 0
        for file in files {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return (directory.path, files.count, bytes)
    }

    // MARK: - 季度

    private struct Season: Hashable {
        let year: Int
        let month: Int
        var id: String { String(format: "%04d-%02d", year, month) }
    }

    /// Date -> 所在季度。
    private static func season(of date: Date) -> Season {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month], from: date)
        let year = components.year ?? 2024
        let month = components.month ?? 1
        return Season(year: year, month: ((month - 1) / 3) * 3 + 1)
    }

    /// "yyyy-MM-dd" -> 所在季度；解析不出来返回 nil。
    private static func season(of airDate: String) -> Season? {
        let parts = airDate.split(separator: "-")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month)
        else { return nil }
        return Season(year: year, month: ((month - 1) / 3) * 3 + 1)
    }

    private static func currentSeason() -> Season {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month], from: Date())
        let year = components.year ?? 2024
        let month = components.month ?? 1
        return Season(year: year, month: ((month - 1) / 3) * 3 + 1)
    }

    private static func remoteURL(for season: Season) -> URL? {
        let month = String(format: "%02d", season.month)
        return URL(string: "https://linkpass888.github.io/bangumi-mal/data/seasons/\(season.year)/\(month).json")
    }

    private func cacheURL(for season: Season) -> URL {
        directory.appendingPathComponent("\(season.id).json")
    }

    /// 清掉一年前的季度文件（按修改时间）。
    ///
    /// 只动 `.json`，刚写的那一份永远跳过；删不掉就跳过——
    /// 清理失败不该影响本次放送时刻的使用。
    private func pruneOldCaches(keeping current: URL) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.cacheMaxAge)
        let files = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "json" && file != current {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: file)
        }
    }

    // MARK: - 加载

    private func loadSeason(id: String) async {
        if let running = inFlight[id] {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchSeason(id: id)
        }
        inFlight[id] = task
        await task.value
        inFlight[id] = nil
    }

    private func fetchSeason(id: String) async {
        isLoading = true
        var applied = false
        defer {
            isLoading = false
            // 只有真拿到数据才算加载过；否则下次还要再试，不然一次失败就永远没时刻。
            if applied { loadedSeasons.insert(id) }
        }

        let components = id.split(separator: "-")
        guard components.count == 2,
              let year = Int(components[0]),
              let month = Int(components[1])
        else { return }
        let season = Season(year: year, month: month)
        let fileURL = cacheURL(for: season)

        let cached = try? Data(contentsOf: fileURL)
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        let isFresh = modified.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false

        // 1. 本地缓存（7 天内直接用，不再发请求）
        if isFresh, let cached {
            apply(cached)
            applied = true
            return
        }

        // 2. 远端
        if let remote = Self.remoteURL(for: season) {
            do {
                let (data, response) = try await session.data(from: remote)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    apply(data)
                    applied = true
                    try? data.write(to: fileURL, options: .atomic)
                    pruneOldCaches(keeping: fileURL)
                    return
                }
            } catch {
                // 下面统一走旧缓存兜底。
            }
        }

        // 3. 拉不到（离线 / 非 2xx）就用过期缓存，main 也是这个顺序：
        //    过期的数据总比空表好，卡片至少还有「HH:mm 更新」。
        if let cached {
            apply(cached)
            applied = true
        }
    }

    private func apply(_ data: Data) {
        for (subjectID, schedule) in Self.parse(data) {
            times[subjectID] = Self.timeText(schedule.first)
            schedules[subjectID] = schedule
        }
        for (subjectID, malID) in Self.parseMalIDs(data) {
            malIDs[subjectID] = malID
        }
    }

    /// 季度 JSON 里的 mal_id，AniList 用它查下一集时刻。
    private static func parseMalIDs(_ data: Data) -> [Int: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [String: Any]
        else { return [:] }
        var result: [Int: Int] = [:]
        for (key, value) in items {
            guard let subjectID = Int(key),
                  let entry = value as? [String: Any],
                  let malID = entry["mal_id"] as? Int
            else { continue }
            result[subjectID] = malID
        }
        return result
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 解析季度 JSON，返回「bangumi id -> 首播时刻 + 周期」。
    private static func parse(_ data: Data) -> [Int: BangumiAirSchedule] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [String: Any]
        else { return [:] }

        var result: [Int: BangumiAirSchedule] = [:]
        for (key, value) in items {
            guard let subjectID = Int(key), let entry = value as? [String: Any] else { continue }
            let beginText = entry["begin"] as? String ?? ""
            let broadcast = entry["broadcast"] as? String ?? ""
            // 与原版 deriveBangumiMalEntry 一致：begin 只有日期（或年月）时
            // 拿不出可信的播出时刻，不显示。
            guard beginText.count > 10 else { continue }
            guard let period = parseBroadcastPeriod(broadcast) else { continue }
            guard let begin = parseInstant(beginText) else { continue }
            result[subjectID] = BangumiAirSchedule(first: begin, period: period)
        }
        return result
    }

    /// `R/<ISO>/P7D` 里的周期；解析不出来（或为 0）返回 nil。
    ///
    /// 这里只用来判断「这条记录有没有可靠时刻」，与时刻本身无关。
    private static func parseBroadcastPeriod(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("R/") else { return nil }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 3 else { return nil }
        let period = String(parts[2])
        guard period.hasPrefix("P") else { return nil }
        var seconds: TimeInterval = 0
        var digits = ""
        for character in period.dropFirst() {
            if character.isNumber {
                digits.append(character)
            } else if character == "D" {
                seconds += (Double(digits) ?? 0) * 86_400
                digits = ""
            } else if character == "H" {
                seconds += (Double(digits) ?? 0) * 3_600
                digits = ""
            } else if character == "T" {
                digits = ""
            } else {
                return nil
            }
        }
        return seconds > 0 ? seconds : nil
    }

    /// 解析带时刻的 ISO 时间戳（`Z` 或 `+00:00`，可带小数秒）。
    private static func parseInstant(_ text: String) -> Date? {
        for formatter in instantFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let instantFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()
}
