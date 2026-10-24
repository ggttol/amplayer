import CoreGraphics

/// 内置皮肤的配色。只给几种主色，其余（高光、阴影、按钮渐变）按比例推出来。
struct SkinPalette: Sendable {
    var id: String
    var name: String
    var frame, frameLight, frameDark: SkinColor
    var lcd, lcdGrid, accent, accentDim, segmentOff: SkinColor
    var titleTop, titleBottom: SkinColor
    var buttonTop, buttonBottom, buttonDownTop, buttonDownBottom: SkinColor
    var icon, warm, hot: SkinColor
    /// 播放列表里当前曲目的文字颜色
    var playlistCurrent: SkinColor

    init(id: String, name: String, frame: String, lcd: String, accent: String,
         icon: String = "#D8DEE9", warm: String = "#FFD166", hot: String = "#FF5E5B",
         current: String = "#FFFFFF", title: String? = nil) {
        func c(_ hex: String) -> SkinColor { SkinColor(hex: hex)! }
        let white = SkinColor(1, 1, 1), black = SkinColor(0, 0, 0)
        let f = c(frame), l = c(lcd), a = c(accent)
        self.id = id
        self.name = name
        self.frame = f
        frameLight = DefaultSkin.mix(f, white, 0.14)
        frameDark = DefaultSkin.mix(f, black, 0.6)
        self.lcd = l
        lcdGrid = DefaultSkin.mix(l, a, 0.12)
        self.accent = a
        accentDim = DefaultSkin.mix(a, l, 0.58)
        segmentOff = DefaultSkin.mix(l, a, 0.08)
        let t = title.map(c) ?? f
        titleTop = DefaultSkin.mix(t, white, 0.1)
        titleBottom = DefaultSkin.mix(t, black, 0.15)
        buttonTop = DefaultSkin.mix(f, white, 0.12)
        buttonBottom = DefaultSkin.mix(f, white, 0.02)
        buttonDownTop = DefaultSkin.mix(f, black, 0.4)
        buttonDownBottom = DefaultSkin.mix(f, black, 0.2)
        self.icon = c(icon)
        self.warm = c(warm)
        self.hot = c(hot)
        playlistCurrent = c(current)
    }

    /// 最初的默认皮肤，颜色保持原样
    static let graphite: SkinPalette = {
        var p = SkinPalette(id: "amplayer-graphite", name: "Amplayer Graphite", frame: "#2A2D34", lcd: "#07110C", accent: "#3CF0A0")
        func c(_ hex: String) -> SkinColor { SkinColor(hex: hex)! }
        p.frameLight = c("#4A4F5A"); p.frameDark = c("#111216")
        p.lcdGrid = c("#10241A"); p.accentDim = c("#1E6B4C"); p.segmentOff = c("#0F2419")
        p.titleTop = c("#3D4250"); p.titleBottom = c("#24272E")
        p.buttonTop = c("#454A55"); p.buttonBottom = c("#2C2F37")
        p.buttonDownTop = c("#1B1D22"); p.buttonDownBottom = c("#25282E")
        return p
    }()

    static let all: [SkinPalette] = [
        graphite,
        SkinPalette(id: "amplayer-nixie", name: "Nixie 辉光", frame: "#2B211B", lcd: "#120804", accent: "#FF8A2A",
                    icon: "#F2DCC8", warm: "#FFC46B", hot: "#FF4D2E", current: "#FFE7CF"),
        SkinPalette(id: "amplayer-ocean", name: "Deep Ocean 深海", frame: "#1D2939", lcd: "#04101A", accent: "#4FD6FF",
                    icon: "#D6E6F5", warm: "#7CF2C8", hot: "#FF7A90", current: "#E8FBFF"),
        SkinPalette(id: "amplayer-sakura", name: "Sakura 樱", frame: "#3A2833", lcd: "#140910", accent: "#FF8FBF",
                    icon: "#F6DCE8", warm: "#FFD1E3", hot: "#FF5C8A", current: "#FFF0F6"),
        SkinPalette(id: "amplayer-synthwave", name: "Synthwave 霓虹", frame: "#231B36", lcd: "#0B0717", accent: "#C77DFF",
                    icon: "#E4D9FF", warm: "#FF9E64", hot: "#FF4F8B", current: "#FFE3F7"),
        SkinPalette(id: "amplayer-ivory", name: "Ivory 象牙", frame: "#BDB6A6", lcd: "#1C2016", accent: "#C6F36B",
                    icon: "#2B2924", warm: "#FFD166", hot: "#FF6B4A", current: "#FFFFFF", title: "#57524A"),
    ]
}

extension Skin {
    /// 内置皮肤（全部原创，代码绘制）
    public static let builtIn: [(id: String, name: String)] = SkinPalette.all.map { ($0.id, $0.name) }

    /// 按 id 生成内置皮肤
    public static func builtIn(id: String) -> Skin? {
        if id == defaultSkin.id { return defaultSkin }
        return SkinPalette.all.first { $0.id == id }.map { DefaultSkin(palette: $0).make() }
    }
}
