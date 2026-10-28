import AmplayerKit
import SwiftUI

/// 经典播放列表窗口：宽 275，高度随屏幕
struct PlaylistWindowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale
    /// 窗口高度（皮肤像素），至少 116
    let height: CGFloat

    @State private var isSaving = false
    @State private var playlistName = ""
    @State private var infoTrack: Track?
    /// 列表顶部那一行（双向绑定：滚动时更新，拖滑块时设置）
    @State private var topRow: Int?
    @State private var draggingScroll = false

    private var player: PlayerController { app.player }
    private let width: CGFloat = 275

    var body: some View {
        let style = skin.playlistStyle
        SkinCanvas(size: CGSize(width: width, height: height)) {
            frame
            Group {
                if app.showLyrics {
                    LyricsPanelView(style: style)
                } else {
                    trackList(style)
                        .overlay(alignment: .top) { if app.isSelecting { selectionBar } }
                        .overlay { if player.queue.isEmpty { emptyHint(style) } }
                }
            }
                .frame(width: (width - 12 - 20) * scale, height: (height - 20 - 38) * scale)
                .background(style.normalBackground.color)
                .at(12, 20)
            scrollbar.at(width - 15, 20)
            bottomControls
        }
        .alert("保存播放列表", isPresented: $isSaving) {
            TextField("名称", text: $playlistName)
            Button("保存") {
                do {
                    try app.library.savePlaylist(player.queue.tracks, name: playlistName)
                    app.show("已保存到 文件 › Amplayer › Playlists")
                } catch {
                    app.show("保存失败：\(error.localizedDescription)")
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $infoTrack) { track in
            TrackInfoView(track: track)
        }
    }

    // MARK: 边框

    private var frame: some View {
        let midH = height - 20 - 38
        let titleX = ((width - 100) / 2).rounded(.down)
        return Group {
            // 顶部：左角、平铺、标题、平铺、右角
            tiles(S.plTopTile, from: 25, to: titleX, y: 0)
            tiles(S.plTopTile, from: titleX + 100, to: width - 25, y: 0)
            SpriteView(S.plTopLeft)
            if app.showLyrics {
                lyricsTitle.at(titleX, 0)
            } else {
                SpriteView(S.plTitle).at(titleX, 0)
            }
            SpriteView(S.plTopRight).at(width - 25, 0)
            // 两侧
            ForEach(0..<Int((midH / 29).rounded(.up)), id: \.self) { i in
                SpriteView(S.plLeftTile).at(0, 20 + CGFloat(i) * 29)
                SpriteView(S.plRightTile).at(width - 20, 20 + CGFloat(i) * 29)
            }
            // 底部
            SpriteView(S.plBottomLeft).at(0, height - 38)
            SpriteView(S.plBottomRight).at(width - 150, height - 38)
            // 标题栏：点一下在播放列表和歌词之间切换
            Color.clear
                .frame(width: (width - 50) * scale, height: 20 * scale)
                .contentShape(Rectangle())
                .onTapGesture {
                    app.showLyrics.toggle()
                    app.show(app.showLyrics ? "歌词" : "播放列表")
                }
                .at(25, 0)
                .accessibilityLabel(app.showLyrics ? "切换到播放列表" : "切换到歌词")
                .accessibilityAddTraits(.isButton)
            // 关闭按钮：常态画在右上角平铺块里，按下时盖上按下态
            Button { app.showPlaylist = false } label: { EmptyView() }
                .buttonStyle(PressedOverlayStyle(pressed: S.plCloseSelected))
                .at(width - 11, 3)
                .accessibilityLabel("关闭播放列表")
        }
    }

    /// 歌词模式的标题：皮肤里只画了 “PLAYLIST”，这里用标题块左边没字的那一列铺底，再写上 LYRICS
    private var lyricsTitle: some View {
        let text = Skin.pixelText("lyrics", color: skin.playlistStyle.normal)
        return ZStack {
            tiles(Sprite(.pledit, 26, 0, 3, 20), from: 0, to: 100, y: 0)
            Image(decorative: text, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(text.width) * scale, height: CGFloat(text.height) * scale)
                .offset(y: -0.5 * scale)
        }
        .frame(width: 100 * scale, height: 20 * scale)
    }

    private func tiles(_ sprite: Sprite, from x0: CGFloat, to x1: CGFloat, y: CGFloat) -> some View {
        let count = max(0, Int(((x1 - x0) / sprite.rect.width).rounded(.up)))
        return ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { i in
                SpriteView(sprite).offset(x: CGFloat(i) * sprite.rect.width * scale)
            }
        }
        .frame(width: max(0, x1 - x0) * scale, height: sprite.rect.height * scale, alignment: .topLeading)
        .clipped()
        .at(x0, y)
    }

    // MARK: 滚动条（经典皮肤的滑块）

    private var scrollbar: some View {
        let trackHeight = height - 20 - 38
        let count = player.queue.tracks.count
        let visibleRows = Int(trackHeight / 13)
        let maxTop = max(0, count - visibleRows)
        let ratio = app.showLyrics || maxTop == 0 ? 0 : CGFloat(min(topRow ?? 0, maxTop)) / CGFloat(maxTop)
        return ZStack(alignment: .topLeading) {
            Color.clear
            SpriteView(draggingScroll ? S.plScrollHandleSelected : S.plScrollHandle)
                .offset(y: (ratio * (trackHeight - 18)).rounded() * scale)
        }
        .frame(width: 8 * scale, height: trackHeight * scale, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard maxTop > 0, !app.showLyrics else { return }
                    draggingScroll = true
                    let r = min(max((value.location.y / scale - 9) / (trackHeight - 18), 0), 1)
                    topRow = Int((r * CGFloat(maxTop)).rounded())
                }
                .onEnded { _ in draggingScroll = false }
        )
        .accessibilityHidden(true)
    }

    // MARK: 曲目列表

    private func trackList(_ style: PlaylistStyle) -> some View {
        let tracks = player.queue.tracks
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        row(index: index, track: track, style: style)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topRow, anchor: .top)
            // 用皮肤里的滑块代替系统滚动条
            .scrollIndicators(.hidden)
            .onChange(of: player.queue.currentIndex) { _, new in
                if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    private func row(index: Int, track: Track, style: PlaylistStyle) -> some View {
        let isCurrent = index == player.queue.currentIndex
        let selected = app.selection.contains(index)
        let fontSize = 8.5 * scale
        return HStack(spacing: 4) {
            Text("\(index + 1). \(track.displayName)")
                .lineLimit(1)
            Spacer(minLength: 2)
            if player.loadingTrackID == track.id {
                if let progress = player.loadingProgress {
                    Text(progress).monospacedDigit()
                } else {
                    ProgressView().controlSize(.mini).tint(style.current.color)
                }
            }
            Text((track.duration).map(TimeFormat.clock) ?? "")
                .monospacedDigit()
        }
        .font(.system(size: fontSize))
        .foregroundStyle((isCurrent ? style.current : style.normal).color)
        .padding(.horizontal, 2 * scale)
        .frame(height: 13 * scale)
        .background(selected ? style.selectedBackground.color : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if app.isSelecting {
                if selected { app.selection.remove(index) } else { app.selection.insert(index) }
            } else {
                player.play(index: index)
            }
        }
        .contextMenu {
            Button("播放", systemImage: "play.fill") { player.play(index: index) }
            Button("多选", systemImage: "checkmark.circle") {
                app.isSelecting = true
                app.selection = [index]
            }
            Menu("移动", systemImage: "arrow.up.arrow.down") {
                Button("移到最前", systemImage: "arrow.up.to.line") { player.moveTrack(at: index, to: 0); app.endSelection() }
                    .disabled(index == 0)
                Button("上移", systemImage: "arrow.up") { player.moveTrack(at: index, to: index - 1); app.endSelection() }
                    .disabled(index == 0)
                Button("下移", systemImage: "arrow.down") { player.moveTrack(at: index, to: index + 1); app.endSelection() }
                    .disabled(index == player.queue.tracks.count - 1)
                Button("移到最后", systemImage: "arrow.down.to.line") { player.moveTrack(at: index, to: player.queue.tracks.count - 1); app.endSelection() }
                    .disabled(index == player.queue.tracks.count - 1)
            }
            Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                // 先插入副本到当前曲目之后，再删掉原位置的那一条
                let current = player.queue.currentIndex
                player.playNext([track])
                if let c = current {
                    if index > c { player.remove(at: IndexSet([index + 1])) } else if index < c { player.remove(at: IndexSet([index])) }
                }
                app.endSelection()
            }
            // 正在播的这首没有“下一首”可言，点了只会多出一条重复
            .disabled(isCurrent)
            Button("离线下载", systemImage: "arrow.down.circle") { makeOffline([track]) }
            Button("曲目信息", systemImage: "info.circle") { infoTrack = track }
            Button("从列表删除", systemImage: "trash", role: .destructive) {
                player.remove(at: IndexSet([index]))
                app.endSelection()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func emptyHint(_ style: PlaylistStyle) -> some View {
        VStack(spacing: 6 * scale) {
            Text("播放列表是空的")
            Button("打开音乐来源") { app.sheet = .sources }
                .buttonStyle(.bordered)
                .tint(style.normal.color)
            Text("也可以点下面的 ADD 从“文件”或曲库添加")
                .opacity(0.6)
        }
        .font(.system(size: 9 * scale))
        .foregroundStyle(style.normal.color)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10 * scale)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(app.selection.count) 首").monospacedDigit()
            Spacer()
            Button("全选") { app.selection = Set(player.queue.tracks.indices) }
            Button("删除") { removeSelected() }
                .disabled(app.selection.isEmpty)
            Button("完成") { app.endSelection() }
                .fontWeight(.semibold)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(6)
        .tint(.orange)
    }

    // MARK: 底部按钮

    private var bottomControls: some View {
        let y = height - 38 + 8
        let right = width - 150
        return Group {
            Menu {
                Button("从“文件”导入…", systemImage: "folder") { app.isImportingFiles = true }
                Button("从音乐来源添加…", systemImage: "externaldrive.connected.to.line.below") { app.sheet = .sources }
                Button("从曲库添加…", systemImage: "music.note.list") { app.sheet = .library }
            } label: { hitArea }
                .accessibilityLabel("添加到播放列表")
                .at(14, y)
            Menu {
                Button("删除所选", systemImage: "minus.circle") { removeSelected() }
                    .disabled(app.selection.isEmpty)
                Button("只保留所选", systemImage: "crop") { cropToSelection() }
                    .disabled(app.selection.isEmpty)
                Button("删除重复项", systemImage: "square.on.square") { removeDuplicates() }
                Button("清空列表", systemImage: "trash", role: .destructive) {
                    player.clear()
                    app.endSelection()
                }
            } label: { hitArea }
                .accessibilityLabel("删除曲目")
                .at(43, y)
            Menu {
                Button(app.isSelecting ? "退出多选" : "多选", systemImage: "checkmark.circle") {
                    if app.isSelecting { app.endSelection() } else { app.isSelecting = true }
                }
                Button("全选") { app.isSelecting = true; app.selection = Set(player.queue.tracks.indices) }
                Button("全不选") { app.selection = [] }
                    .disabled(!app.isSelecting)
                Button("反选") { app.isSelecting = true; app.selection = Set(player.queue.tracks.indices).subtracting(app.selection) }
            } label: { hitArea }
                .accessibilityLabel("选择曲目")
                .at(72, y)
            Menu {
                Menu("排序") {
                    Button("按标题") { sort(.title) }
                    Button("按艺术家") { sort(.artist) }
                    Button("按专辑") { sort(.album) }
                    Button("按路径") { sort(.path) }
                }
                Button("反转顺序") { player.reverse(); app.endSelection() }
                Button("随机打乱") { player.randomize(); app.endSelection() }
                Button("离线下载所选") {
                    makeOffline(app.selection.sorted().map { player.queue.tracks[$0] })
                }
                .disabled(app.selection.isEmpty)
                Button("曲目信息") {
                    if let first = app.selection.min() ?? player.queue.currentIndex { infoTrack = player.queue.tracks[first] }
                }
            } label: { hitArea }
                .accessibilityLabel("更多操作")
                .at(101, y)
            Menu {
                Button("保存播放列表…", systemImage: "square.and.arrow.down") {
                    playlistName = player.current?.album ?? "我的播放列表"
                    isSaving = true
                }
                .disabled(player.queue.isEmpty)
                Button("打开播放列表…", systemImage: "folder") { app.sheet = .playlists }
                Button("新建（清空）", systemImage: "doc") { player.clear(); app.endSelection() }
            } label: { hitArea }
                .accessibilityLabel("播放列表文件")
                .at(width - 44, y)

            // 总时长显示
            SkinText(text: runningTime)
                .frame(width: 90 * scale, alignment: .leading)
                .at(right + 7, height - 38 + 10)
            // 迷你播放按钮（6 个 10x10 热区）
            miniTransport.at(right + 3, height - 38 + 22)
        }
    }

    private var hitArea: some View {
        Color.clear
            .frame(width: 22 * scale, height: 18 * scale)
            .contentShape(Rectangle())
    }

    private var miniTransport: some View {
        HStack(spacing: 0) {
            mini("列表·上一首") { player.previous() }
            mini("列表·播放") { player.play() }
            mini("列表·暂停") { player.togglePause() }
            mini("列表·停止") { player.stop() }
            mini("列表·下一首") { player.next() }
            mini("列表·打开文件") { app.isImportingFiles = true }
        }
    }

    private func mini(_ label: String, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 10 * scale, height: 10 * scale)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    private var runningTime: String {
        let tracks = player.queue.tracks
        let selected = app.selection.compactMap { tracks.indices.contains($0) ? tracks[$0].duration : nil }.reduce(0, +)
        let total = tracks.compactMap(\.duration).reduce(0, +)
        return "\(TimeFormat.clock(selected))/\(TimeFormat.clock(total))"
    }

    // MARK: 操作

    private func removeSelected() {
        player.remove(at: IndexSet(app.selection))
        app.endSelection()
    }

    private func cropToSelection() {
        let keep = app.selection
        player.remove(at: IndexSet(player.queue.tracks.indices.filter { !keep.contains($0) }))
        app.endSelection()
    }

    private func removeDuplicates() {
        var seen = Set<String>()
        var dupes = IndexSet()
        for (i, t) in player.queue.tracks.enumerated() {
            if !seen.insert(t.id).inserted { dupes.insert(i) }
        }
        player.remove(at: dupes)
        app.endSelection()
        app.show(dupes.isEmpty ? "没有重复项" : "已删除 \(dupes.count) 个重复项")
    }

    private func sort(_ key: PlayerController.SortKey) {
        player.sort(by: key)
        app.endSelection()
    }

    private func makeOffline(_ tracks: [Track]) {
        let sources = app.sources
        let cache = player.cache
        app.show("开始离线下载 \(tracks.count) 首")
        Task {
            var failed = 0
            for t in tracks {
                guard let source = sources.source(t.sourceID) else { failed += 1; continue }
                do { try await cache.makeOffline(t, source: source) } catch { failed += 1 }
            }
            app.show(failed == 0 ? "离线下载完成" : "\(failed) 首下载失败")
        }
    }
}

/// 常态透明（皮肤底图里已画好），按下时显示按下态精灵
private struct PressedOverlayStyle: ButtonStyle {
    let pressed: Sprite
    @Environment(\.skinScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            if configuration.isPressed { SpriteView(pressed) } else { Color.clear }
        }
        .frame(width: pressed.rect.width * scale, height: pressed.rect.height * scale)
        // 点击区域比 9 像素大一圈，手指好点
        .padding(4 * scale)
        .contentShape(Rectangle())
        .padding(-4 * scale)
    }
}
