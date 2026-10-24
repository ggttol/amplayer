import MP9Kit
import SwiftUI

/// 经典主窗口（275x116）
struct MainWindowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale

    private var player: PlayerController { app.player }

    var body: some View {
        SkinCanvas(size: SkinLayout.windowSize) {
            SpriteView(S.mainBackground)
            titleBar
            statusIndicators
            TimeDisplay().at(SkinLayout.time)
            VisualizerView(mode: app.visualizerMode)
                .frame(width: SkinLayout.visualizer.width * scale, height: SkinLayout.visualizer.height * scale)
                .contentShape(Rectangle())
                .onTapGesture { cycleVisualizer() }
                .at(SkinLayout.visualizer.origin)
                .accessibilityLabel("可视化，点按切换")
            Marquee(text: marqueeText, width: SkinLayout.marquee.width)
                .at(SkinLayout.marquee.origin)
            mediaInfo
            sliders
            windowToggles
            transport
        }
    }

    // MARK: 标题栏

    private var titleBar: some View {
        Group {
            SpriteView(S.titleBarSelected)
            SpriteButton(normal: S.optionsButton, pressed: S.optionsButtonDown, label: "菜单") { app.sheet = .menu }
                .at(SkinLayout.options)
            SpriteButton(normal: S.minimizeButton, pressed: S.minimizeButtonDown, label: "皮肤") { app.sheet = .skins }
                .at(SkinLayout.minimize)
            SpriteButton(normal: S.shadeButton, pressed: S.shadeButtonDown, label: "来源") { app.sheet = .sources }
                .at(SkinLayout.shade)
            SpriteButton(normal: S.closeButton, pressed: S.closeButtonDown, label: "关闭（停止播放）") { player.stop() }
                .at(SkinLayout.close)
        }
    }

    // MARK: 状态

    private var statusIndicators: some View {
        Group {
            SpriteView(player.audio.state == .playing ? S.playing : (player.audio.state == .paused ? S.paused : S.stopped))
                .at(SkinLayout.playStatus)
            if player.audio.state == .playing || player.isLoading {
                SpriteView(player.isLoading ? S.working : S.notWorking).at(SkinLayout.workIndicator)
            }
        }
    }

    private var marqueeText: String {
        if let error = player.lastError { return error }
        guard let track = player.current, let index = player.queue.currentIndex else { return "MP9 - 点 ADD 或右上角按钮添加音乐" }
        let duration = (player.audio.info?.duration ?? track.duration).map { " (\(TimeFormat.clock($0)))" } ?? ""
        let prefix = player.isLoading ? "[缓冲中] " : ""
        return "\(prefix)\(index + 1). \(track.displayName)\(duration)"
    }

    private var mediaInfo: some View {
        Group {
            if let info = player.audio.info, player.audio.state != .stopped || player.current != nil {
                SkinText(text: String(String(info.bitrate).suffix(3)).leftPadded(to: 3))
                    .frame(width: SkinLayout.kbps.width * scale, alignment: .trailing)
                    .at(SkinLayout.kbps.origin)
                SkinText(text: String(Int((info.sampleRate / 1000).rounded())).leftPadded(to: 2))
                    .frame(width: SkinLayout.khz.width * scale, alignment: .trailing)
                    .at(SkinLayout.khz.origin)
                SpriteView(info.channels == 1 ? S.monoOn : S.mono).at(SkinLayout.mono)
                SpriteView(info.channels >= 2 ? S.stereoOn : S.stereo).at(SkinLayout.stereo)
            } else {
                SpriteView(S.mono).at(SkinLayout.mono)
                SpriteView(S.stereo).at(SkinLayout.stereo)
            }
        }
    }

    // MARK: 滑块

    private var sliders: some View {
        Group {
            SkinHSlider(
                width: 68, height: 13, thumbSize: CGSize(width: 14, height: 11), thumbY: 1,
                value: Double(player.volume),
                background: { S.volumeFrame(Int(($0 * 27).rounded())) },
                thumb: S.volumeThumb, thumbPressed: S.volumeThumbSelected, label: "音量"
            ) { v, _ in player.volume = Float(v) }
                .at(SkinLayout.volume.origin)

            SkinHSlider(
                width: 38, height: 13, thumbSize: CGSize(width: 14, height: 11), thumbY: 1,
                value: Double(player.balance + 1) / 2,
                background: { S.balanceFrame(Int(abs($0 * 2 - 1) * 27)) },
                thumb: S.balanceThumb, thumbPressed: S.balanceThumbSelected, label: "平衡"
            ) { v, _ in
                // 中间附近吸附到 0
                let b = Float(v * 2 - 1)
                player.balance = abs(b) < 0.12 ? 0 : b
            }
            .at(SkinLayout.balance.origin)

            PositionSlider().at(SkinLayout.position.origin)
        }
    }

    private var windowToggles: some View {
        Group {
            Button { app.showEqualizer.toggle() } label: { EmptyView() }
                .buttonStyle(ToggleSpriteStyle { pressed in S.eqButton(on: app.showEqualizer, down: pressed) })
                .accessibilityLabel("均衡器")
                .at(SkinLayout.eqButton)
            Button { app.showPlaylist.toggle() } label: { EmptyView() }
                .buttonStyle(ToggleSpriteStyle { pressed in S.playlistButton(on: app.showPlaylist, down: pressed) })
                .accessibilityLabel("播放列表")
                .at(SkinLayout.playlistButton)
        }
    }

    // MARK: 播放控制

    private var transport: some View {
        Group {
            SpriteButton(normal: S.previous, pressed: S.previousDown, label: "上一首") { player.previous() }.at(SkinLayout.previous)
            SpriteButton(normal: S.play, pressed: S.playDown, label: "播放") {
                if player.audio.state == .playing { player.seek(to: 0) } else { player.play() }
            }.at(SkinLayout.play)
            SpriteButton(normal: S.pause, pressed: S.pauseDown, label: "暂停") { player.togglePause() }.at(SkinLayout.pause)
            SpriteButton(normal: S.stop, pressed: S.stopDown, label: "停止") { player.stop() }.at(SkinLayout.stop)
            SpriteButton(normal: S.next, pressed: S.nextDown, label: "下一首") { player.next() }.at(SkinLayout.next)
            SpriteButton(normal: S.eject, pressed: S.ejectDown, label: "打开文件") { app.isImportingFiles = true }.at(SkinLayout.eject)

            Button { player.shuffle.toggle() } label: { EmptyView() }
                .buttonStyle(ToggleSpriteStyle { pressed in S.shuffleButton(on: player.shuffle, down: pressed) })
                .accessibilityLabel(player.shuffle ? "随机播放：开" : "随机播放：关")
                .at(SkinLayout.shuffle)
            Button {
                player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
                let message = switch player.repeatMode {
                case .off: "循环：关"
                case .all: "循环：全部"
                case .one: "循环：单曲"
                }
                app.show(message)
            } label: { EmptyView() }
                .buttonStyle(ToggleSpriteStyle { pressed in S.repeatButton(on: player.repeatMode != .off, down: pressed) })
                .accessibilityLabel("循环")
                .at(SkinLayout.repeatButton)
            Color.clear
                .frame(width: SkinLayout.about.width * scale, height: SkinLayout.about.height * scale)
                .contentShape(Rectangle())
                .onTapGesture { app.sheet = .settings }
                .at(SkinLayout.about.origin)
                .accessibilityLabel("设置")
        }
    }

    private func cycleVisualizer() {
        app.visualizerMode = switch app.visualizerMode {
        case .spectrum: .oscilloscope
        case .oscilloscope: .off
        case .off: .spectrum
        }
    }
}

