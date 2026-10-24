import AmplayerKit
import SwiftUI

// 皮肤坐标系：所有位置都用皮肤像素表示，乘以 skinScale 得到屏幕点。
// 不用 scaleEffect，而是让每张精灵图按最近邻插值放大，保证像素清晰、手势坐标直观。

private struct SkinScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct SkinKey: EnvironmentKey {
    static let defaultValue: Skin = Skin.defaultSkin
}

extension EnvironmentValues {
    var skinScale: CGFloat {
        get { self[SkinScaleKey.self] }
        set { self[SkinScaleKey.self] = newValue }
    }

    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

extension SkinColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// 把子视图放到皮肤坐标 (x, y)
struct SkinPlacement: ViewModifier {
    @Environment(\.skinScale) private var scale
    let point: CGPoint

    func body(content: Content) -> some View {
        content.offset(x: point.x * scale, y: point.y * scale)
    }
}

extension View {
    func at(_ point: CGPoint) -> some View { modifier(SkinPlacement(point: point)) }
    func at(_ x: CGFloat, _ y: CGFloat) -> some View { modifier(SkinPlacement(point: CGPoint(x: x, y: y))) }
}

/// 固定尺寸的皮肤画布，子视图用 .at() 定位
struct SkinCanvas<Content: View>: View {
    @Environment(\.skinScale) private var scale
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) { content }
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .clipped()
    }
}

/// 一张位图，按最近邻放大
struct PixelImage: View {
    @Environment(\.skinScale) private var scale
    let image: CGImage?
    var size: CGSize?

    var body: some View {
        let w = size?.width ?? CGFloat(image?.width ?? 0)
        let h = size?.height ?? CGFloat(image?.height ?? 0)
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: w * scale, height: h * scale)
    }
}

/// 一个精灵
struct SpriteView: View {
    @Environment(\.skin) private var skin
    let sprite: Sprite

    init(_ sprite: Sprite) { self.sprite = sprite }

    var body: some View {
        PixelImage(image: skin.image(sprite), size: sprite.rect.size)
    }
}

/// 精灵按钮：按下时显示按下态
struct SpriteButton: View {
    let normal: Sprite
    let pressed: Sprite
    let label: String
    /// 点击区域向外扩展（皮肤像素）：标题栏那种 9 像素的小按钮手指很难点中
    var hitSlop: EdgeInsets = EdgeInsets()
    let action: () -> Void

    @State private var taps = 0

    init(normal: Sprite, pressed: Sprite, label: String, hitSlop: EdgeInsets = EdgeInsets(), action: @escaping () -> Void) {
        self.normal = normal
        self.pressed = pressed
        self.label = label
        self.hitSlop = hitSlop
        self.action = action
    }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: { EmptyView() }
            .buttonStyle(SpriteButtonStyle(normal: normal, pressed: pressed, hitSlop: hitSlop))
            .accessibilityLabel(label)
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

struct SpriteButtonStyle: ButtonStyle {
    let normal: Sprite
    let pressed: Sprite
    var hitSlop = EdgeInsets()
    @Environment(\.skinScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        SpriteView(configuration.isPressed ? pressed : normal)
            .padding(scaled(hitSlop))
            .contentShape(Rectangle())
            .padding(scaled(hitSlop, sign: -1))
    }

    private func scaled(_ e: EdgeInsets, sign: CGFloat = 1) -> EdgeInsets {
        EdgeInsets(top: e.top * scale * sign, leading: e.leading * scale * sign, bottom: e.bottom * scale * sign, trailing: e.trailing * scale * sign)
    }
}

/// 横向滑块（进度、音量、平衡）。value 为 0...1。
struct SkinHSlider: View {
    @Environment(\.skinScale) private var scale
    let width: CGFloat
    let height: CGFloat
    let thumbSize: CGSize
    let thumbY: CGFloat
    let value: Double
    let background: (Double) -> Sprite?
    let thumb: Sprite?
    let thumbPressed: Sprite?
    var label: String
    /// 拖动中（ended=false）与松手（ended=true）
    let onChange: (Double, Bool) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let v = dragValue ?? value
        ZStack(alignment: .topLeading) {
            if let bg = background(v) { SpriteView(bg) }
            if let thumb {
                SpriteView(dragValue != nil ? (thumbPressed ?? thumb) : thumb)
                    .offset(x: CGFloat(v) * (width - thumbSize.width) * scale, y: thumbY * scale)
            }
        }
        .frame(width: width * scale, height: height * scale, alignment: .topLeading)
        .padding(.vertical, 8 * scale)
        .contentShape(Rectangle())
        .padding(.vertical, -8 * scale)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let nv = valueFor(g.location.x)
                    dragValue = nv
                    onChange(nv, false)
                }
                .onEnded { g in
                    let nv = valueFor(g.location.x)
                    dragValue = nil
                    onChange(nv, true)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(v * 100))%")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            onChange(min(1, max(0, value + step)), true)
        }
    }

    private func valueFor(_ x: CGFloat) -> Double {
        let px = x / scale - thumbSize.width / 2
        return Double(min(1, max(0, px / (width - thumbSize.width))))
    }
}

/// 经典皮肤字体的一行文字；含有皮肤字体没有的字符（如中文）时改用系统字体，颜色取自皮肤
struct SkinText: View {
    @Environment(\.skin) private var skin
    @Environment(\.skinScale) private var scale
    let text: String

    var body: some View {
        if Skin.canRenderWithBitmapFont(text) {
            PixelImage(image: skin.renderText(text))
        } else {
            Text(text)
                .font(.system(size: 6.6 * scale, weight: .medium))
                .foregroundStyle(skin.textColors.foreground.color)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 6 * scale)
        }
    }
}

/// 循环滚动的文字区
struct Marquee: View {
    @Environment(\.skinScale) private var scale
    let text: String
    let width: CGFloat
    @State private var textWidth: CGFloat = 0

    var body: some View {
        let gap = 25 * scale
        let needsScroll = textWidth > width * scale
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !needsScroll)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = textWidth + gap
            let offset = needsScroll && cycle > 0 ? -CGFloat((t * 30 * Double(scale)).truncatingRemainder(dividingBy: Double(cycle))) : 0
            HStack(spacing: gap) {
                SkinText(text: text)
                    .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
                if needsScroll { SkinText(text: text) }
            }
            .offset(x: offset)
        }
        .frame(width: width * scale, height: 6 * scale, alignment: .leading)
        .clipped()
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}
