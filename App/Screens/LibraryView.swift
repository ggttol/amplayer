import MP9Kit
import SwiftUI

/// 曲库：歌曲 / 艺术家 / 专辑 / 播放列表
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.songs
    @State private var query = ""
    @State private var playlists: [URL] = []

    enum Tab: String, CaseIterable { case songs = "歌曲", artists = "艺术家", albums = "专辑", playlists = "播放列表" }

    var body: some View {
        NavigationStack {
            let results = app.library.search(query)
            List {
                if !app.library.scanning.isEmpty {
                    Section {
                        ForEach(Array(app.library.scanning.keys), id: \.self) { id in
                            HStack {
                                ProgressView()
                                Text("正在扫描 \(app.sources.config(id)?.name ?? id)…")
                                Spacer()
                                Button("取消") { app.library.cancelScan(id) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                switch tab {
                case .songs:
                    if !results.isEmpty {
                        Button("播放全部（\(results.count) 首）", systemImage: "play.fill") { play(results, at: 0) }
                        Button("随机播放", systemImage: "shuffle") {
                            app.player.shuffle = true
                            play(results, at: Int.random(in: 0..<results.count))
                        }
                    }
                    songRows(results)
                case .artists:
                    ForEach(app.library.artists(in: results)) { group in
                        NavigationLink {
                            List { albumsOrSongs(group.tracks) }.navigationTitle(group.name)
                        } label: {
                            LabeledContent(group.name, value: "\(group.tracks.count) 首")
                        }
                    }
                case .albums:
                    ForEach(app.library.albums(in: results)) { group in
                        NavigationLink {
                            List {
                                Button("播放专辑", systemImage: "play.fill") { play(group.tracks, at: 0) }
                                songRows(group.tracks)
                            }
                            .navigationTitle(group.name)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(group.name)
                                Text(group.tracks.first?.artist ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                case .playlists:
                    Section {
                        ForEach(playlists, id: \.self) { url in
                            Button {
                                if let tracks = try? app.library.loadPlaylist(url), !tracks.isEmpty {
                                    play(tracks, at: 0)
                                } else {
                                    app.show("播放列表为空或无法读取")
                                }
                            } label: {
                                Label(url.deletingPathExtension().lastPathComponent, systemImage: "music.note.list")
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    app.library.deletePlaylist(url)
                                    playlists = app.library.savedPlaylists()
                                }
                                Button("加入") {
                                    if let tracks = try? app.library.loadPlaylist(url) { app.player.enqueue(tracks); app.show("已加入 \(tracks.count) 首") }
                                }.tint(.green)
                            }
                        }
                    } footer: {
                        Text("播放列表保存为 M3U，位于“文件”App › MP9 › Playlists，可与其他播放器互通。")
                    }
                }
            }
            .overlay {
                if tab != .playlists && app.library.tracks.isEmpty && app.library.scanning.isEmpty {
                    ContentUnavailableView("曲库是空的", systemImage: "music.note.house", description: Text("在“来源”里长按某个来源或文件夹，选择“扫描到曲库”。"))
                } else if tab == .playlists && playlists.isEmpty {
                    ContentUnavailableView("还没有保存的播放列表", systemImage: "music.note.list", description: Text("在播放列表窗口点 LIST › 保存播放列表。"))
                }
            }
            .searchable(text: $query, prompt: "搜索标题、艺术家、专辑")
            .navigationTitle("曲库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("分类", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }
            .onAppear { playlists = app.library.savedPlaylists() }
            .alert("曲库", isPresented: Binding(get: { app.library.lastError != nil }, set: { if !$0 { app.library.lastError = nil } })) {
                Button("好") {}
            } message: {
                Text(app.library.lastError ?? "")
            }
        }
    }

    @ViewBuilder private func albumsOrSongs(_ tracks: [Track]) -> some View {
        ForEach(app.library.albums(in: tracks)) { album in
            Section(album.name) {
                songRows(album.tracks)
            }
        }
    }

    @ViewBuilder private func songRows(_ tracks: [Track]) -> some View {
        ForEach(Array(tracks.prefix(3000).enumerated()), id: \.element.id) { index, track in
            Button { play(tracks, at: index) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1).foregroundStyle(.primary)
                        Text([track.artist, track.album, app.sources.config(track.sourceID)?.name].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let d = track.duration { Text(TimeFormat.clock(d)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .contextMenu {
                Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { app.player.playNext([track]) }
                Button("加入播放列表", systemImage: "text.badge.plus") { app.player.enqueue([track]); app.show("已加入") }
                Button("离线下载", systemImage: "arrow.down.circle") { offline(track) }
                Button("从曲库移除", systemImage: "trash", role: .destructive) { app.library.remove([track.id]) }
            }
        }
    }

    private func play(_ tracks: [Track], at index: Int) {
        app.player.setQueue(tracks, startAt: index)
        app.selection = []
        dismiss()
    }

    private func offline(_ track: Track) {
        guard let source = app.sources.source(track.sourceID) else { return }
        app.show("开始下载")
        Task {
            do { try await app.player.cache.makeOffline(track, source: source); app.show("下载完成") }
            catch { app.show("下载失败：\(error.localizedDescription)") }
        }
    }
}
