import AmplayerKit
import SwiftUI

// Subsonic / Navidrome 的曲库界面：首页（可自定义分类和顺序）、专辑封面墙、专辑 / 艺术家 / 播放列表详情、流派、年代、收藏、搜索。

// MARK: - 首页分类

enum SubsonicHomeSection: String, CaseIterable, Identifiable, Codable {
    case randomSongs, newest, recent, starred, playlists, artists, genres, frequent, randomAlbums, decades, highest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .randomSongs: "随机播放"
        case .newest: "最近添加"
        case .recent: "最近播放"
        case .starred: "我的收藏"
        case .playlists: "播放列表"
        case .artists: "艺术家"
        case .genres: "流派"
        case .frequent: "最常播放"
        case .randomAlbums: "随便听听"
        case .decades: "年代"
        case .highest: "评分最高"
        }
    }

    var symbol: String {
        switch self {
        case .randomSongs: "shuffle"
        case .newest: "sparkles"
        case .recent: "clock.arrow.circlepath"
        case .starred: "star"
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .frequent: "flame"
        case .randomAlbums: "die.face.5"
        case .decades: "calendar"
        case .highest: "hand.thumbsup"
        }
    }

    static let defaults: [Self] = [.randomSongs, .newest, .recent, .starred, .playlists, .artists, .genres, .frequent, .randomAlbums, .decades]

    /// 每个来源单独记首页布局
    static func load(for sourceID: String) -> [Self] {
        guard let raw = UserDefaults.standard.stringArray(forKey: key(sourceID)) else { return defaults }
        return raw.compactMap(Self.init(rawValue:))
    }

    static func save(_ sections: [Self], for sourceID: String) {
        UserDefaults.standard.set(sections.map(\.rawValue), forKey: key(sourceID))
    }

    private static func key(_ sourceID: String) -> String { "amplayer.subsonicHome.\(sourceID)" }
}

// MARK: - 公共小工具

/// 拿到 Subsonic 来源、播放歌曲
@MainActor
private struct SubsonicContext {
    let app: AppModel
    let sourceID: String

    var source: SubsonicSource? { app.sources.source(sourceID) as? SubsonicSource }

    func play(_ items: [SourceItem], from index: Int = 0, shuffle: Bool = false) {
        guard !items.isEmpty else { return }
        var tracks = items.map { $0.makeTrack(sourceID: sourceID) }
        var start = min(max(index, 0), tracks.count - 1)
        if shuffle {
            tracks.shuffle()
            start = 0
        }
        app.player.setQueue(tracks, startAt: start)
        // 开始播放后收起页面，回到播放器
        app.sheet = nil
    }

    func playNext(_ items: [SourceItem]) {
        app.player.playNext(items.map { $0.makeTrack(sourceID: sourceID) })
        app.show(items.count == 1 ? "下一首播放" : "\(items.count) 首将接着播放")
    }

    func enqueue(_ items: [SourceItem]) {
        app.player.enqueue(items.map { $0.makeTrack(sourceID: sourceID) })
        app.show("已加入播放列表 \(items.count) 首")
    }

    func isPlaying(_ item: SourceItem) -> Bool {
        app.player.current?.sourceID == sourceID && app.player.current?.path == item.path
    }
}

/// 封面缓存：内存 + 磁盘（Caches/covers），同一张图同时只下载一次
@MainActor
final class CoverArtCache {
    static let shared = CoverArtCache()
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    func cached(_ key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    func image(source: SubsonicSource, id: String, size: Int) async -> UIImage? {
        let key = Self.key(source.config.id, id, size)
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = inflight[key] { return await task.value }
        let file = folder.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image.preparingForDisplay() ?? image }
            guard let data = try? await source.coverArt(id: id, size: size), let image = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return image.preparingForDisplay() ?? image
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    static func key(_ sourceID: String, _ id: String, _ size: Int) -> String { "\(sourceID)-\(id)-\(size)" }
}

/// 封面：加载前显示按 id 上色的占位
struct CoverArt: View {
    let source: SubsonicSource?
    let id: String?
    var size: Int = 300
    var corner: CGFloat = 8
    var symbol = "music.note"
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(placeholder)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .task(id: id) {
                guard let source, let id else { return }
                if let hit = CoverArtCache.shared.cached(CoverArtCache.key(source.config.id, id, size)) { image = hit; return }
                image = await CoverArtCache.shared.image(source: source, id: id, size: size)
            }
            .accessibilityHidden(true)
    }

    private var placeholder: LinearGradient {
        let hue = Double(abs((id ?? "").hashValue) % 360) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.32), Color(hue: hue, saturation: 0.45, brightness: 0.2)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 自动换行排列（流派、年代标签）
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxWidth), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

private struct Chip: View {
    let text: String
    var detail: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.subheadline)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Color(white: 0.17), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
    }
}

private struct ShelfHeader<Destination: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            NavigationLink(destination: destination) {
                HStack(spacing: 2) {
                    Text("全部")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 18)
    }
}

private func durationText(_ seconds: TimeInterval?) -> String? {
    guard let seconds, seconds > 0 else { return nil }
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(max(1, minutes)) 分钟"
}

