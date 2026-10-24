import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把皮肤合成为静态窗口图（皮肤列表缩略图、快照测试用）
public enum SkinPreview {
    public struct State: Sendable {
        public var title = "MP9 - Classic skin preview"
        public var minutes = 1, seconds = 23
        public var volume: Double = 0.75
        public var balance: Double = 0
        public var position: Double = 0.35
        public var eqBands: [Double] = [0.7, 0.62, 0.55, 0.5, 0.45, 0.5, 0.58, 0.66, 0.7, 0.74]
        public init() {}
    }

    public static func mainWindow(_ skin: Skin, state: State = State()) -> CGImage? {
        let c = Canvas(width: 275, height: 116, skin: skin)
        c.draw(S.mainBackground, at: .zero)
        c.draw(S.titleBarSelected, at: .zero)
        c.draw(S.optionsButton, at: SkinLayout.options)
        c.draw(S.minimizeButton, at: SkinLayout.minimize)
        c.draw(S.shadeButton, at: SkinLayout.shade)
        c.draw(S.closeButton, at: SkinLayout.close)
        c.draw(S.playing, at: SkinLayout.playStatus)
        c.draw(S.working, at: SkinLayout.workIndicator)
        let digits = [state.minutes / 10, state.minutes % 10, state.seconds / 10, state.seconds % 10]
        for (i, d) in digits.enumerated() {
            c.draw(S.digit(d, ex: skin.hasNumsEx), at: CGPoint(x: SkinLayout.time.x + SkinLayout.digitOffsets[i], y: SkinLayout.time.y))
        }
        if let text = skin.renderText(state.title) {
            c.drawImage(text, at: SkinLayout.marquee.origin, clip: SkinLayout.marquee)
        }
        if let kbps = skin.renderText("320") { c.drawImage(kbps, at: SkinLayout.kbps.origin, clip: SkinLayout.kbps) }
        if let khz = skin.renderText("44") { c.drawImage(khz, at: SkinLayout.khz.origin, clip: SkinLayout.khz) }
        c.draw(S.mono, at: SkinLayout.mono)
        c.draw(S.stereoOn, at: SkinLayout.stereo)
        let volumeFrame = Int((state.volume * 27).rounded())
        c.draw(S.volumeFrame(volumeFrame), at: SkinLayout.volume.origin)
        c.draw(S.volumeThumb, at: CGPoint(x: SkinLayout.volume.minX + CGFloat(state.volume * 54), y: SkinLayout.volume.minY + 1))
        c.draw(S.balanceFrame(Int(abs(state.balance) * 27)), at: SkinLayout.balance.origin)
        c.draw(S.balanceThumb, at: CGPoint(x: SkinLayout.balance.minX + CGFloat((state.balance + 1) / 2 * 24), y: SkinLayout.balance.minY + 1))
        c.draw(S.eqButton(on: true, down: false), at: SkinLayout.eqButton)
        c.draw(S.playlistButton(on: true, down: false), at: SkinLayout.playlistButton)
        c.draw(S.positionBackground, at: SkinLayout.position.origin)
        c.draw(S.positionThumb, at: CGPoint(x: SkinLayout.position.minX + CGFloat(state.position * 219), y: SkinLayout.position.minY))
        c.draw(S.previous, at: SkinLayout.previous)
        c.draw(S.play, at: SkinLayout.play)
        c.draw(S.pause, at: SkinLayout.pause)
        c.draw(S.stop, at: SkinLayout.stop)
        c.draw(S.next, at: SkinLayout.next)
        c.draw(S.eject, at: SkinLayout.eject)
        c.draw(S.shuffleButton(on: false, down: false), at: SkinLayout.shuffle)
        c.draw(S.repeatButton(on: true, down: false), at: SkinLayout.repeatButton)
        // 频谱示意
        let vis = SkinLayout.visualizer
        for i in 0..<19 {
            let h = Int(abs(sin(Double(i) * 0.7)) * 14) + 1
            for row in 0..<h {
                let color = skin.visColors[min(17, 2 + 15 - row)]
                c.fill(CGRect(x: vis.minX + CGFloat(i * 4), y: vis.maxY - CGFloat(row) - 1, width: 3, height: 1), color)
            }
        }
        return c.image()
    }

    public static func equalizerWindow(_ skin: Skin, state: State = State()) -> CGImage? {
        let c = Canvas(width: 275, height: 116, skin: skin)
        c.draw(S.eqBackground, at: .zero)
        c.draw(S.eqTitleBarSelected, at: .zero)
        c.draw(S.eqOnButton(on: true, down: false), at: SkinLayout.eqOn)
        c.draw(S.eqAutoButton(on: false, down: false), at: SkinLayout.eqAuto)
        c.draw(S.eqPresetsButton, at: SkinLayout.eqPresets)
        c.draw(S.eqGraphBackground, at: SkinLayout.eqGraph)
        func slider(_ value: Double, at p: CGPoint) {
            c.draw(S.eqSliderFrame(Int((value * 27).rounded())), at: p)
            c.draw(S.eqSliderThumb, at: CGPoint(x: p.x + 1, y: p.y + CGFloat((1 - value) * 51)))
        }
        slider(0.5, at: SkinLayout.eqPreamp)
        for (i, v) in state.eqBands.enumerated() { slider(v, at: SkinLayout.eqBand(i)) }
        return c.image()
    }

    public static func pngData(_ image: CGImage, scale: Int = 1) -> Data? {
        var target = image
        if scale > 1, let ctx = Skin.makeContext(width: image.width * scale, height: image.height * scale) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
            if let scaled = ctx.makeImage() { target = scaled }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, target, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private final class Canvas {
        let ctx: CGContext
        let height: Int
        let skin: Skin

        init(width: Int, height: Int, skin: Skin) {
            ctx = Skin.makeContext(width: width, height: height)!
            self.height = height
            self.skin = skin
        }

        func draw(_ sprite: Sprite, at p: CGPoint) {
            guard let img = skin.image(sprite) else { return }
            drawImage(img, at: p, clip: nil)
        }

        func drawImage(_ img: CGImage, at p: CGPoint, clip: CGRect?) {
            ctx.saveGState()
            if let clip { ctx.clip(to: Skin.flipped(clip, height: height)) }
            ctx.draw(img, in: Skin.flipped(CGRect(x: p.x, y: p.y, width: CGFloat(img.width), height: CGFloat(img.height)), height: height))
            ctx.restoreGState()
        }

        func fill(_ rect: CGRect, _ color: SkinColor) {
            ctx.setFillColor(color.cgColor)
            ctx.fill(Skin.flipped(rect, height: height))
        }

        func image() -> CGImage? { ctx.makeImage() }
    }
}
