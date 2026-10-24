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
    private var player: PlayerController { app.player }

    var body: some View {
        Group {
            if let lyrics = player.lyrics {
                if lyrics.isSynced {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        LyricsLines(lyrics: lyrics, current: lyrics.index(at: player.audio.currentTime), style: style, scale: scale) { time in
                            player.seek(to: time)
                        }
                    }
                } else {
                    LyricsLines(lyrics: lyrics, current: nil, style: style, scale: scale) { _ in }
                }
            } else {
                placeholder
            }
        }
        .contextMenu {
            Button("从“文件”导入 .lrc", systemImage: "doc.badge.plus") { importing = true }
                .disabled(player.current == nil)
            Button("重新查找歌词", systemImage: "arrow.clockwise") { player.reloadLyrics() }
                .disabled(player.current == nil)
            Button("显示播放列表", systemImage: "list.bullet") { app.showLyrics = false }
        }
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

    private var placeholder: some View {
        VStack(spacing: 6 * scale) {
            if player.current == nil {
                Text("没有正在播放的歌曲")
            } else if player.lyricsLoading {
                ProgressView().controlSize(.small).tint(style.normal.color)
                Text("正在查找歌词…")
            } else {
                Text("没有找到歌词")
                Text("把同名 .lrc 放在歌曲旁边，或长按这里导入")
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
    let current: Int?
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
                .onChange(of: current) { _, _ in scroll(proxy, animated: true) }
                .onChange(of: lyrics) { _, _ in scroll(proxy, animated: false) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let current else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(current, anchor: .center) }
        } else {
            proxy.scrollTo(current, anchor: .center)
        }
    }
}