/// 专辑卡片：封面 + 名称 + 艺术家
struct AlbumCard: View {
    let source: SubsonicSource?
    let album: SubsonicAlbum
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverArt(source: source, id: album.coverArt, size: 300)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: width)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

private struct SongRow: View {
    let item: SourceItem
    var number: Int?
    var showArtist = true
    var playing = false

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if playing { Image(systemName: "speaker.wave.2.fill").font(.caption) } else { Text("\(number)") }
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(playing ? Color.accentColor : .secondary)
                .frame(minWidth: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? item.name).lineLimit(1)
                    .foregroundStyle(playing ? Color.accentColor : .primary)
                if showArtist, let artist = item.artist {
                    Text([artist, item.album].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let d = item.duration {
                Text(TimeFormat.clock(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 播放 / 随机播放两个大按钮
private struct PlayButtons: View {
    let disabled: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button(action: shuffle) {
                Label("随机播放", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(disabled)
    }
}

// MARK: - 首页

struct SubsonicHomeView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let title: String

    @State private var sections: [SubsonicHomeSection] = []
    @State private var query = ""
    @State private var editing = false
    @State private var showFolders = false
    @State private var reload = 0
    @State private var linkedArtist: String?
    @State private var showArtistList = false

    private var ctx: SubsonicContext { SubsonicContext(app: app, sourceID: sourceID) }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        QuickLinks(sourceID: sourceID)
                        ForEach(sections) { section in
                            shelf(section).id("\(section.rawValue)-\(reload)")
                        }
                        Button { editing = true } label: {
                            Label("编辑首页", systemImage: "slider.horizontal.3")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .padding(.horizontal, 18)
                    }
                    .padding(.vertical, 12)
                }
                .refreshable { reload += 1 }
            } else {
                SubsonicSearchResults(sourceID: sourceID, query: query)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索艺术家、专辑、歌曲")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("编辑首页", systemImage: "slider.horizontal.3") { editing = true }
                    Button("按目录浏览", systemImage: "folder") { showFolders = true }
                    Button("扫描到曲库", systemImage: "square.and.arrow.down.on.square") {
                        if let source = ctx.source { app.library.scan(source, path: source.rootPath); app.show("开始扫描 \(title)") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(isPresented: $showFolders) {
            BrowserView(target: BrowseTarget(sourceID: sourceID, path: nil, title: title))
        }
        .sheet(isPresented: $editing) {
            SubsonicHomeEditor(sections: $sections) { SubsonicHomeSection.save($0, for: sourceID) }
        }
        .onAppear {
            if sections.isEmpty { sections = SubsonicHomeSection.load(for: sourceID) }
            if let link = app.pendingArtist, link.sourceID == sourceID {
                app.pendingArtist = nil
                if let name = link.name { linkedArtist = name } else { showArtistList = true }
            }
        }
        .navigationDestination(isPresented: Binding(get: { linkedArtist != nil }, set: { if !$0 { linkedArtist = nil } })) {
            if let linkedArtist { ArtistLinkResolver(sourceID: sourceID, name: linkedArtist) }
        }
        .navigationDestination(isPresented: $showArtistList) { ArtistListView(sourceID: sourceID) }
        #if DEBUG
        // 截图用：-DebugSubsonicPage album / artists / genres / search:关键词
        .navigationDestination(isPresented: $debugPage) { debugDestination }
        .task {
            guard let page = UserDefaults.standard.string(forKey: "DebugSubsonicPage") else { return }
            if page.hasPrefix("search:") { query = String(page.dropFirst(7)); return }
            if page == "editor" { editing = true; return }
            guard ["album", "artists", "genres", "artist"].contains(page) else { return }
            if page == "album" { debugAlbum = try? await ctx.source?.albums(.newest, size: 1).first }
            debugPage = true
        }
        #endif
    }

    #if DEBUG
    @State private var debugPage = false
    @State private var debugAlbum: SubsonicAlbum?
    @ViewBuilder private var debugDestination: some View {
        switch UserDefaults.standard.string(forKey: "DebugSubsonicPage") {
        case "album": if let debugAlbum { AlbumDetailView(sourceID: sourceID, album: debugAlbum) }
        case "artists": ArtistListView(sourceID: sourceID)
        case "artist": ArtistLinkResolver(sourceID: sourceID, name: "张学友")
        case "genres": GenreListView(sourceID: sourceID)
        default: EmptyView()
        }
    }
    #endif

    @ViewBuilder
    private func shelf(_ section: SubsonicHomeSection) -> some View {
        switch section {
        case .randomSongs: RandomSongsCard(sourceID: sourceID)
        case .newest: AlbumShelf(sourceID: sourceID, title: section.title, list: .newest)
        case .recent: AlbumShelf(sourceID: sourceID, title: section.title, list: .recent)
        case .frequent: AlbumShelf(sourceID: sourceID, title: section.title, list: .frequent)
        case .randomAlbums: AlbumShelf(sourceID: sourceID, title: section.title, list: .random)
        case .highest: AlbumShelf(sourceID: sourceID, title: section.title, list: .highest)
        case .starred: StarredShelf(sourceID: sourceID)
        case .playlists: PlaylistShelf(sourceID: sourceID)
        case .artists: ArtistShelf(sourceID: sourceID)
        case .genres: GenreShelf(sourceID: sourceID)
        case .decades: DecadeShelf(sourceID: sourceID)
        }
    }
}

/// 首页顶部的快捷入口：歌手、专辑、播放列表、流派、收藏
private struct QuickLinks: View {
    let sourceID: String

    var body: some View {
        HStack(spacing: 10) {
            tile("歌手", "music.mic", Color(red: 0.95, green: 0.35, blue: 0.4)) { ArtistListView(sourceID: sourceID) }
            tile("专辑", "square.stack", Color(red: 0.3, green: 0.6, blue: 0.98)) { AlbumGridView(sourceID: sourceID, title: "全部专辑", list: .alphabetical) }
            tile("歌单", "music.note.list", Color(red: 0.55, green: 0.4, blue: 0.95)) { PlaylistListView(sourceID: sourceID) }
            tile("流派", "guitars", Color(red: 0.2, green: 0.72, blue: 0.55)) { GenreListView(sourceID: sourceID) }
            tile("收藏", "star.fill", Color(red: 0.98, green: 0.7, blue: 0.2)) { StarredView(sourceID: sourceID) }
        }
        .padding(.horizontal, 18)
    }

    private func tile<D: View>(_ title: String, _ symbol: String, _ color: Color, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 一键随机播放整个曲库
private struct RandomSongsCard: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var loading = false

    var body: some View {
        Button {
            Task {
                loading = true
                defer { loading = false }
                let ctx = SubsonicContext(app: app, sourceID: sourceID)
                do {
                    let songs = try await ctx.source?.randomSongs(size: 100) ?? []
                    ctx.play(songs)
                    app.show("随机播放 \(songs.count) 首")
                } catch {
                    app.show(error.localizedDescription)
                }
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.2))
                    if loading { ProgressView().tint(.white) } else {
                        Image(systemName: "shuffle").font(.system(size: 20, weight: .bold))
                    }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("随机播放").font(.headline)
                    Text("从整个曲库随机挑 100 首").font(.caption).opacity(0.85)
                }
                Spacer()
                Image(systemName: "play.fill").font(.title3)
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(
                LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .padding(.horizontal, 18)
    }
}

/// 横向滚动的专辑一排
private struct AlbumShelf: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let title: String
    let list: SubsonicAlbumList
    @State private var albums: [SubsonicAlbum]?
    @State private var error: String?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        Group {
            if let albums, albums.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: title) { AlbumGridView(sourceID: sourceID, title: title, list: list) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 18)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            if let albums {
                                ForEach(albums) { album in
                                    NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                                        AlbumCard(source: ctx.source, album: album, width: 140)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else if error == nil {
                                ForEach(0..<4, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15)).frame(width: 140, height: 180)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task {
            guard albums == nil else { return }
            do { albums = try await ctx.source?.albums(list, size: 20) ?? [] } catch { self.error = error.localizedDescription }
        }
    }
}

private struct StarredShelf: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var starred: SubsonicResults?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        Group {
            if let starred, !starred.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: "我的收藏", subtitle: summary(starred)) { StarredView(sourceID: sourceID) }
                    if !starred.albums.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(starred.albums) { album in
                                    NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                                        AlbumCard(source: ctx.source, album: album, width: 140)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                        .scrollIndicators(.hidden)
                    }
                    if !starred.songs.isEmpty {
                        Button { ctx.play(starred.songs) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    .frame(width: 40, height: 40)
                                    .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("播放收藏的歌曲").font(.subheadline.weight(.semibold))
                                    Text("\(starred.songs.count) 首").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                            }
                            .padding(12)
                            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                    }
                }
            }
        }
        .task {
            guard starred == nil else { return }
            starred = (try? await ctx.source?.starred()) ?? SubsonicResults()
        }
    }

    private func summary(_ r: SubsonicResults) -> String {
        [r.albums.isEmpty ? nil : "\(r.albums.count) 张专辑", r.songs.isEmpty ? nil : "\(r.songs.count) 首歌", r.artists.isEmpty ? nil : "\(r.artists.count) 位艺术家"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct PlaylistShelf: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var playlists: [SubsonicPlaylist]?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        Group {
            if let playlists, !playlists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: "播放列表") { PlaylistListView(sourceID: sourceID) }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(playlists) { playlist in
                                NavigationLink { PlaylistDetailView(sourceID: sourceID, playlist: playlist) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverArt(source: ctx.source, id: playlist.coverArt, size: 300, symbol: "music.note.list")
                                            .frame(width: 140, height: 140)
                                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                                        Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text("\(playlist.songCount ?? 0) 首").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 140)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task {
            guard playlists == nil else { return }
            playlists = (try? await ctx.source?.playlists()) ?? []
        }
    }
}

private struct ArtistShelf: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var index: [SubsonicArtistIndex]?
    @State private var sample: [SubsonicArtist] = []

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        Group {
            if let index, !index.isEmpty {
                let total = index.reduce(0) { $0 + $1.artists.count }
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: "艺术家", subtitle: "共 \(total) 位") { ArtistListView(sourceID: sourceID, preloaded: index) }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(sample) { artist in
                                NavigationLink { ArtistDetailView(sourceID: sourceID, artist: artist) } label: {
                                    VStack(spacing: 6) {
                                        CoverArt(source: ctx.source, id: artist.coverArt, size: 200, corner: 44, symbol: "music.mic")
                                            .frame(width: 88, height: 88)
                                        Text(artist.name).font(.caption).lineLimit(1)
                                    }
                                    .frame(width: 92)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task {
            guard index == nil else { return }
            let loaded = (try? await ctx.source?.artistIndex()) ?? []
            // 首页挑专辑多的艺术家展示
            sample = Array(loaded.flatMap(\.artists).sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }.prefix(16))
            index = loaded
        }
    }
}

private struct GenreShelf: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var genres: [SubsonicGenre]?

    var body: some View {
        Group {
            if let genres, !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: "流派", subtitle: "共 \(genres.count) 种") { GenreListView(sourceID: sourceID, preloaded: genres) }
                    ChipFlow {
                        ForEach(genres.prefix(14)) { genre in
                            NavigationLink { AlbumGridView(sourceID: sourceID, title: genre.name, list: .genre(genre.name)) } label: {
                                Chip(text: genre.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
        .task {
            guard genres == nil else { return }
            genres = (try? await SubsonicContext(app: app, sourceID: sourceID).source?.genres()) ?? []
        }
    }
}

private struct DecadeShelf: View {
    let sourceID: String
    private let decades = [2020, 2010, 2000, 1990, 1980, 1970, 1960]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("年代").font(.title3.weight(.bold)).padding(.horizontal, 18)
            ChipFlow {
                ForEach(decades, id: \.self) { decade in
                    NavigationLink {
                        AlbumGridView(sourceID: sourceID, title: "\(decade) 年代", list: .years(decade + 9, decade))
                    } label: {
                        Chip(text: decade >= 2000 ? "\(decade) 年代" : "\(decade % 100) 年代")
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    AlbumGridView(sourceID: sourceID, title: "更早", list: .years(1959, 1900))
                } label: {
                    Chip(text: "更早")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - 专辑墙

struct AlbumGridView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let title: String
    let list: SubsonicAlbumList

    @State private var albums: [SubsonicAlbum] = []
    @State private var loading = false
    @State private var finished = false
    @State private var error: String?
    private let page = 40

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 22) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                        AlbumCard(source: ctx.source, album: album)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if album.id == albums.last?.id { Task { await loadMore() } } }
                }
            }
            .padding(18)
            if loading { ProgressView().padding() }
        }
        .overlay {
            if let error, albums.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("重试") { Task { await loadMore() } }
                }
            } else if finished, albums.isEmpty {
                ContentUnavailableView("这里还没有专辑", systemImage: "square.stack")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if case .random = list {
                    Button("换一批", systemImage: "arrow.clockwise") {
                        albums = []
                        finished = false
                        Task { await loadMore() }
                    }
                }
            }
        }
        .task { if albums.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !finished, let source = SubsonicContext(app: app, sourceID: sourceID).source else { return }
        loading = true
        defer { loading = false }
        do {
            let more = try await source.albums(list, size: page, offset: list.isPaged ? albums.count : 0)
            let known = Set(albums.map(\.id))
            albums += more.filter { !known.contains($0.id) }
            error = nil
            if more.count < page || !list.isPaged { finished = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 专辑详情

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State var album: SubsonicAlbum
    @State private var songs: [SourceItem]?
    @State private var error: String?
    @State private var showArtist = false

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        List {
            VStack(spacing: 14) {
                CoverArt(source: ctx.source, id: album.coverArt, size: 600, corner: 12)
                    .frame(width: 230, height: 230)
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                VStack(spacing: 5) {
                    Text(album.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    if let artist = album.artist {
                        if album.artistID != nil {
                            // 列表里的 NavigationLink 会变成整行，用按钮 + navigationDestination
                            Button { showArtist = true } label: {
                                Text(artist).font(.title3).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Text(artist).font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                PlayButtons(disabled: (songs ?? []).isEmpty) {
                    ctx.play(songs ?? [])
                } shuffle: {
                    ctx.play(songs ?? [], shuffle: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if let songs {
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                    Button { ctx.play(songs, from: i) } label: {
                        SongRow(item: song, number: song.trackNumber ?? i + 1,
                                showArtist: song.artist != nil && song.artist != album.artist,
                                playing: ctx.isPlaying(song))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { songMenu(ctx, song) }
                    .swipeActions { swipe(ctx, song) }
                }
                if !songs.isEmpty {
                    Text("\(songs.count) 首" + (durationText(album.duration).map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationDestination(isPresented: $showArtist) {
            if let id = album.artistID {
                ArtistDetailView(sourceID: sourceID, artist: SubsonicArtist(id: id, name: album.artist ?? ""))
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("下一首播放", systemImage: "text.insert") { ctx.playNext(songs ?? []) }
                    Button("加入播放列表", systemImage: "text.badge.plus") { ctx.enqueue(songs ?? []) }
                    Button(album.starred ? "取消收藏" : "收藏专辑", systemImage: album.starred ? "star.slash" : "star") {
                        Task { await toggleStar(ctx) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(songs == nil)
            }
        }
        .task {
            guard songs == nil else { return }
            do {
                let detail = try await ctx.source?.album(id: album.id)
                if let detail { album = detail.album; songs = detail.songs } else { songs = [] }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var meta: String {
        [album.genre, album.year.map(String.init), album.songCount.map { "\($0) 首" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func toggleStar(_ ctx: SubsonicContext) async {
        do {
            try await ctx.source?.setStarred(!album.starred, albumID: album.id)
            album.starred.toggle()
            app.show(album.starred ? "已收藏" : "已取消收藏")
        } catch {
            app.show(error.localizedDescription)
        }
    }
}

@MainActor @ViewBuilder
private func songMenu(_ ctx: SubsonicContext, _ song: SourceItem) -> some View {
    Button("下一首播放", systemImage: "text.insert") { ctx.playNext([song]) }
    Button("加入播放列表", systemImage: "text.badge.plus") { ctx.enqueue([song]) }
    if song.path.hasPrefix("song/") {
        Button("收藏", systemImage: "star") {
            Task {
                do {
                    try await ctx.source?.setStarred(true, songID: String(song.path.dropFirst(5)))
                    ctx.app.show("已收藏")
                } catch {
                    ctx.app.show(error.localizedDescription)
                }
            }
        }
    }
}

@MainActor @ViewBuilder
private func swipe(_ ctx: SubsonicContext, _ song: SourceItem) -> some View {
    Button("加入") { ctx.enqueue([song]) }.tint(.green)
    Button("下一首") { ctx.playNext([song]) }.tint(Color.accentColor)
}

// MARK: - 艺术家

/// 艺术家：“热门”头像墙（按专辑数）和“A–Z”列表（右侧字母条快速定位），顶部可筛选
struct ArtistListView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    var preloaded: [SubsonicArtistIndex]?
    @State private var index: [SubsonicArtistIndex]?
    @State private var query = ""
    @State private var mode = Mode.popular
    @State private var activeLetter: String?

    enum Mode: String, CaseIterable { case popular = "热门", all = "A–Z" }

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        Group {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty || mode == .all {
                alphabetical(ctx)
            } else {
                popular(ctx)
            }
        }
        .safeAreaInset(edge: .top) {
            if query.isEmpty {
                Picker("显示", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .overlay { if index == nil { ProgressView() } }
        .searchable(text: $query, prompt: "筛选艺术家")
        .navigationTitle(index.map { "艺术家（\($0.reduce(0) { $0 + $1.artists.count })）" } ?? "艺术家")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "DebugArtistMode") == "az" { mode = .all }
            #endif
            if index == nil { index = preloaded }
            if index == nil { index = (try? await ctx.source?.artistIndex()) ?? [] }
        }
    }

    /// 专辑最多的 90 位，头像网格
    private func popular(_ ctx: SubsonicContext) -> some View {
        let top = (index ?? []).flatMap(\.artists).sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }.prefix(90)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 18) {
                ForEach(Array(top)) { artist in
                    NavigationLink { ArtistDetailView(sourceID: sourceID, artist: artist) } label: {
                        VStack(spacing: 6) {
                            CoverArt(source: ctx.source, id: artist.coverArt, size: 240, corner: 50, symbol: "music.mic")
                                .aspectRatio(1, contentMode: .fit)
                                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                            Text(artist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            if let n = artist.albumCount, n > 0 {
                                Text("\(n) 张专辑").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
    }

    private func alphabetical(_ ctx: SubsonicContext) -> some View {
        let groups = filtered
        return ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(Array(group.artists.enumerated()), id: \.element.id) { i, artist in
                            NavigationLink { ArtistDetailView(sourceID: sourceID, artist: artist) } label: {
                                HStack(spacing: 12) {
                                    CoverArt(source: ctx.source, id: artist.coverArt, size: 120, corner: 22, symbol: "music.mic")
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist.name)
                                        if let n = artist.albumCount, n > 0 { Text("\(n) 张专辑").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .id(i == 0 ? "letter-\(group.name)" : artist.id)
                        }
                    } header: {
                        Text(group.name)
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.trailing, query.isEmpty && groups.count > 5 ? 20 : 0, for: .scrollContent)
            .overlay(alignment: .trailing) {
                if query.isEmpty, groups.count > 5 {
                    LetterBar(letters: groups.map(\.name), active: $activeLetter) { letter in
                        proxy.scrollTo("letter-\(letter)", anchor: .top)
                    }
                    .padding(.trailing, 2)
                }
            }
            .overlay {
                if let activeLetter {
                    Text(activeLetter)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .frame(width: 88, height: 88)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var filtered: [SubsonicArtistIndex] {
        guard let index else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return index }
        return index.compactMap { group in
            let hits = group.artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
            return hits.isEmpty ? nil : SubsonicArtistIndex(name: group.name, artists: hits)
        }
    }
}

/// 右侧竖排字母条：点或滑动到某个字母就跳过去
private struct LetterBar: View {
    let letters: [String]
    @Binding var active: String?
    let onSelect: (String) -> Void
    @State private var lastHaptic: String?

    var body: some View {
        GeometryReader { geo in
            let rowHeight = min(18, geo.size.height / CGFloat(max(letters.count, 1)))
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active == letter ? Color.primary : Color.accentColor)
                        .frame(width: 22, height: rowHeight)
                }
            }
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.12).opacity(active == nil ? 0 : 0.85)))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let total = rowHeight * CGFloat(letters.count)
                        let top = (geo.size.height - total) / 2
                        let i = Int((value.location.y - top) / rowHeight)
                        let letter = letters[min(max(i, 0), letters.count - 1)]
                        if letter != active {
                            active = letter
                            onSelect(letter)
                            if letter != lastHaptic { UISelectionFeedbackGenerator().selectionChanged(); lastHaptic = letter }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.3)) { active = nil }
                        lastHaptic = nil
                    }
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 26)
        .accessibilityHidden(true)
    }
}

/// 艺术家详情：专辑 / 全部歌曲两页；歌曲页可以在这位艺术家的歌里搜索
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State var artist: SubsonicArtist
    @State private var albums: [SubsonicAlbum]?
    @State private var songs: [SourceItem] = []
    /// 歌曲页按专辑分组显示（单曲一组、每张专辑一组），songs 是展开后的播放顺序
    @State private var groups: [SongGroup] = []
    /// 歌曲页：已载入几张专辑的歌
    @State private var loadedAlbums = 0
    @State private var songsLoading = false
    @State private var tab = Tab.albums
    @State private var query = ""
    @State private var error: String?

    enum Tab: Hashable { case albums, songs }

    struct SongGroup: Identifiable {
        let id: String
        let album: SubsonicAlbum?
        let songs: [SourceItem]
    }

    private var shownGroups: [SongGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            let hits = g.songs.filter { ($0.title ?? $0.name).localizedCaseInsensitiveContains(q) || ($0.album?.localizedCaseInsensitiveContains(q) ?? false) }
            return hits.isEmpty ? nil : SongGroup(id: g.id, album: g.album, songs: hits)
        }
    }

    private var shownSongs: [SourceItem] { shownGroups.flatMap(\.songs) }

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        ScrollView {
            VStack(spacing: 14) {
                CoverArt(source: ctx.source, id: artist.coverArt, size: 400, corner: 75, symbol: "music.mic")
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                Text(artist.name).font(.title.weight(.bold)).multilineTextAlignment(.center)
                if let albums {
                    Text([albums.isEmpty ? nil : "\(albums.count) 张专辑", songs.isEmpty || songsLoading ? nil : "\(songs.count) 首歌"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                PlayButtons(disabled: (albums ?? []).isEmpty && songs.isEmpty) {
                    Task { await play(ctx, shuffle: false) }
                } shuffle: {
                    Task { await play(ctx, shuffle: true) }
                }
                if let albums, !albums.isEmpty {
                    Picker("显示", selection: $tab) {
                        Text("专辑").tag(Tab.albums)
                        Text("全部歌曲").tag(Tab.songs)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding()
            }
            if tab == .albums, let albums, !albums.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 22) {
                    ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                            AlbumCard(source: ctx.source, album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            } else if albums != nil {
                songList(ctx)
            }
            if albums == nil, error == nil { ProgressView().padding() }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索\(artist.name)的歌")
        .onChange(of: query) { _, q in if !q.isEmpty { tab = .songs } }
        .onChange(of: tab) { _, t in if t == .songs { Task { await loadSongs(ctx) } } }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard albums == nil else { return }
            do {
                if let detail = try await ctx.source?.artist(id: artist.id) {
                    artist = detail.artist
                    albums = detail.albums
                    #if DEBUG
                    if UserDefaults.standard.string(forKey: "DebugArtistMode") == "songs" { tab = .songs }
                    #endif
                    // 只在别人专辑里出现的艺术家：直接按名字找歌
                    if detail.albums.isEmpty {
                        tab = .songs
                        let found = try await ctx.source?.search(artist.name, artists: 0, albums: 0, songs: 300).songs ?? []
                        songs = found.filter { $0.artist?.localizedCaseInsensitiveContains(artist.name) == true }
                        groups = [SongGroup(id: "search", album: nil, songs: songs)]
                    }
                } else { albums = [] }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func songList(_ ctx: SubsonicContext) -> some View {
        let shown = shownGroups
        let list = shown.flatMap(\.songs)
        // 每组第一首在 list 里的位置，点歌时从整份列表的这一首开始放
        let starts = shown.reduce(into: [Int]()) { acc, g in acc.append((acc.last ?? 0) + (acc.isEmpty ? 0 : shown[acc.count - 1].songs.count)) }
        LazyVStack(alignment: .leading, spacing: 0) {
            if songsLoading, let albums {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在载入 \(loadedAlbums)/\(albums.count) 张专辑的歌…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
            if !query.isEmpty, list.isEmpty, !songsLoading {
                Text("没有找到“\(query)”").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { g, group in
                if let album = group.album {
                    NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                        HStack(spacing: 10) {
                            CoverArt(source: ctx.source, id: album.coverArt, size: 120, corner: 6)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text([album.year.map(String.init), "\(group.songs.count) 首"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.top, g == 0 ? 4 : 22)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // 真实专辑用音轨号；单曲组（各自来自不同文件）按顺序编号
                let useTrackNumbers = group.album.map { !$0.id.hasPrefix("as-") && !$0.name.hasSuffix("单曲") } ?? false
                ForEach(Array(group.songs.enumerated()), id: \.offset) { i, song in
                    Button { ctx.play(list, from: starts[g] + i) } label: {
                        SongRow(item: song, number: useTrackNumbers ? (song.trackNumber ?? i + 1) : i + 1, showArtist: song.artist != artist.name, playing: ctx.isPlaying(song))
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { songMenu(ctx, song) }
                    Divider()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    /// 逐张专辑取歌：先到先显示，最终按专辑顺序（新专辑在前）排好
    private func loadSongs(_ ctx: SubsonicContext) async {
        guard !songsLoading, songs.isEmpty, let source = ctx.source, let albums, !albums.isEmpty else { return }
        songsLoading = true
        defer { songsLoading = false }
        loadedAlbums = 0
        var byIndex: [Int: [SourceItem]] = [:]
        await withTaskGroup(of: (Int, [SourceItem]).self) { group in
            var next = 0
            // 同时最多 6 个请求，专辑多的歌手也不会把服务器压垮
            for _ in 0..<min(6, albums.count) {
                let i = next, id = albums[i].id
                group.addTask { (i, (try? await source.album(id: id).songs) ?? []) }
                next += 1
            }
            for await (i, list) in group {
                byIndex[i] = list
                loadedAlbums += 1
                if loadedAlbums % 10 == 0 || loadedAlbums == albums.count {
                    setGroups(albums, byIndex)
                }
                if next < albums.count {
                    let j = next, id = albums[j].id
                    group.addTask { (j, (try? await source.album(id: id).songs) ?? []) }
                    next += 1
                }
            }
        }
        setGroups(albums, byIndex)
    }

    private func setGroups(_ albums: [SubsonicAlbum], _ byIndex: [Int: [SourceItem]]) {
        groups = albums.indices.compactMap { i in
            guard let list = byIndex[i], !list.isEmpty else { return nil }
            return SongGroup(id: albums[i].id, album: albums[i], songs: list)
        }
        songs = groups.flatMap(\.songs)
    }

    private func play(_ ctx: SubsonicContext, shuffle: Bool) async {
        if songs.isEmpty { await loadSongs(ctx) }
        let list = shownSongs
        ctx.play(list, shuffle: shuffle)
        app.show("\(shuffle ? "随机播放" : "播放") \(artist.name) 的 \(list.count) 首歌")
    }
}

/// 从别处（播放列表、菜单）跳到某位歌手：按名字在服务器上找到这位艺术家再打开
struct ArtistLinkResolver: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let name: String
    @State private var artist: SubsonicArtist?
    @State private var failed = false

    var body: some View {
        Group {
            if let artist {
                ArtistDetailView(sourceID: sourceID, artist: artist)
            } else if failed {
                ContentUnavailableView("找不到歌手", systemImage: "music.mic", description: Text("服务器上没有“\(name)”"))
            } else {
                ProgressView()
            }
        }
        .task {
            guard artist == nil else { return }
            let source = SubsonicContext(app: app, sourceID: sourceID).source
            let found = (try? await source?.search(name, artists: 20, albums: 0, songs: 0).artists) ?? []
            if let hit = found.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? found.first {
                artist = hit
            } else {
                failed = true
            }
        }
    }
}

// MARK: - 播放列表

struct PlaylistListView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var playlists: [SubsonicPlaylist]?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        List(playlists ?? []) { playlist in
            NavigationLink { PlaylistDetailView(sourceID: sourceID, playlist: playlist) } label: {
                HStack(spacing: 12) {
                    CoverArt(source: ctx.source, id: playlist.coverArt, size: 120, corner: 6, symbol: "music.note.list")
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                        Text(["\(playlist.songCount ?? 0) 首", durationText(playlist.duration)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if playlists == nil { ProgressView() }
            else if playlists?.isEmpty == true { ContentUnavailableView("没有播放列表", systemImage: "music.note.list") }
        }
        .navigationTitle("播放列表")
        .navigationBarTitleDisplayMode(.inline)
        .task { if playlists == nil { playlists = (try? await ctx.source?.playlists()) ?? [] } }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let playlist: SubsonicPlaylist
    @State private var songs: [SourceItem]?
    @State private var error: String?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        SongCollection(ctx: ctx, songs: songs, error: error) {
            VStack(spacing: 14) {
                CoverArt(source: ctx.source, id: playlist.coverArt, size: 600, corner: 12, symbol: "music.note.list")
                    .frame(width: 210, height: 210)
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                Text(playlist.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text(["\(playlist.songCount ?? songs?.count ?? 0) 首", durationText(playlist.duration), playlist.owner].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard songs == nil else { return }
            do { songs = try await ctx.source?.playlist(id: playlist.id).songs ?? [] } catch { self.error = error.localizedDescription }
        }
    }
}

/// 一组歌：顶部信息 + 播放按钮 + 歌曲列表
private struct SongCollection<Header: View>: View {
    let ctx: SubsonicContext
    let songs: [SourceItem]?
    let error: String?
    @ViewBuilder var header: () -> Header

    var body: some View {
        List {
            VStack(spacing: 14) {
                header()
                PlayButtons(disabled: (songs ?? []).isEmpty) { ctx.play(songs ?? []) } shuffle: { ctx.play(songs ?? [], shuffle: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            if let songs {
                ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                    Button { ctx.play(songs, from: i) } label: {
                        SongRow(item: song, number: i + 1, playing: ctx.isPlaying(song))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { songMenu(ctx, song) }
                    .swipeActions { swipe(ctx, song) }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 收藏、流派

struct StarredView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var starred: SubsonicResults?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        SongCollection(ctx: ctx, songs: starred?.songs, error: nil) {
            VStack(spacing: 12) {
                Image(systemName: "star.fill").font(.system(size: 44)).foregroundStyle(.yellow)
                    .frame(width: 110, height: 110)
                    .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                Text("我的收藏").font(.title2.weight(.bold))
                if let starred, !starred.albums.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(starred.albums) { album in
                                NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                                    AlbumCard(source: ctx.source, album: album, width: 120)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task { if starred == nil { starred = (try? await ctx.source?.starred()) ?? SubsonicResults() } }
    }
}

struct GenreListView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    var preloaded: [SubsonicGenre]?
    @State private var genres: [SubsonicGenre]?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        List(genres ?? []) { genre in
            NavigationLink { AlbumGridView(sourceID: sourceID, title: genre.name, list: .genre(genre.name)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(genre.name)
                    Text("\(genre.albumCount) 张专辑 · \(genre.songCount) 首").font(.caption).foregroundStyle(.secondary)
                }
            }
            .swipeActions {
                Button("随机播放") {
                    Task {
                        let songs = (try? await ctx.source?.randomSongs(size: 100, genre: genre.name)) ?? []
                        ctx.play(songs)
                        app.show("随机播放 \(genre.name) \(songs.count) 首")
                    }
                }
                .tint(Color.accentColor)
            }
        }
        .listStyle(.plain)
        .overlay { if genres == nil { ProgressView() } }
        .navigationTitle("流派")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if genres == nil { genres = preloaded }
            if genres == nil { genres = (try? await ctx.source?.genres()) ?? [] }
        }
    }
}

// MARK: - 搜索

private struct SubsonicSearchResults: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let query: String
    @State private var results: SubsonicResults?
    @State private var error: String?

    var body: some View {
        let ctx = SubsonicContext(app: app, sourceID: sourceID)
        List {
            if let results {
                if !results.artists.isEmpty {
                    Section("艺术家") {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 16) {
                                ForEach(results.artists) { artist in
                                    NavigationLink { ArtistDetailView(sourceID: sourceID, artist: artist) } label: {
                                        VStack(spacing: 6) {
                                            CoverArt(source: ctx.source, id: artist.coverArt, size: 200, corner: 36, symbol: "music.mic")
                                                .frame(width: 72, height: 72)
                                            Text(artist.name).font(.caption).lineLimit(1)
                                        }
                                        .frame(width: 80)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                if !results.albums.isEmpty {
                    Section("专辑") {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(results.albums) { album in
                                    NavigationLink { AlbumDetailView(sourceID: sourceID, album: album) } label: {
                                        AlbumCard(source: ctx.source, album: album, width: 120)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                if !results.songs.isEmpty {
                    Section("歌曲") {
                        ForEach(Array(results.songs.enumerated()), id: \.offset) { i, song in
                            Button { ctx.play(results.songs, from: i) } label: {
                                SongRow(item: song, playing: ctx.isPlaying(song))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { songMenu(ctx, song) }
                            .swipeActions { swipe(ctx, song) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if let error {
                ContentUnavailableView("搜索失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if results == nil {
                ProgressView()
            } else if results?.isEmpty == true {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            // 停止输入 0.35 秒后再搜
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let found = try await ctx.source?.search(query.trimmingCharacters(in: .whitespaces)) ?? SubsonicResults()
                guard !Task.isCancelled else { return }
                results = found
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - 编辑首页

struct SubsonicHomeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var sections: [SubsonicHomeSection]
    let onSave: ([SubsonicHomeSection]) -> Void
    @State private var draft: [SubsonicHomeSection] = []

    private var hidden: [SubsonicHomeSection] { SubsonicHomeSection.allCases.filter { !draft.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draft) { section in
                        HStack(spacing: 12) {
                            Button { withAnimation { draft.removeAll { $0 == section } } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("隐藏\(section.title)")
                            Label(section.title, systemImage: section.symbol)
                        }
                    }
                    .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("首页显示")
                } footer: {
                    Text("按住右边的横线拖动可以调整顺序。")
                }
                if !hidden.isEmpty {
                    Section("未显示") {
                        ForEach(hidden) { section in
                            Button { withAnimation { draft.append(section) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.title3)
                                    Label(section.title, systemImage: section.symbol).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Button("恢复默认") { withAnimation { draft = SubsonicHomeSection.defaults } }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("编辑首页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        sections = draft
                        onSave(draft)
                        dismiss()
                    }
                }
            }
            .onAppear { draft = sections }
        }
    }
}
