// 精灵图坐标与字体映射移植自 Webamp（https://github.com/captbaritone/webamp，MIT License，
// Copyright (c) 2015 Jordan Eldredge）。详见 THIRD_PARTY_LICENSES.md。

import CoreGraphics

/// 经典皮肤包里的位图文件
public enum SkinSheet: String, CaseIterable, Sendable {
    case main, titlebar, cbuttons, numbers, numsEx, playpaus, monoster, posbar, volume, balance, shufrep, text, eqmain, pledit

    public var fileName: String {
        switch self {
        case .numsEx: "nums_ex.bmp"
        default: "\(rawValue).bmp"
        }
    }

    /// 标准尺寸（默认皮肤按此生成）
    public var size: CGSize {
        switch self {
        case .main: CGSize(width: 275, height: 116)
        case .titlebar: CGSize(width: 344, height: 87)
        case .cbuttons: CGSize(width: 136, height: 36)
        case .numbers: CGSize(width: 99, height: 13)
        case .numsEx: CGSize(width: 108, height: 13)
        case .playpaus: CGSize(width: 42, height: 9)
        case .monoster: CGSize(width: 56, height: 24)
        case .posbar: CGSize(width: 307, height: 10)
        case .volume: CGSize(width: 68, height: 433)
        case .balance: CGSize(width: 47, height: 433)
        case .shufrep: CGSize(width: 92, height: 85)
        case .text: CGSize(width: 155, height: 18)
        case .eqmain: CGSize(width: 275, height: 315)
        case .pledit: CGSize(width: 280, height: 186)
        }
    }
}

public struct Sprite: Hashable, Sendable {
    public var sheet: SkinSheet
    public var rect: CGRect

    public init(_ sheet: SkinSheet, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        self.sheet = sheet
        self.rect = CGRect(x: x, y: y, width: w, height: h)
    }
}

/// 所有用到的精灵
public enum S {
    // 主窗口
    public static let mainBackground = Sprite(.main, 0, 0, 275, 116)
    public static let titleBar = Sprite(.titlebar, 27, 15, 275, 14)
    public static let titleBarSelected = Sprite(.titlebar, 27, 0, 275, 14)
    public static let optionsButton = Sprite(.titlebar, 0, 0, 9, 9)
    public static let optionsButtonDown = Sprite(.titlebar, 0, 9, 9, 9)
    public static let minimizeButton = Sprite(.titlebar, 9, 0, 9, 9)
    public static let minimizeButtonDown = Sprite(.titlebar, 9, 9, 9, 9)
    public static let shadeButton = Sprite(.titlebar, 0, 18, 9, 9)
    public static let shadeButtonDown = Sprite(.titlebar, 9, 18, 9, 9)
    public static let closeButton = Sprite(.titlebar, 18, 0, 9, 9)
    public static let closeButtonDown = Sprite(.titlebar, 18, 9, 9, 9)

    public static let previous = Sprite(.cbuttons, 0, 0, 23, 18)
    public static let previousDown = Sprite(.cbuttons, 0, 18, 23, 18)
    public static let play = Sprite(.cbuttons, 23, 0, 23, 18)
    public static let playDown = Sprite(.cbuttons, 23, 18, 23, 18)
    public static let pause = Sprite(.cbuttons, 46, 0, 23, 18)
    public static let pauseDown = Sprite(.cbuttons, 46, 18, 23, 18)
    public static let stop = Sprite(.cbuttons, 69, 0, 23, 18)
    public static let stopDown = Sprite(.cbuttons, 69, 18, 23, 18)
    public static let next = Sprite(.cbuttons, 92, 0, 23, 18)
    public static let nextDown = Sprite(.cbuttons, 92, 18, 22, 18)
    public static let eject = Sprite(.cbuttons, 114, 0, 22, 16)
    public static let ejectDown = Sprite(.cbuttons, 114, 16, 22, 16)

    public static let stereo = Sprite(.monoster, 0, 12, 29, 12)
    public static let stereoOn = Sprite(.monoster, 0, 0, 29, 12)
    public static let mono = Sprite(.monoster, 29, 12, 27, 12)
    public static let monoOn = Sprite(.monoster, 29, 0, 27, 12)

    public static let playing = Sprite(.playpaus, 0, 0, 9, 9)
    public static let paused = Sprite(.playpaus, 9, 0, 9, 9)
    public static let stopped = Sprite(.playpaus, 18, 0, 9, 9)
    public static let notWorking = Sprite(.playpaus, 36, 0, 3, 9)
    public static let working = Sprite(.playpaus, 39, 0, 3, 9)

