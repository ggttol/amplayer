import AmplayerKit
import SwiftUI
import UniformTypeIdentifiers

/// 歌词面板：放在播放列表窗口的列表区域，用皮肤的播放列表配色。
/// 同步歌词自动滚动并高亮当前行，点某一行跳到那里。
struct LyricsPanelView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skinScale) private var scale
    let style: PlaylistStyle

    @State private var importing = false
    @State private var searching = false
    private var player: PlayerController { app.player }

    var body: some View {
        Group {
            if let lyrics = player.lyrics {
                if lyrics.isSynced {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        let current = lyrics.index(at: player.audio.currentTime)
                        LyricsLines(lyrics: lyrics, current: current, follow: current, style: style, scale: scale) { time in
                            player.seek(to: time)
                        }
                    }
                } else {
                    // 纯文本歌词：按播放进度慢慢往下滚
                    TimelineView(.periodic(from: .now, by: player.audio.state == .playing ? 1 : 60)) { _ in
                        LyricsLines(lyrics: lyrics, current: nil, follow: estimatedLine(lyrics), style: style, scale: scale) { _ in }
                    }
                }
            } else {
                placeholder
            }
        }
        .contextMenu {
            Button("在线搜索歌词…", systemImage: "magnifyingglass") { searching = true }
                .disabled(player.current == nil)
            Button("从“文件”导入 .lrc", systemImage: "doc.badge.plus") { importing = true }
                .disabled(player.current == nil)
            Button("重新查找歌词", systemImage: "arrow.clockwise") { player.reloadLyrics() }
                .disabled(player.current == nil)
            Button("显示播放列表", systemImage: "list.bullet") { app.showLyrics = false }
        }
        .sheet(isPresented: $searching) { LyricsSearchView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let text = Lyrics.decode(data), player.setLyrics(text) {
                app.show("已导入歌词")
            } else {
                app.show("不是有效的歌词文件")
            }
        }
    }

    private func estimatedLine(_ lyrics: Lyrics) -> Int? {
        guard let duration = player.audio.info?.duration, duration > 0 else { return nil }
        return lyrics.estimatedIndex(progress: player.audio.currentTime / duration)
    }

    private var placeholder: some View {
        VStack(spacing: 6 * scale) {
            if player.current == nil {
                Text("没有正在播放的歌曲")
            } else if player.lyricsLoading {
                ProgressView().controlSize(.small).tint(style.normal.color)
                Text("正在查找歌词…")
            } else {
                Text("没有找到歌词")
                Text("长按这里可在线搜索或导入 .lrc")
                    .opacity(0.6)
            }
        }
        .font(.system(size: 8.5 * scale))
        .foregroundStyle(style.normal.color)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct LyricsLines: View {
    let lyrics: Lyrics
    /// 高亮的行（只有同步歌词有）
    let current: Int?
    /// 要滚到中间的行：同步歌词是当前行，纯文本是按进度估的行
    let follow: Int?
    let style: PlaylistStyle
    let scale: CGFloat
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4 * scale) {
                        ForEach(lyrics.lines) { line in
                            let isCurrent = line.id == current
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: (isCurrent ? 10 : 9) * scale, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle((isCurrent ? style.current : style.normal).color)
                                .opacity(current == nil || isCurrent ? 1 : 0.7)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 6 * scale)
                                .contentShape(Rectangle())
                                .onTapGesture { if let t = line.time { onSeek(t) } }
                                .id(line.id)
                        }
                    }
                    // 上下留白，第一行和最后一行也能滚到中间
                    .padding(.vertical, lyrics.isSynced ? geo.size.height / 2 : 8 * scale)
                }
                .scrollIndicators(.hidden)
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: follow) { _, _ in scroll(proxy, animated: true) }
                .onChange(of: lyrics) { _, _ in scroll(proxy, animated: false) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let follow else { return }
        if animated {
            withAnimation(.easeInOut(duration: current == nil ? 0.8 : 0.35)) { proxy.scrollTo(follow, anchor: .center) }
        } else {
            proxy.scrollTo(follow, anchor: .center)
        }
    }
}
