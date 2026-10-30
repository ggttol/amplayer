import AmplayerKit
import SwiftUI

/// 经典均衡器窗口（275x116）
struct EqualizerWindowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale

    private var player: PlayerController { app.player }

    var body: some View {
        let eq = player.equalizer
        SkinCanvas(size: SkinLayout.windowSize) {
            SpriteView(S.eqBackground)
            SpriteView(S.eqTitleBarSelected)
            SpriteButton(normal: S.eqCloseButton, pressed: S.eqCloseButtonDown, label: "关闭均衡器") { app.showEqualizer = false }
                .at(SkinLayout.eqClose)

            Button {
                var e = player.equalizer
                e.enabled.toggle()
                player.equalizer = e
            } label: { EmptyView() }
                .buttonStyle(ToggleSpriteStyle { S.eqOnButton(on: eq.enabled, down: $0) })
                .accessibilityLabel(eq.enabled ? "均衡器：开" : "均衡器：关")
                .at(SkinLayout.eqOn)
            // AUTO：每首歌记住自己的均衡器，下次播放时自动换回来
            Button {
                player.autoEqualizer.toggle()
                app.show(player.autoEqualizer ? "AUTO：每首歌记住自己的均衡器" : "AUTO：关")
            } label: { EmptyView() }
                .buttonStyle(ToggleSpriteStyle { S.eqAutoButton(on: player.autoEqualizer, down: $0) })
                .accessibilityLabel(player.autoEqualizer ? "均衡器自动：开" : "均衡器自动：关")
                .at(SkinLayout.eqAuto)

            Button { app.sheet = .effects } label: {
                SpriteView(S.eqPresetsButton)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预设")
            .at(SkinLayout.eqPresets)

            EQGraph(settings: eq).at(SkinLayout.eqGraph)

            EQSlider(value: Double(EqualizerSettings.normalized(eq.preamp)), label: "前级放大") { v in
                var e = player.equalizer
                e.preamp = snapped(v)
                player.equalizer = e
            }
            .at(SkinLayout.eqPreamp)

            ForEach(0..<10, id: \.self) { i in
                EQSlider(value: Double(EqualizerSettings.normalized(eq.bands[i])), label: "\(EqualizerSettings.bandLabels[i]) 赫兹") { v in
                    var e = player.equalizer
                    e.bands[i] = snapped(v)
                    player.equalizer = e
                }
                .at(SkinLayout.eqBand(i))
            }
        }
    }

    /// 0 dB 附近吸附
    private func snapped(_ v: Double) -> Float {
        let db = EqualizerSettings.decibels(fromNormalized: Float(v))
        return abs(db) < 0.8 ? 0 : (db * 2).rounded() / 2
    }
}

/// 竖向 EQ 滑块（14x63），value 0...1，1 为 +12dB
struct EQSlider: View {
    @Environment(\.skinScale) private var scale
    let value: Double
    let label: String
    let onChange: (Double) -> Void
    @State private var dragging = false
    @State private var lastTap: Date?
    @State private var dragMoved = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpriteView(S.eqSliderFrame(Int((value * 27).rounded())))
            SpriteView(dragging ? S.eqSliderThumbSelected : S.eqSliderThumb)
                .offset(x: 1 * scale, y: CGFloat(1 - value) * 51 * scale)
        }
        .frame(width: 14 * scale, height: 63 * scale, alignment: .topLeading)
        .contentShape(Rectangle().inset(by: -2 * scale))
        // 拖动手势从按下就开始识别，会吞掉双击手势：在拖动里自己判断“两次轻点”来归零
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    if abs(g.translation.height) > 3 { dragMoved = true }
                    if dragMoved { onChange(valueFor(g.location.y)) }
                }
                .onEnded { g in
                    dragging = false
                    defer { dragMoved = false }
                    if dragMoved {
                        onChange(valueFor(g.location.y))
                        lastTap = nil
                    } else if let last = lastTap, Date().timeIntervalSince(last) < 0.35 {
                        onChange(0.5)
                        lastTap = nil
                    } else {
                        lastTap = Date()
                        onChange(valueFor(g.location.y))
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f dB", EqualizerSettings.decibels(fromNormalized: Float(value))))
        .accessibilityAdjustableAction { d in onChange(min(1, max(0, value + (d == .increment ? 1.0 / 24 : -1.0 / 24)))) }
    }

    private func valueFor(_ y: CGFloat) -> Double {
        let px = y / scale - 5.5
        return Double(min(1, max(0, 1 - px / 51)))
    }
}

/// EQ 曲线小图（113x19）
struct EQGraph: View {
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale
    let settings: EqualizerSettings

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpriteView(S.eqGraphBackground)
            Canvas { ctx, _ in
                let s = scale
                let colors = skin.eqGraphColors
                // 前级放大线
                let preY = Int(((1 - Double(EqualizerSettings.normalized(settings.preamp))) * 18).rounded())
                if let line = skin.image(S.eqPreampLine) {
                    ctx.draw(Image(decorative: line, scale: 1).interpolation(.none), in: CGRect(x: 0, y: CGFloat(preY) * s, width: 113 * s, height: s))
                }
                // 10 个点之间做平滑插值
                let values = settings.bands.map { 1 - Double(EqualizerSettings.normalized($0)) }
                for x in 0..<113 {
                    let pos = Double(x) / 112 * 9
                    let i = min(8, Int(pos))
                    let t = pos - Double(i)
                    let smooth = t * t * (3 - 2 * t)
                    let v = values[i] + (values[i + 1] - values[i]) * smooth
                    let y = min(18, max(0, Int((v * 18).rounded())))
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(colors[min(colors.count - 1, y)].color))
                }
            }
            .frame(width: 113 * scale, height: 19 * scale)
        }
        .frame(width: 113 * scale, height: 19 * scale, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