    public static func digit(_ n: Int, ex: Bool) -> Sprite { Sprite(ex ? .numsEx : .numbers, CGFloat(n * 9), 0, 9, 13) }
    public static let minus = Sprite(.numbers, 20, 6, 5, 1)
    public static let noMinus = Sprite(.numbers, 9, 6, 5, 1)
    public static let minusEx = Sprite(.numsEx, 99, 0, 9, 13)
    public static let noMinusEx = Sprite(.numsEx, 90, 0, 9, 13)

    public static let positionBackground = Sprite(.posbar, 0, 0, 248, 10)
    public static let positionThumb = Sprite(.posbar, 248, 0, 29, 10)
    public static let positionThumbSelected = Sprite(.posbar, 278, 0, 29, 10)

    /// 音量背景第 n 帧（0...27）
    public static func volumeFrame(_ n: Int) -> Sprite { Sprite(.volume, 0, CGFloat(n * 15), 68, 13) }
    public static let volumeThumb = Sprite(.volume, 15, 422, 14, 11)
    public static let volumeThumbSelected = Sprite(.volume, 0, 422, 14, 11)
    public static func balanceFrame(_ n: Int) -> Sprite { Sprite(.balance, 9, CGFloat(n * 15), 38, 13) }
    public static let balanceThumb = Sprite(.balance, 15, 422, 14, 11)
    public static let balanceThumbSelected = Sprite(.balance, 0, 422, 14, 11)

    public static func repeatButton(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, 0, CGFloat((on ? 30 : 0) + (down ? 15 : 0)), 28, 15) }
    public static func shuffleButton(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, 28, CGFloat((on ? 30 : 0) + (down ? 15 : 0)), 47, 15) }
    public static func eqButton(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, down ? 46 : 0, on ? 73 : 61, 23, 12) }
    public static func playlistButton(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, down ? 69 : 23, on ? 73 : 61, 23, 12) }

    // 均衡器窗口
    public static let eqBackground = Sprite(.eqmain, 0, 0, 275, 116)
    public static let eqTitleBar = Sprite(.eqmain, 0, 149, 275, 14)
    public static let eqTitleBarSelected = Sprite(.eqmain, 0, 134, 275, 14)
    public static let eqCloseButton = Sprite(.eqmain, 0, 116, 9, 9)
    public static let eqCloseButtonDown = Sprite(.eqmain, 0, 125, 9, 9)
    public static func eqSliderFrame(_ n: Int) -> Sprite {
        Sprite(.eqmain, CGFloat(13 + (n % 14) * 15), CGFloat(164 + (n / 14) * 65), 14, 63)
    }
    public static let eqSliderThumb = Sprite(.eqmain, 0, 164, 11, 11)
    public static let eqSliderThumbSelected = Sprite(.eqmain, 0, 176, 11, 11)
    public static func eqOnButton(on: Bool, down: Bool) -> Sprite {
        Sprite(.eqmain, [[10, 128], [69, 187]][on ? 1 : 0][down ? 1 : 0], 119, 26, 12)
    }
    public static func eqAutoButton(on: Bool, down: Bool) -> Sprite {
        Sprite(.eqmain, [[36, 154], [95, 213]][on ? 1 : 0][down ? 1 : 0], 119, 32, 12)
    }
    public static let eqPresetsButton = Sprite(.eqmain, 224, 164, 44, 12)
    public static let eqPresetsButtonDown = Sprite(.eqmain, 224, 176, 44, 12)
    public static let eqGraphBackground = Sprite(.eqmain, 0, 294, 113, 19)
    public static let eqGraphLineColors = Sprite(.eqmain, 115, 294, 1, 19)
    public static let eqPreampLine = Sprite(.eqmain, 0, 314, 113, 1)

    // 播放列表窗口
    public static let plTopLeft = Sprite(.pledit, 0, 0, 25, 20)
    public static let plTitle = Sprite(.pledit, 26, 0, 100, 20)
    public static let plTopTile = Sprite(.pledit, 127, 0, 25, 20)
    public static let plTopRight = Sprite(.pledit, 153, 0, 25, 20)
    public static let plTopLeftInactive = Sprite(.pledit, 0, 21, 25, 20)
    public static let plTitleInactive = Sprite(.pledit, 26, 21, 100, 20)
    public static let plTopTileInactive = Sprite(.pledit, 127, 21, 25, 20)
    public static let plTopRightInactive = Sprite(.pledit, 153, 21, 25, 20)
    public static let plLeftTile = Sprite(.pledit, 0, 42, 12, 29)
    public static let plRightTile = Sprite(.pledit, 31, 42, 20, 29)
    public static let plBottomTile = Sprite(.pledit, 179, 0, 25, 38)
    public static let plBottomLeft = Sprite(.pledit, 0, 72, 125, 38)
    public static let plBottomRight = Sprite(.pledit, 126, 72, 150, 38)
    public static let plVisualizer = Sprite(.pledit, 205, 0, 75, 38)
    public static let plScrollHandle = Sprite(.pledit, 52, 53, 8, 18)
    public static let plScrollHandleSelected = Sprite(.pledit, 61, 53, 8, 18)
    public static let plCloseSelected = Sprite(.pledit, 52, 42, 9, 9)

    // 文字（text.bmp，每个字符 5x6）
    public static let charWidth: CGFloat = 5
    public static let charHeight: CGFloat = 6

    public static let fontLookup: [Character: (row: Int, col: Int)] = {
        var m: [Character: (Int, Int)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[c] = (0, i) }
        m["\""] = (0, 26); m["@"] = (0, 27); m[" "] = (0, 30)
        for (i, c) in "0123456789".enumerated() { m[c] = (1, i) }
        let row1: [(Character, Int)] = [
            ("…", 10), (".", 11), (":", 12), ("(", 13), (")", 14), ("-", 15), ("'", 16), ("!", 17), ("_", 18), ("+", 19),
            ("\\", 20), ("/", 21), ("[", 22), ("]", 23), ("^", 24), ("&", 25), ("%", 26), (",", 27), ("=", 28), ("$", 29), ("#", 30),
            ("<", 22), (">", 23), ("{", 22), ("}", 23),
        ]
        for (c, i) in row1 { m[c] = (1, i) }
        m["å"] = (2, 0); m["ö"] = (2, 1); m["ä"] = (2, 2); m["?"] = (2, 3); m["*"] = (2, 4)
        return m
    }()

    public static func character(_ c: Character) -> Sprite? {
        let lower = Character(c.lowercased())
        guard let pos = fontLookup[lower] else { return nil }
        return Sprite(.text, CGFloat(pos.col) * charWidth, CGFloat(pos.row) * charHeight, charWidth, charHeight)
    }
}

