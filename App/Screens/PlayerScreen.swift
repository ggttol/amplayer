import AmplayerKit
import SwiftUI
import UniformTypeIdentifiers

/// 主界面：主窗口 + 均衡器 + 播放列表竖向排列，按屏宽等比放大
struct PlayerScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            let scale = geo.size.width / 275
            let toolbarHeight: CGFloat = 44 + WindowStrip.height
            let used = 116 * scale * (app.showEqualizer ? 2 : 1)
            let playlistHeight = max(116, (geo.size.height - used - toolbarHeight) / scale)
            VStack(spacing: 0) {
                MainWindowView()
                if app.showEqualizer { EqualizerWindowView() }
                if app.showPlaylist {
                    PlaylistWindowView(height: playlistHeight.rounded(.down))
                } else {
                    Spacer(minLength: 0)
                }
                WindowStrip().frame(height: WindowStrip.height)
                BottomBar().frame(height: 44)
            }
            .environment(\.skinScale, scale)
            .environment(\.skin, app.skin)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { ToastView() }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .sources: SourcesView()
            case .library: LibraryView()
            case .skins: SkinsView()
            case .settings: SettingsView()
            case .menu: MainMenuView()
            }
        }
        .fileImporter(isPresented: $app.isImportingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { app.importAudioFiles(urls, play: true) }
        }
        .onOpenURL { app.open(url: $0) }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }
}

/// 窗口开关：均衡器开关，播放列表/歌词二选一。窗口被右上角 × 关掉后在这里一点就回来
struct WindowStrip: View {
    static let height: CGFloat = 36
    @Environment(AppModel.self) private var app

    private enum Panel { case playlist, lyrics }

    private var panel: Panel? {
        guard app.showPlaylist else { return nil }
        return app.showLyrics ? .lyrics : .playlist
    }

    var body: some View {
        HStack(spacing: 8) {
            chip("均衡器", "slider.vertical.3", on: app.showEqualizer) { app.showEqualizer.toggle() }
                .frame(maxWidth: 110)
            HStack(spacing: 0) {
                segment("列表", "list.bullet", on: panel == .playlist) { show(.playlist) }
                segment("歌词", "quote.bubble", on: panel == .lyrics) { show(.lyrics) }
            }
            .background(Color(white: 0.14), in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    /// 已经在显示的那个再点一下就收起
    private func show(_ target: Panel) {
        if panel == target {
            app.showPlaylist = false
        } else {
            app.showLyrics = target == .lyrics
            app.showPlaylist = true
        }
    }

    private func chip(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, symbol, on: on)
                .background(on ? Color(white: 0.28) : Color(white: 0.14), in: Capsule())
        }
        .accessibilityLabel("窗口·\(title)")
        .accessibilityValue(on ? "已打开" : "已关闭")
    }

    private func segment(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, symbol, on: on)
                .background(on ? Color(white: 0.28) : Color.clear, in: Capsule())
        }
        .accessibilityLabel("窗口·\(title)")
        .accessibilityValue(on ? "已打开" : "已关闭")
    }

    private func label(_ title: String, _ symbol: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
        }
        .foregroundStyle(on ? Color.white : Color(white: 0.6))
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .contentShape(Capsule())
    }
}

/// 底部原生工具栏（手机上比皮肤里的小按钮好点）
struct BottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            item("来源", "externaldrive.connected.to.line.below") { app.sheet = .sources }
            item("曲库", "music.note.list") { app.sheet = .library }
            item("皮肤", "paintpalette") { app.sheet = .skins }
            item("设置", "gearshape") { app.sheet = .settings }
        }
        .padding(.horizontal, 8)
        .background(Color(white: 0.08))
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color(white: 0.75))
        }
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

/// 标题栏左上角菜单
struct MainMenuView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                Section("播放") {
                    Button("打开文件…", systemImage: "doc.badge.plus") { dismiss(); app.isImportingFiles = true }
                    Button("浏览来源", systemImage: "externaldrive.connected.to.line.below") { app.sheet = .sources }
                    Button("曲库与播放列表", systemImage: "music.note.list") { app.sheet = .library }
                }
                Section("窗口") {
                    Toggle("均衡器", isOn: $app.showEqualizer)
                    Toggle("播放列表", isOn: $app.showPlaylist)
                    Toggle("歌词（代替播放列表显示）", isOn: $app.showLyrics)
                    Picker("可视化", selection: $app.visualizerMode) {
                        Text("频谱").tag(AppModel.VisualizerMode.spectrum)
                        Text("示波器").tag(AppModel.VisualizerMode.oscilloscope)
                        Text("关闭").tag(AppModel.VisualizerMode.off)
                    }
                    Toggle("显示剩余时间", isOn: $app.showRemainingTime)
                }
                Section {
                    Button("皮肤", systemImage: "paintpalette") { app.sheet = .skins }
                    Button("设置", systemImage: "gearshape") { app.sheet = .settings }
                }
            }
            .navigationTitle("Amplayer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
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
