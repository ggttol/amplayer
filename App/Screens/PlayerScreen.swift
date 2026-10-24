import AmplayerKit
import SwiftUI
import UniformTypeIdentifiers

/// 主界面：主窗口 + 均衡器 + 播放列表竖向排列，按屏宽等比放大
struct PlayerScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            // 按宽度放大；高度放不下（iPad 横屏）时按高度缩小，保证主窗口 + 均衡器 + 最矮的播放列表都在屏幕内
            let windows: CGFloat = 116 * (app.showEqualizer ? 2 : 1) + (app.showPlaylist ? 116 : 0)
            let scale = min(geo.size.width / 275, geo.size.height / windows)
            let used = 116 * scale * (app.showEqualizer ? 2 : 1)
            let playlistHeight = max(116, (geo.size.height - used) / scale)
            VStack(spacing: 0) {
                MainWindowView()
                if app.showEqualizer { EqualizerWindowView() }
                if app.showPlaylist {
                    PlaylistWindowView(height: playlistHeight.rounded(.down))
                } else {
                    ClosedWindowsHint().frame(maxHeight: .infinity)
                }
            }
            .frame(width: 275 * scale)
            .frame(maxWidth: .infinity)
            .environment(\.skinScale, scale)
            .environment(\.skin, app.skin)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay { SideMenuView() }
        .overlay(alignment: .top) { ToastView() }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .sources: SourcesView()
            case .library: LibraryView()
            case .playlists: LibraryView(initialTab: .playlists)
            case .skins: SkinsView()
            case .settings: SettingsView()
            case .effects: SoundEffectsView()
            }
        }
        .fileImporter(isPresented: $app.isImportingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { app.importAudioFiles(urls, play: true) }
        }
        .onOpenURL { app.open(url: $0) }
        .onChange(of: app.player.lastError) { _, error in
            if let error { app.show(error) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }
}

/// 播放列表被关掉后下面的空白处：告诉用户怎么找回窗口
struct ClosedWindowsHint: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            Text(app.isMiniMode ? "迷你模式" : "播放列表已关闭").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if app.isMiniMode { Button("恢复窗口") { app.toggleMiniMode() } } else {
                Button("显示播放列表") { app.showLyrics = false; app.showPlaylist = true }
                Button("显示歌词") { app.showLyrics = true; app.showPlaylist = true }
                if !app.showEqualizer { Button("均衡器") { app.showEqualizer = true } }
                }
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .font(.footnote)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let message = app.toast {
            Text(message)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.default, value: app.toast)
        }
    }
}

/// 曲目信息
struct TrackInfoView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var offline = false

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("标题", value: track.title)
                if let v = track.artist { LabeledContent("艺术家", value: v) }
                if let v = track.album { LabeledContent("专辑", value: v) }
                if let v = track.trackNumber { LabeledContent("音轨", value: "\(v)") }
                if let v = track.duration { LabeledContent("时长", value: TimeFormat.clock(v)) }
                if let v = track.fileSize { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: v, countStyle: .file)) }
                LabeledContent("格式", value: track.fileExtension.uppercased())
                LabeledContent("来源", value: app.sources.config(track.sourceID)?.name ?? track.sourceID)
                LabeledContent("路径") { Text(track.path).font(.caption).textSelection(.enabled) }
                LabeledContent("离线", value: offline ? "已下载" : "否")
            }
            .navigationTitle("曲目信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { offline = await app.player.cache.isOffline(track) }
        }
        .presentationDetents([.medium, .large])
    }
}