/// 控件在窗口内的位置（像素坐标，原点左上）
public enum SkinLayout {
    public static let windowSize = CGSize(width: 275, height: 116)

    public static let options = CGPoint(x: 6, y: 3)
    public static let minimize = CGPoint(x: 244, y: 3)
    public static let shade = CGPoint(x: 254, y: 3)
    public static let close = CGPoint(x: 264, y: 3)

    public static let playStatus = CGPoint(x: 26, y: 28)
    public static let workIndicator = CGPoint(x: 24, y: 28)
    public static let time = CGPoint(x: 39, y: 26)
    public static let minus = CGPoint(x: 38, y: 32)
    public static let digitOffsets: [CGFloat] = [9, 21, 39, 51]
    public static let visualizer = CGRect(x: 24, y: 43, width: 76, height: 16)
    public static let marquee = CGRect(x: 111, y: 27, width: 154, height: 6)
    public static let kbps = CGRect(x: 111, y: 43, width: 15, height: 6)
    public static let khz = CGRect(x: 156, y: 43, width: 10, height: 6)
    public static let mono = CGPoint(x: 212, y: 41)
    public static let stereo = CGPoint(x: 239, y: 41)
    public static let volume = CGRect(x: 107, y: 57, width: 68, height: 13)
    public static let balance = CGRect(x: 177, y: 57, width: 38, height: 13)
    public static let eqButton = CGPoint(x: 219, y: 58)
    public static let playlistButton = CGPoint(x: 242, y: 58)
    public static let position = CGRect(x: 16, y: 72, width: 248, height: 10)
    public static let previous = CGPoint(x: 16, y: 88)
    public static let play = CGPoint(x: 39, y: 88)
    public static let pause = CGPoint(x: 62, y: 88)
    public static let stop = CGPoint(x: 85, y: 88)
    public static let next = CGPoint(x: 108, y: 88)
    public static let eject = CGPoint(x: 136, y: 89)
    public static let shuffle = CGPoint(x: 164, y: 89)
    public static let repeatButton = CGPoint(x: 210, y: 89)
    public static let about = CGRect(x: 253, y: 91, width: 13, height: 15)

    // 均衡器
    public static let eqClose = CGPoint(x: 264, y: 3)
    public static let eqOn = CGPoint(x: 14, y: 18)
    public static let eqAuto = CGPoint(x: 40, y: 18)
    public static let eqPresets = CGPoint(x: 217, y: 18)
    public static let eqGraph = CGPoint(x: 86, y: 17)
    public static let eqPreamp = CGPoint(x: 21, y: 38)
    public static func eqBand(_ i: Int) -> CGPoint { CGPoint(x: 78 + CGFloat(i) * 18, y: 38) }
    public static let eqSliderSize = CGSize(width: 14, height: 63)
}
