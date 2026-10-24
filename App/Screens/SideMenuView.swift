import AmplayerKit
import SwiftUI

/// 总控侧边菜单：左上角按钮打开，从左边滑出。所有功能入口和设置都在这里。
struct SideMenuView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if app.showSideMenu {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                        .accessibilityLabel("关闭菜单")
                        .accessibilityAddTraits(.isButton)
                    panel
                        .frame(width: min(320, geo.size.width * 0.82))
                        .frame(maxHeight: .infinity)
                        .background(Color(white: 0.09).ignoresSafeArea())
                        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                            if value.translation.width < -60 { close() }
                        })
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeOut(duration: 0.22), value: app.showSideMenu)
        }
    }

    private func close() { app.showSideMenu = false }

    /// 先收起菜单再打开对应页面
    /// 和收起动画同时弹出页面会被系统丢掉，所以等菜单收起后再弹
    private func open(_ sheet: AppModel.Sheet) {
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            app.sheet = sheet
        }
    }

    private var panel: some View {
        @Bindable var app = app
        return List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 36)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Amplayer").font(.headline)
                        Text(app.player.current?.displayName ?? "未在播放")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("音乐") {
                row("打开文件…", "doc.badge.plus") {
                    close()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(280))
                        app.isImportingFiles = true
                    }
                }
                row("来源", "externaldrive.connected.to.line.below") { open(.sources) }
                row("曲库与播放列表", "music.note.list") { open(.library) }
            }
            Section("播放顺序") {
                Picker(selection: Binding(get: { app.player.repeatMode }, set: { app.player.repeatMode = $0 })) {
                    ForEach(RepeatMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label("循环", systemImage: app.player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                Toggle(isOn: Binding(get: { app.player.shuffle }, set: { app.player.shuffle = $0 })) {
                    Label("随机播放", systemImage: "shuffle")
                }
            }
            Section("窗口") {
                Toggle(isOn: $app.showEqualizer) { Label("均衡器", systemImage: "slider.vertical.3") }
                Toggle(isOn: $app.showPlaylist) { Label("列表/歌词窗口", systemImage: "list.bullet.rectangle") }
                Picker(selection: $app.showLyrics) {
                    Text("播放列表").tag(false)
                    Text("歌词").tag(true)
                } label: {
                    Label("窗口内容", systemImage: "quote.bubble")
                }
                Picker(selection: $app.visualizerMode) {
                    Text("频谱").tag(AppModel.VisualizerMode.spectrum)
                    Text("示波器").tag(AppModel.VisualizerMode.oscilloscope)
                    Text("关闭").tag(AppModel.VisualizerMode.off)
                } label: {
                    Label("可视化", systemImage: "waveform")
                }
                Toggle(isOn: $app.showRemainingTime) { Label("显示剩余时间", systemImage: "timer") }
            }
            Section("外观与设置") {
                row("皮肤", "paintpalette") { open(.skins) }
                row("设置", "gearshape") { open(.settings) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .tint(.orange)
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("menu.\(title)")
    }
}
