import MP9Kit
import SwiftUI

/// 经典频谱 / 示波器（76x16 像素），颜色来自皮肤 viscolor.txt
struct VisualizerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale
    let mode: AppModel.VisualizerMode

    @State private var peaks = [Double](repeating: 0, count: 19)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: mode == .off)) { timeline in
            Canvas { ctx, size in
                let colors = skin.visColors
                let s = scale
                func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: SkinColor) {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: CGFloat(w) * s, height: CGFloat(h) * s)), with: .color(c.color))
                }
                // 背景与网点
                px(0, 0, 76, 16, colors[0])
                for y in stride(from: 1, to: 16, by: 2) {
                    for x in stride(from: 1, to: 76, by: 2) { px(x, y, 1, 1, colors[1]) }
                }
                guard mode != .off else { return }
                let audio = app.player.audio
                if audio.state != .playing { audio.analyzer.decay() }
                let snapshot = audio.analyzer.snapshot()
                if mode == .spectrum {
                    // 75 个频段合成 19 根柱，每根 3 像素宽、间隔 1 像素
                    for bar in 0..<19 {
                        let slice = snapshot.spectrum[(bar * 75 / 19)..<min(75, (bar + 1) * 75 / 19)]
                        let level = Double(slice.max() ?? 0)
                        let height = Int((level * 16).rounded())
                        for row in 0..<height {
                            px(bar * 4, 15 - row, 3, 1, colors[17 - min(15, row)])
                        }
                        let peakRow = Int((peaks[bar] * 16).rounded())
                        if peakRow > 0 { px(bar * 4, 16 - peakRow, 3, 1, colors[23]) }
                    }
                } else {
                    // 示波器
                    for x in 0..<75 {
                        let v = Double(snapshot.waveform[x])
                        let y = min(15, max(0, Int((8 - v * 8).rounded())))
                        let colorIndex = 18 + min(4, abs(y - 8) / 2)
                        px(x, y, 1, 1, colors[colorIndex])
                    }
                }
                _ = timeline.date
            }
            .onChange(of: timeline.date) { updatePeaks() }
        }
    }

    private func updatePeaks() {
        guard mode == .spectrum else { return }
        let snapshot = app.player.audio.analyzer.snapshot().spectrum
        for bar in 0..<19 {
            let slice = snapshot[(bar * 75 / 19)..<min(75, (bar + 1) * 75 / 19)]
            let level = Double(slice.max() ?? 0)
            peaks[bar] = level >= peaks[bar] ? level : max(0, peaks[bar] - 0.02)
        }
    }
}
