import AVKit
import AmplayerKit
import SwiftUI

/// 总控侧边菜单：左上角按钮打开，从左边滑出。所有功能入口和设置都在这里。
struct SideMenuView: View {
    @Environment(AppModel.self) private var app
    @State private var showSleepOptions = false

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
            Section("声音") {
                Button { open(.effects) } label: {
                    HStack {
                        Label("音效", systemImage: "sparkles")
                        Spacer()
                        Text(effectName).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("menu.音效")
                Toggle(isOn: $app.showEqualizer) { Label("均衡器窗口", systemImage: "slider.vertical.3") }
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
                sleepTimer
                HStack {
                    Label("输出设备", systemImage: "airplayaudio")
                    Spacer()
                    RoutePicker().frame(width: 32, height: 32)
                }
            }
            Section("窗口") {
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
            Section {
                row("皮肤", "paintpalette") { open(.skins) }
                row("设置", "gearshape") { open(.settings) }
            } header: {
                Text("外观与设置")
            } footer: {
                Link(destination: AppLinks.repository) {
                    Label("免费开源 · github.com/ggttol/amplayer", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.footnote)
                }
                .padding(.top, 8)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .tint(.orange)
    }

    /// 定时关闭：到点淡出并暂停，或播完当前这首就停。
    /// 倒计时每秒刷新，不能放进 Menu 的标签里（标签一变菜单就会自己关掉），所以用按钮 + 选项框
    private var sleepTimer: some View {
        Button { showSleepOptions = true } label: {
            HStack {
                Label("定时关闭", systemImage: "moon.zzz")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(sleepStatus(at: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("menu.定时关闭")
        .confirmationDialog("定时关闭", isPresented: $showSleepOptions, titleVisibility: .visible) {
            let player = app.player
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) 分钟") { player.setSleepTimer(minutes: m); app.show("\(m) 分钟后停止播放") }
            }
            Button("播完当前这首") { player.setSleepAfterCurrentTrack(); app.show("播完当前这首后停止") }
            if player.sleepDeadline != nil || player.sleepAfterCurrent {
                Button("取消定时", role: .destructive) { player.setSleepTimer(minutes: nil); app.show("已取消定时关闭") }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var effectName: String {
        let id = app.player.effects.presetID
        if id == SoundEffectPreset.custom { return "自定义" }
        return SoundEffectPreset.preset(id)?.name ?? "原声"
    }

    private func sleepStatus(at date: Date) -> String {
        if app.player.sleepAfterCurrent { return "播完这首" }
        guard let deadline = app.player.sleepDeadline else { return "关" }
        let left = max(0, Int(deadline.timeIntervalSince(date)))
        return String(format: "%d:%02d", left / 60, left % 60)
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

/// 系统的 AirPlay / 蓝牙输出选择按钮
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .systemOrange
        view.activeTintColor = .systemOrange
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
