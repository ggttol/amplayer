import CoreGraphics
import Foundation
import ImageIO

/// RGBA 颜色（0...1）
public struct SkinColor: Hashable, Sendable {
    public var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(r255 r: Int, g: Int, b: Int) {
        self.init(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255)
    }

    /// "#RRGGBB" 或 "RRGGBB"
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        s = String(s.prefix(6))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r255: Int(v >> 16 & 0xFF), g: Int(v >> 8 & 0xFF), b: Int(v & 0xFF))
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// 播放列表配色（pledit.txt）
public struct PlaylistStyle: Sendable, Equatable {
    public var normal: SkinColor
    public var current: SkinColor
    public var normalBackground: SkinColor
    public var selectedBackground: SkinColor
    public var font: String

    public static let fallback = PlaylistStyle(
        normal: SkinColor(hex: "#3CF0A0")!, current: SkinColor(hex: "#FFFFFF")!,
        normalBackground: SkinColor(hex: "#0B130E")!, selectedBackground: SkinColor(hex: "#1F4D3A")!, font: "Arial"
    )

    public static func parse(_ text: String) -> PlaylistStyle {
        var style = fallback
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "normal": style.normal = SkinColor(hex: value) ?? style.normal
            case "current": style.current = SkinColor(hex: value) ?? style.current
            case "normalbg": style.normalBackground = SkinColor(hex: value) ?? style.normalBackground
            case "selectedbg": style.selectedBackground = SkinColor(hex: value) ?? style.selectedBackground
            case "font": style.font = value
            default: break
            }
        }
        return style
    }
}

/// 一套经典皮肤：各位图 + 可视化配色 + 播放列表配色
public final class Skin: @unchecked Sendable, Identifiable {
    public let id: String
    public let name: String
    /// 每张位图；缺失的已用默认皮肤补齐
    private let sheets: [SkinSheet: CGImage]
    /// 24 种可视化颜色（viscolor.txt）
    public let visColors: [SkinColor]
    public let playlistStyle: PlaylistStyle
    /// 是否提供了 nums_ex.bmp
    public let hasNumsEx: Bool

    private let lock = NSLock()
    private var cropCache: [Sprite: CGImage] = [:]

    init(id: String, name: String, sheets: [SkinSheet: CGImage], visColors: [SkinColor], playlistStyle: PlaylistStyle, hasNumsEx: Bool) {
        self.id = id
        self.name = name
        self.sheets = sheets
        self.visColors = visColors
        self.playlistStyle = playlistStyle
        self.hasNumsEx = hasNumsEx
    }

    public func sheet(_ sheet: SkinSheet) -> CGImage? { sheets[sheet] }

    /// 裁出精灵；超出位图范围时返回 nil
    public func image(_ sprite: Sprite) -> CGImage? {
        if let cached = lock.withLock({ cropCache[sprite] }) { return cached }
        guard let sheet = sheets[sprite.sheet] else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        guard bounds.contains(sprite.rect) || bounds.intersects(sprite.rect),
              let cropped = sheet.cropping(to: sprite.rect.intersection(bounds))
        else { return nil }
        lock.withLock { cropCache[sprite] = cropped }
        return cropped
    }

    /// 文字是否都能用皮肤字体（text.bmp）渲染
    public static func canRenderWithBitmapFont(_ text: String) -> Bool {
        text.allSatisfy { S.fontLookup[Character($0.lowercased())] != nil }
    }

    /// 用皮肤字体渲染一行文字（未知字符显示为空格）
    public func renderText(_ text: String) -> CGImage? {
        let chars = Array(text)
        let width = max(1, Int(CGFloat(chars.count) * S.charWidth))
        let height = Int(S.charHeight)
        guard let ctx = Self.makeContext(width: width, height: height) else { return nil }
        if let space = image(S.character(" ")!) {
            for i in 0..<chars.count { ctx.draw(space, in: Self.flipped(CGRect(x: CGFloat(i) * S.charWidth, y: 0, width: S.charWidth, height: S.charHeight), height: height)) }
        }
        for (i, c) in chars.enumerated() {
            guard let sprite = S.character(c), let glyph = image(sprite) else { continue }
            ctx.draw(glyph, in: Self.flipped(CGRect(x: CGFloat(i) * S.charWidth, y: 0, width: S.charWidth, height: S.charHeight), height: height))
        }
        return ctx.makeImage()
    }

