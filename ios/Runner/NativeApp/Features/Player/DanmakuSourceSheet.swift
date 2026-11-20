//
//  DanmakuSourceSheet.swift
//  Kazumi
//

import SwiftUI

struct DanmakuSourceSheet: View {
    let initialKeyword: String
    let currentEpisode: Int
    let onSelectEpisode: (DanmakuEpisode, Int, [DanmakuEpisode]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String
    @State private var animes: [DanmakuSearchAnime] = []
    @State private var selectedAnime: DanmakuSearchAnime?
    @State private var episodes: [DanmakuEpisode] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var didAutoSearch = false

    init(
        initialKeyword: String,
        currentEpisode: Int = 1,
        onSelectEpisode: @escaping (DanmakuEpisode, Int, [DanmakuEpisode]) async -> String?
    ) {
        self.initialKeyword = initialKeyword
        self.currentEpisode = max(1, currentEpisode)
        self.onSelectEpisode = onSelectEpisode
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        Group {
            if let selectedAnime {
                episodeContent(selectedAnime)
            } else {
                searchContent
            }
        }
        .navigationTitle(selectedAnime == nil ? "弹幕检索" : "选择分集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
        .overlay {
            if loading {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .disabled(loading)
        .task {
            // U5：弹窗打开时有预填词即自动发起检索，省去一次手动点「搜索」。
            guard !didAutoSearch else { return }
            didAutoSearch = true
            guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await search()
        }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("番剧名称", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                    .textFieldStyle(.roundedBorder)
                Button("搜索") {
                    Task { await search() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            if let errorMessage {
                errorLabel(errorMessage)
            }

            List(animes) { anime in
                Button {
                    Task { await loadEpisodes(for: anime) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(anime.animeTitle)
                                .foregroundStyle(.primary)
                            if !anime.typeDescription.isEmpty {
                                Text(anime.typeDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func episodeContent(_ anime: DanmakuSearchAnime) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedAnime = nil
                    episodes = []
                    errorMessage = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                Text(anime.animeTitle)
                    .lineLimit(1)
                Spacer()
            }
            .padding()

            if let errorMessage {
                errorLabel(errorMessage)
            }

            ScrollViewReader { proxy in
                List(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    let isCurrent = isCurrentEpisode(episode, index: index, animeID: anime.animeID)
                    Button {
                        Task { await select(episode, animeID: anime.animeID) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(episode.episodeTitle)
                                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                .fontWeight(isCurrent ? .semibold : .regular)
                            if isCurrent {
                                Text("当前集")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.accentColor.opacity(0.14))
                                    )
                            }
                            Spacer()
                            Image(systemName: "captions.bubble")
                                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(episode.episodeID)
                }
                .listStyle(.plain)
                .task(id: episodes.count) {
                    guard let targetID = matchedEpisodeID(for: anime.animeID) else { return }
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
            }
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    private func search() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = String(localized: "请输入番剧名称")
            return
        }
        loading = true
        errorMessage = nil
        animes = []
        defer { loading = false }
        do {
            animes = try await DanmakuAPI.searchAnimes(query)
            if animes.isEmpty {
                errorMessage = String(localized: "未找到番剧")
            }
        } catch {
            errorMessage = String(localized: "搜索失败：\(error.localizedDescription)")
        }
    }

    private func loadEpisodes(for anime: DanmakuSearchAnime) async {
        loading = true
        errorMessage = nil
        episodes = []
        defer { loading = false }
        do {
            let result = try await DanmakuAPI.episodes(animeID: anime.animeID)
            selectedAnime = anime
            episodes = result
            if result.isEmpty {
                errorMessage = String(localized: "暂无分集")
            }
        } catch {
            errorMessage = String(localized: "分集加载失败：\(error.localizedDescription)")
        }
    }

    private func isCurrentEpisode(_ episode: DanmakuEpisode, index: Int, animeID: Int) -> Bool {
        if let matched = matchedEpisodeID(for: animeID) {
            return episode.episodeID == matched
        }
        return index + 1 == currentEpisode
    }

    private func matchedEpisodeID(for animeID: Int) -> Int? {
        let standardID = animeID * 10_000 + currentEpisode
        if episodes.contains(where: { $0.episodeID == standardID }) {
            return standardID
        }
        let idx = currentEpisode - 1
        return episodes.indices.contains(idx) ? episodes[idx].episodeID : nil
    }

    private func select(_ episode: DanmakuEpisode, animeID: Int) async {
        loading = true
        errorMessage = nil
        if let failure = await onSelectEpisode(episode, animeID, episodes) {
            errorMessage = String(localized: "弹幕源切换失败：\(failure)")
            loading = false
        } else {
            dismiss()
        }
    }
}