/// 根据按下与开关状态取精灵的按钮样式
struct ToggleSpriteStyle: ButtonStyle {
    let sprite: (Bool) -> Sprite

    func makeBody(configuration: Configuration) -> some View {
        SpriteView(sprite(configuration.isPressed)).contentShape(Rectangle())
    }
}

/// 时间显示：分:秒，点按切换剩余时间；暂停时闪烁
struct TimeDisplay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let player = app.player
            let audio = player.audio
            let duration = audio.info?.duration ?? 0
            let elapsed = audio.currentTime
            let remaining = app.showRemainingTime && duration > 0
            let shown = remaining ? max(0, duration - elapsed) : elapsed
            let total = Int(shown)
            let minutes = min(99, total / 60), seconds = total % 60
            let blinkOff = audio.state == .paused && Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            let visible = audio.state != .stopped && !blinkOff
            ZStack(alignment: .topLeading) {
                if visible {
                    if skin.hasNumsEx {
                        SpriteView(remaining ? S.minusEx : S.noMinusEx).offset(x: 0, y: 0)
                    } else if remaining {
                        SpriteView(S.minus).offset(x: -1 * scale, y: 6 * scale)
                    }
                    ForEach(0..<4, id: \.self) { i in
                        let digits = [minutes / 10, minutes % 10, seconds / 10, seconds % 10]
                        SpriteView(S.digit(digits[i], ex: skin.hasNumsEx))
                            .offset(x: SkinLayout.digitOffsets[i] * scale)
                    }
                }
            }
            .frame(width: 63 * scale, height: 13 * scale, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.showRemainingTime.toggle() }
        .accessibilityElement()
        .accessibilityLabel("播放时间")
        .accessibilityIdentifier("time")
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        let player = app.player
        let state = player.isLoading ? "缓冲中" : (player.audio.state == .playing ? "播放中" : (player.audio.state == .paused ? "已暂停" : "已停止"))
        return "\(state) \(TimeFormat.clock(player.audio.currentTime)) \(player.current?.title ?? "")"
    }
}

/// 进度条：拖动时只移动滑块，松手后跳转
struct PositionSlider: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let audio = app.player.audio
            let duration = audio.info?.duration ?? 0
            let value = duration > 0 ? audio.currentTime / duration : 0
            SkinHSlider(
                width: 248, height: 10, thumbSize: CGSize(width: 29, height: 10), thumbY: 0,
                value: value,
                background: { _ in S.positionBackground },
                thumb: audio.state == .stopped && audio.info == nil ? nil : S.positionThumb,
                thumbPressed: S.positionThumbSelected, label: "进度"
            ) { v, ended in
                if ended, duration > 0 { app.player.seek(to: v * duration) }
            }
        }
    }
}

extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
