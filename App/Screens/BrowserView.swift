import MP9Kit
import SwiftUI

/// 浏览某个来源的目录
struct BrowserView: View {
    @Environment(AppModel.self) private var app
    let target: BrowseTarget

    @State private var items: [SourceItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var collecting = false

    private var source: (any MediaSource)? { app.sources.source(target.sourceID) }
    private var path: String { target.path ?? source?.rootPath ?? "/" }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("重试") { Task { await load() } }
                }
            }
            ForEach(filtered) { item in
                switch item.kind {
                case .directory:
                    NavigationLink(value: BrowseTarget(sourceID: target.sourceID, path: item.path, title: item.name)) {
                        Label(item.name, systemImage: "folder")
                    }
                    .contextMenu { folderMenu(item) }
                    .swipeActions { Button("加入") { Task { await addFolder(item, play: false) } }.tint(.green) }
                case .audio:
                    Button { playFrom(item) } label: { audioRow(item) }
                        .contextMenu { audioMenu(item) }
                        .swipeActions {
                            Button("加入") { enqueue([item]) }.tint(.green)
                            Button("下一首") { app.player.playNext([item.makeTrack(sourceID: target.sourceID)]) }.tint(.orange)
                        }
                }
            }
        }
        .overlay {
            if loading { ProgressView() }
            else if items.isEmpty && error == nil { ContentUnavailableView("没有可播放的内容", systemImage: "music.note") }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "筛选")
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("播放本目录", systemImage: "play.fill") { playAll() }
                        .disabled(audioItems.isEmpty)
                    Button("本目录加入播放列表", systemImage: "text.badge.plus") { enqueue(audioItems) }
                        .disabled(audioItems.isEmpty)
                    Button("播放全部（含子目录）", systemImage: "play.square.stack") {
                        Task { await addFolder(SourceItem(path: path, name: target.title, kind: .directory), play: true) }
                    }
                    Button("扫描到曲库", systemImage: "square.and.arrow.down.on.square") {
                        if let source { app.library.scan(source, path: path); app.show("开始扫描") }
                    }
                } label: {
                    if collecting { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var filtered: [SourceItem] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    private var audioItems: [SourceItem] { filtered.filter { $0.kind == .audio } }

    private func audioRow(_ item: SourceItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? item.name).lineLimit(1)
                let detail = [item.artist, item.album, item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                    .compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let d = item.duration { Text(TimeFormat.clock(d)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder private func audioMenu(_ item: SourceItem) -> some View {
        Button("播放", systemImage: "play.fill") { playFrom(item) }
        Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { app.player.playNext([item.makeTrack(sourceID: target.sourceID)]) }
        Button("加入播放列表", systemImage: "text.badge.plus") { enqueue([item]) }
        Button("加入曲库", systemImage: "music.note.list") { app.library.add([item.makeTrack(sourceID: target.sourceID)]); app.show("已加入曲库") }
        Button("离线下载", systemImage: "arrow.down.circle") {
            let track = item.makeTrack(sourceID: target.sourceID)
            guard let source else { return }
            app.show("开始下载")
            Task {
                do { try await app.player.cache.makeOffline(track, source: source); app.show("下载完成") }
                catch { app.show("下载失败：\(error.localizedDescription)") }
            }
        }
    }

    @ViewBuilder private func folderMenu(_ item: SourceItem) -> some View {
        Button("播放整个文件夹", systemImage: "play.fill") { Task { await addFolder(item, play: true) } }
        Button("加入播放列表", systemImage: "text.badge.plus") { Task { await addFolder(item, play: false) } }
        Button("扫描到曲库", systemImage: "square.and.arrow.down.on.square") {
            if let source { app.library.scan(source, path: item.path); app.show("开始扫描 \(item.name)") }
        }
    }

    private func load() async {
        guard let source else { error = "来源不存在"; loading = false; return }
        loading = items.isEmpty
        do {
            items = try await source.list(path: path).sortedForBrowsing()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func playFrom(_ item: SourceItem) {
        let audio = audioItems
        let tracks = audio.map { $0.makeTrack(sourceID: target.sourceID) }
        let index = audio.firstIndex(of: item) ?? 0
        app.player.setQueue(tracks, startAt: index)
        app.selection = []
        app.sheet = nil
    }

    private func playAll() {
        app.player.setQueue(audioItems.map { $0.makeTrack(sourceID: target.sourceID) }, startAt: 0)
        app.selection = []
        app.sheet = nil
    }

    private func enqueue(_ items: [SourceItem]) {
        app.player.enqueue(items.map { $0.makeTrack(sourceID: target.sourceID) }, playIfIdle: false)
        app.show("已加入 \(items.count) 首")
    }

    private func addFolder(_ item: SourceItem, play: Bool) async {
        guard let source else { return }
        collecting = true
        defer { collecting = false }
        do {
            let tracks = try await source.collectTracks(path: item.path)
            guard !tracks.isEmpty else { app.show("没有找到音乐"); return }
            if play {
                app.player.setQueue(tracks, startAt: 0)
                app.selection = []
                app.sheet = nil
            } else {
                app.player.enqueue(tracks)
                app.show("已加入 \(tracks.count) 首")
            }
        } catch {
            app.show("读取失败：\(error.localizedDescription)")
        }
    }
}