    /// 皮肤字体的前景色与背景色（渲染中文等皮肤字体没有的字符时用）
    public lazy var textColors: (foreground: SkinColor, background: SkinColor) = {
        guard let sheet = sheets[.text] else { return (PlaylistStyle.fallback.normal, PlaylistStyle.fallback.normalBackground) }
        let pixels = Self.pixels(of: sheet)
        let bg = pixels.at(150, 2) ?? SkinColor(0, 0, 0)
        // 前景取字母 a～z 区域里与背景差别最大的颜色
        var best = bg
        var bestDistance: CGFloat = -1
        for x in 0..<min(130, sheet.width) {
            for y in 0..<min(6, sheet.height) {
                guard let c = pixels.at(x, y) else { continue }
                let d = abs(c.r - bg.r) + abs(c.g - bg.g) + abs(c.b - bg.b)
                if d > bestDistance { bestDistance = d; best = c }
            }
        }
        return (best, bg)
    }()

    // MARK: 加载

    public static let defaultSkin: Skin = DefaultSkin(palette: .graphite).make()

    /// 从 .wsz（zip）数据加载
    public static func load(wszData data: Data, id: String, name: String) throws -> Skin {
        let zip = try ZipArchive(data: data)
        return build(id: id, name: name) { zip.data(named: $0) }
    }

    /// 从已解压的皮肤目录加载
    public static func load(directory: URL, id: String, name: String) -> Skin {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return build(id: id, name: name) { wanted in
            files.first { $0.lastPathComponent.lowercased() == wanted.lowercased() }.flatMap { try? Data(contentsOf: $0) }
        }
    }

    private static func build(id: String, name: String, file: (String) -> Data?) -> Skin {
        let base = defaultSkin
        var sheets: [SkinSheet: CGImage] = [:]
        var hasNumsEx = false
        for sheet in SkinSheet.allCases {
            if let data = file(sheet.fileName), let image = decodeImage(data) {
                sheets[sheet] = image
                if sheet == .numsEx { hasNumsEx = true }
            }
        }
        // balance.bmp 缺失时经典播放器沿用 volume.bmp
        if sheets[.balance] == nil, let volume = sheets[.volume] { sheets[.balance] = volume }
        for sheet in SkinSheet.allCases where sheets[sheet] == nil {
            sheets[sheet] = base.sheets[sheet]
        }
        let vis = file("viscolor.txt").flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
            .map(parseVisColors) ?? base.visColors
        let style = file("pledit.txt").flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
            .map(PlaylistStyle.parse) ?? base.playlistStyle
        return Skin(id: id, name: name, sheets: sheets, visColors: vis.count >= 24 ? vis : base.visColors, playlistStyle: style, hasNumsEx: hasNumsEx)
    }

    /// viscolor.txt：每行 "r,g,b, // 注释"，共 24 行
    public static func parseVisColors(_ text: String) -> [SkinColor] {
        var colors: [SkinColor] = []
        for line in text.components(separatedBy: .newlines) {
            let numbers = line.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
            guard numbers.count == 3 else { continue }
            colors.append(SkinColor(r255: min(numbers[0], 255), g: min(numbers[1], 255), b: min(numbers[2], 255)))
            if colors.count == 24 { break }
        }
        return colors
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: 位图工具

    static func makeContext(width: Int, height: Int) -> CGContext? {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.interpolationQuality = .none
        ctx?.setShouldAntialias(false)
        return ctx
    }

    /// CGContext 原点在左下，转换成左上原点的矩形
    static func flipped(_ rect: CGRect, height: Int) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
    }

    struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int

        func at(_ x: Int, _ y: Int) -> SkinColor? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let i = (y * width + x) * 4
            return SkinColor(CGFloat(data[i]) / 255, CGFloat(data[i + 1]) / 255, CGFloat(data[i + 2]) / 255)
        }
    }

    static func pixels(of image: CGImage) -> Pixels {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return Pixels(data: data, width: w, height: h)
    }

    /// EQ 曲线颜色（eqmain.bmp 里 1x19 的竖条，从上到下）
    public lazy var eqGraphColors: [SkinColor] = {
        guard let strip = image(S.eqGraphLineColors) else { return Array(repeating: SkinColor(0, 1, 0), count: 19) }
        let px = Self.pixels(of: strip)
        return (0..<19).map { px.at(0, $0) ?? SkinColor(0, 1, 0) }
    }()
}
