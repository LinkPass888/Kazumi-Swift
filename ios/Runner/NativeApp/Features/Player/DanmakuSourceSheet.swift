//
//  DanmakuSourceSheet.swift
//  Kazumi
//

import SwiftUI

struct DanmakuSourceSheet: View {
    let initialKeyword: String
    let onSelectEpisode: (DanmakuEpisode) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String
    @State private var animes: [DanmakuSearchAnime] = []
    @State private var selectedAnime: DanmakuSearchAnime?
    @State private var episodes: [DanmakuEpisode] = []
    @State private var loading = false
    @State private var errorMessage: String?

    init(
        initialKeyword: String,
        onSelectEpisode: @escaping (DanmakuEpisode) async -> String?
    ) {
        self.initialKeyword = initialKeyword
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

            List(episodes) { episode in
                Button {
                    Task { await select(episode) }
                } label: {
                    HStack {
                        Text(episode.episodeTitle)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "captions.bubble")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
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

    private func select(_ episode: DanmakuEpisode) async {
        loading = true
        errorMessage = nil
        if let failure = await onSelectEpisode(episode) {
            errorMessage = String(localized: "弹幕源切换失败：\(failure)")
            loading = false
        } else {
            dismiss()
        }
    }
}
