import CoreGraphics
import Foundation

/// Amplayer 原创默认皮肤 "Amplayer Graphite"：全部用代码绘制，坐标布局与经典皮肤一致。
enum DefaultSkin {
    // 配色
    static let frame = SkinColor(hex: "#2A2D34")!
    static let frameLight = SkinColor(hex: "#4A4F5A")!
    static let frameDark = SkinColor(hex: "#111216")!
    static let lcd = SkinColor(hex: "#07110C")!
    static let lcdGrid = SkinColor(hex: "#10241A")!
    static let accent = SkinColor(hex: "#3CF0A0")!
    static let accentDim = SkinColor(hex: "#1E6B4C")!
    static let segmentOff = SkinColor(hex: "#0F2419")!
    static let titleTop = SkinColor(hex: "#3D4250")!
    static let titleBottom = SkinColor(hex: "#24272E")!
    static let buttonTop = SkinColor(hex: "#454A55")!
    static let buttonBottom = SkinColor(hex: "#2C2F37")!
    static let buttonDownTop = SkinColor(hex: "#1B1D22")!
    static let buttonDownBottom = SkinColor(hex: "#25282E")!
    static let icon = SkinColor(hex: "#D8DEE9")!
    static let warm = SkinColor(hex: "#FFD166")!
    static let hot = SkinColor(hex: "#FF5E5B")!

    static func make() -> Skin {
        var sheets: [SkinSheet: CGImage] = [:]
        for sheet in SkinSheet.allCases {
            let p = Painter(sheet.size)
            switch sheet {
            case .main: drawMain(p)
            case .titlebar: drawTitleBar(p)
            case .cbuttons: drawControlButtons(p)
            case .numbers: drawNumbers(p, ex: false)
            case .numsEx: drawNumbers(p, ex: true)
            case .playpaus: drawPlayPause(p)
            case .monoster: drawMonoStereo(p)
            case .posbar: drawPositionBar(p)
            case .volume: drawVolume(p, balance: false)
            case .balance: drawVolume(p, balance: true)
            case .shufrep: drawShuffleRepeat(p)
            case .text: drawText(p)
            case .eqmain: drawEqualizer(p)
            case .pledit: drawPlaylist(p)
            }
            sheets[sheet] = p.image()
        }
        return Skin(id: "amplayer-graphite", name: "Amplayer Graphite", sheets: sheets, visColors: visColors, playlistStyle: .fallback, hasNumsEx: false)
    }

    static let visColors: [SkinColor] = {
        var c: [SkinColor] = [lcd, lcdGrid]
        // 2...17：频谱从顶部（热）到底部（冷）
        for i in 0..<16 {
            let t = CGFloat(i) / 15
            let from = t < 0.4 ? hot : warm
            let to = t < 0.4 ? warm : accent
            let local = t < 0.4 ? t / 0.4 : (t - 0.4) / 0.6
            c.append(mix(from, to, local))
        }
        // 18...22：示波器亮到暗
        for i in 0..<5 { c.append(mix(accent, accentDim, CGFloat(i) / 4)) }
        c.append(SkinColor(1, 1, 1))
        return c
    }()

    static func mix(_ a: SkinColor, _ b: SkinColor, _ t: CGFloat) -> SkinColor {
        SkinColor(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    // MARK: 主窗口

    static func drawMain(_ p: Painter) {
        p.fill(0, 0, 275, 116, frame)
        p.bevel(0, 0, 275, 116, light: frameLight, dark: frameDark)
        // 左侧显示屏
        p.inset(10, 21, 95, 41, lcd)
        for y in stride(from: 23, to: 61, by: 2) { p.fill(11, y, 93, 1, lcdGrid.with(alpha: 0.35)) }
        // 分钟与秒之间的冒号（经典皮肤里画在背景上）
        p.fill(72, 29, 2, 2, accent)
        p.fill(72, 35, 2, 2, accent)
        // 标题滚动区、码率区
        p.inset(108, 22, 160, 15, lcd)
        p.inset(108, 40, 21, 11, lcd)
        p.inset(153, 40, 16, 11, lcd)
        p.text("kbps", 131, 43, accentDim)
        p.text("khz", 171, 43, accentDim)
        // 音量/平衡标签
        p.text("vol", 107, 52, frameLight)
        p.text("bal", 177, 52, frameLight)
        // 按钮区分隔线
        p.fill(10, 85, 255, 1, frameDark)
        p.fill(10, 86, 255, 1, frameLight.with(alpha: 0.5))
        // 标志
        p.text("amp", 250, 95, accent)
        p.fill(246, 102, 11, 1, accentDim)
    }

    static func drawTitleBar(_ p: Painter) {
        // 标题栏：选中 (27,0)，未选中 (27,15)
        for (y, active) in [(0, true), (15, false)] {
            p.gradient(27, y, 275, 14, active ? titleTop : frame, active ? titleBottom : frameDark)
            p.fill(27, y, 275, 1, active ? frameLight : frame)
            let groove = active ? accentDim : frameLight.with(alpha: 0.4)
            for x in [20, 162] {
                for gy in stride(from: 4, through: 9, by: 2) { p.fill(27 + x, y + gy, x == 20 ? 115 : 78, 1, groove) }
            }
            p.text("amplayer", 27 + 140 - 18, y + 4, active ? accent : frameLight)
        }
        // 9x9 小按钮：options、minimize、close、shade
        let buttons: [(Int, Int, String)] = [(0, 0, "options"), (9, 0, "min"), (18, 0, "close"), (0, 18, "shade")]
        for (x, y, kind) in buttons {
            for down in [false, true] {
                let by = y + (down && y == 0 ? 9 : 0)
                let bx = x + (down && y == 18 ? 9 : 0)
                p.gradient(bx, by, 9, 9, down ? buttonDownTop : buttonTop, down ? buttonDownBottom : buttonBottom)
                p.bevel(bx, by, 9, 9, light: down ? frameDark : frameLight, dark: frameDark)
                let c = down ? accent : icon
                switch kind {
                case "options": p.fill(bx + 2, by + 3, 5, 1, c); p.fill(bx + 2, by + 5, 5, 1, c)
                case "min": p.fill(bx + 2, by + 6, 5, 1, c)
                case "close":
                    for i in 0..<5 { p.fill(bx + 2 + i, by + 2 + i, 1, 1, c); p.fill(bx + 6 - i, by + 2 + i, 1, 1, c) }
                default: p.stroke(bx + 2, by + 2, 5, 5, c)
                }
            }
        }
    }

    static func drawControlButtons(_ p: Painter) {
        let widths = [23, 23, 23, 23, 22, 22]
        var x = 0
        for (i, w) in widths.enumerated() {
            let isEject = i == 5
            let h = isEject ? 16 : 18
            for down in [false, true] {
                let y = down ? h : 0
                p.gradient(x, y, w, h, down ? buttonDownTop : buttonTop, down ? buttonDownBottom : buttonBottom)
                p.bevel(x, y, w, h, light: down ? frameDark : frameLight, dark: frameDark)
                let c = down ? accent : icon
                let cx = x + w / 2, cy = y + h / 2
                switch i {
                case 0: // 上一首
                    p.fill(cx - 5, cy - 4, 2, 9, c)
                    p.triangle(left: true, x: cx - 3, y: cy - 4, w: 4, h: 9, c)
                    p.triangle(left: true, x: cx + 1, y: cy - 4, w: 4, h: 9, c)
                case 1: // 播放
                    p.triangle(left: false, x: cx - 3, y: cy - 4, w: 6, h: 9, c)
                case 2: // 暂停
                    p.fill(cx - 4, cy - 4, 3, 9, c)
                    p.fill(cx + 1, cy - 4, 3, 9, c)
                case 3: // 停止
                    p.fill(cx - 4, cy - 4, 8, 8, c)
                case 4: // 下一首
                    p.triangle(left: false, x: cx - 5, y: cy - 4, w: 4, h: 9, c)
                    p.triangle(left: false, x: cx - 1, y: cy - 4, w: 4, h: 9, c)
                    p.fill(cx + 3, cy - 4, 2, 9, c)
                default: // 弹出
                    p.triangleUp(x: cx - 5, y: cy - 5, w: 10, h: 5, c)
                    p.fill(cx - 5, cy + 2, 10, 2, c)
                }
            }
            x += w
        }
    }

    /// 七段数码管
    static func drawNumbers(_ p: Painter, ex: Bool) {
        p.fill(0, 0, Int(p.size.width), 13, lcd)
        // 段：a 上、b 右上、c 右下、d 下、e 左下、f 左上、g 中
        let map: [[Bool]] = [
            [true, true, true, true, true, true, false], [false, true, true, false, false, false, false],
            [true, true, false, true, true, false, true], [true, true, true, true, false, false, true],
            [false, true, true, false, false, true, true], [true, false, true, true, false, true, true],
            [true, false, true, true, true, true, true], [true, true, true, false, false, false, false],
            [true, true, true, true, true, true, true], [true, true, true, true, false, true, true],
        ]
        func segments(_ ox: Int, _ on: [Bool]) {
            let rects: [(Int, Int, Int, Int)] = [
                (2, 0, 5, 2), (7, 2, 2, 4), (7, 7, 2, 4), (2, 11, 5, 2), (0, 7, 2, 4), (0, 2, 2, 4), (2, 6, 5, 1),
            ]
            for (s, r) in rects.enumerated() {
                p.fill(ox + r.0, r.1, r.2, r.3, on[s] ? accent : segmentOff)
            }
        }
        for d in 0..<10 { segments(d * 9, map[d]) }
        // numbers.bmp：(9,6) 处是“无负号”，(20,6) 处是负号——正好对应 1 与 2 的中段
        if ex {
            segments(90, Array(repeating: false, count: 7))
            segments(99, [false, false, false, false, false, false, true])
        } else {
            p.fill(9, 6, 5, 1, lcd)
        }
    }

    static func drawPlayPause(_ p: Painter) {
        p.fill(0, 0, 42, 9, lcd)
        p.triangle(left: false, x: 2, y: 1, w: 5, h: 7, accent) // 播放中
        p.fill(10, 1, 2, 7, warm); p.fill(14, 1, 2, 7, warm) // 暂停
        p.fill(20, 2, 5, 5, accentDim) // 停止
        p.fill(36, 0, 3, 9, lcd) // 未加载
        p.fill(39, 1, 2, 7, accent) // 加载中
    }

    static func drawMonoStereo(_ p: Painter) {
        for (y, on) in [(0, true), (12, false)] {
            p.fill(0, y, 56, 12, frame)
            p.inset(0, y + 1, 29, 10, lcd)
            p.inset(29, y + 1, 27, 10, lcd)
            p.text("stereo", 3, y + 3, on ? accent : segmentOff)
            p.text("mono", 35, y + 3, on ? accent : segmentOff)
        }
    }

    static func drawPositionBar(_ p: Painter) {
        p.fill(0, 0, 248, 10, frame)
        p.inset(0, 2, 248, 6, frameDark)
        p.fill(1, 4, 246, 2, lcd)
        for (x, selected) in [(248, false), (278, true)] {
            p.gradient(x, 0, 29, 10, selected ? accent : buttonTop, selected ? accentDim : buttonBottom)
            p.bevel(x, 0, 29, 10, light: selected ? accent : frameLight, dark: frameDark)
            for gx in [11, 14, 17] { p.fill(x + gx, 3, 1, 4, selected ? lcd : frameDark) }
        }
    }

    /// volume.bmp / balance.bmp：28 帧背景 + 滑块
    static func drawVolume(_ p: Painter, balance: Bool) {
        let width = balance ? 47 : 68
        p.fill(0, 0, width, 433, frame)
        for i in 0..<28 {
            let y = i * 15
            let t = CGFloat(i) / 27
            let x0 = balance ? 9 : 0
            let w = balance ? 38 : 68
            p.inset(x0, y + 4, w, 5, frameDark)
            if balance {
                let c = mix(accent, hot, t)
                p.fill(x0 + 19 - Int(t * 18), y + 5, max(1, Int(t * 36)), 3, c.with(alpha: 0.35 + 0.65 * t))
                p.fill(x0 + 18, y + 3, 2, 7, frameLight)
            } else {
                let fillW = Int(t * CGFloat(w - 2))
                if fillW > 0 { p.fill(x0 + 1, y + 5, fillW, 3, mix(accentDim, i > 22 ? warm : accent, t)) }
            }
        }
        for (x, selected) in [(0, true), (15, false)] {
            p.gradient(x, 422, 14, 11, selected ? accent : buttonTop, selected ? accentDim : buttonBottom)
            p.bevel(x, 422, 14, 11, light: selected ? accent : frameLight, dark: frameDark)
            p.fill(x + 6, 424, 2, 7, selected ? lcd : frameDark)
        }
    }

    static func drawShuffleRepeat(_ p: Painter) {
        p.fill(0, 0, 92, 85, frame)
        func button(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ label: String, on: Bool, down: Bool) {
            p.gradient(x, y, w, h, down ? buttonDownTop : buttonTop, down ? buttonDownBottom : buttonBottom)
            p.bevel(x, y, w, h, light: down ? frameDark : frameLight, dark: frameDark)
            let textW = label.count * 4 - 1
            p.text(label, x + 2 + (w - 6 - textW) / 2 + 3, y + (h - 5) / 2, on ? accent : icon)
            p.fill(x + 3, y + h / 2 - 1, 2, 2, on ? accent : segmentOff)
        }
        for (i, y) in [0, 15, 30, 45].enumerated() {
            let on = i >= 2, down = i % 2 == 1
            button(0, y, 28, 15, "rep", on: on, down: down)
            button(28, y, 47, 15, "shuffle", on: on, down: down)
        }
        for (x, down) in [(0, false), (46, true)] {
            for (y, on) in [(61, false), (73, true)] { button(x, y, 23, 12, "eq", on: on, down: down) }
        }
        for (x, down) in [(23, false), (69, true)] {
            for (y, on) in [(61, false), (73, true)] { button(x, y, 23, 12, "pl", on: on, down: down) }
        }
    }

    static func drawText(_ p: Painter) {
        p.fill(0, 0, 155, 18, lcd)
        for (c, pos) in S.fontLookup {
            // 同一位置的多个字符（如 < 与 [）只画一次
            if "<>{}".contains(c) { continue }
            p.glyph(c, pos.col * 5, pos.row * 6, accent)
        }
    }

    // MARK: 均衡器

    static let bandLabels = ["60", "170", "310", "600", "1k", "3k", "6k", "12k", "14k", "16k"]

    static func drawEqualizer(_ p: Painter) {
        p.fill(0, 0, 275, 315, frame)
        p.bevel(0, 0, 275, 116, light: frameLight, dark: frameDark)
        // 滑块槽与标签
        p.text("preamp", 13, 104, icon)
        for i in 0..<10 {
            let x = 78 + i * 18
            p.inset(x + 5, 38, 4, 63, frameDark)
            let label = bandLabels[i]
            p.text(label, x + 7 - (label.count * 4 - 1) / 2, 104, icon)
        }
        p.inset(26, 38, 4, 63, frameDark)
        p.text("+12db", 45, 37, accentDim)
        p.text("+0db", 49, 66, accentDim)
        p.text("-12db", 45, 95, accentDim)
        p.fill(67, 69, 8, 1, accentDim)

        // 关闭按钮
        for (y, down) in [(116, false), (125, true)] {
            p.gradient(0, y, 9, 9, down ? buttonDownTop : buttonTop, down ? buttonDownBottom : buttonBottom)
            p.bevel(0, y, 9, 9, light: down ? frameDark : frameLight, dark: frameDark)
            for i in 0..<5 { p.fill(2 + i, y + 2 + i, 1, 1, down ? accent : icon); p.fill(6 - i, y + 2 + i, 1, 1, down ? accent : icon) }
        }
        // ON / AUTO：x 依次为 关、开、关按下、开按下
        let onXs = [10, 69, 128, 187], autoXs = [36, 95, 154, 213]
        for k in 0..<4 {
            let on = k == 1 || k == 3, down = k >= 2
            for (x, w, label) in [(onXs[k], 26, "on"), (autoXs[k], 32, "auto")] {
                p.gradient(x, 119, w, 12, down ? buttonDownTop : buttonTop, down ? buttonDownBottom : buttonBottom)
                p.bevel(x, 119, w, 12, light: down ? frameDark : frameLight, dark: frameDark)
                p.fill(x + 3, 124, 2, 2, on ? accent : segmentOff)
                p.text(label, x + 8, 123, on ? accent : icon)
            }
        }
        // 标题栏
        for (y, active) in [(134, true), (149, false)] {
            p.gradient(0, y, 275, 14, active ? titleTop : frame, active ? titleBottom : frameDark)
            p.fill(0, y, 275, 1, active ? frameLight : frame)
            for gy in stride(from: 4, through: 9, by: 2) {
                p.fill(8, y + gy, 100, 1, active ? accentDim : frameLight.with(alpha: 0.4))
                p.fill(168, y + gy, 90, 1, active ? accentDim : frameLight.with(alpha: 0.4))
            }
            p.text("equalizer", 118, y + 4, active ? accent : frameLight)
        }
        // 滑块
        for (y, selected) in [(164, false), (176, true)] {
            p.gradient(0, y, 11, 11, selected ? accent : buttonTop, selected ? accentDim : buttonBottom)
            p.bevel(0, y, 11, 11, light: selected ? accent : frameLight, dark: frameDark)
            p.fill(2, y + 5, 7, 1, selected ? lcd : frameDark)
        }
        // 28 帧滑块背景：自下而上点亮
        for i in 0..<28 {
            let x = 13 + (i % 14) * 15, y = 164 + (i / 14) * 65
            p.fill(x, y, 14, 63, frame)
            p.inset(x + 5, y, 4, 63, frameDark)
            let level = Int(CGFloat(i) / 27 * 61)
            for row in 0..<level {
                let t = CGFloat(row) / 61
                p.fill(x + 6, y + 62 - row, 2, 1, mix(accentDim, t > 0.5 ? warm : accent, t))
            }
        }
        // PRESETS
        for (y, down) in [(164, false), (176, true)] {
            p.gradient(224, y, 44, 12, down ? buttonDownTop : buttonTop, down ? buttonDownBottom : buttonBottom)
            p.bevel(224, y, 44, 12, light: down ? frameDark : frameLight, dark: frameDark)
            p.text("presets", 232, y + 4, down ? accent : icon)
        }
        // 曲线图
        p.fill(0, 294, 113, 19, lcd)
        for x in stride(from: 0, to: 113, by: 4) { p.fill(x, 303, 2, 1, lcdGrid) }
        for y in 0..<19 {
            let t = CGFloat(y) / 18
            p.fill(115, 294 + y, 1, 1, t < 0.5 ? mix(hot, warm, t * 2) : mix(warm, accent, (t - 0.5) * 2))
        }
        p.fill(0, 314, 113, 1, accentDim)
    }

    // MARK: 播放列表

    static func drawPlaylist(_ p: Painter) {
        p.fill(0, 0, 280, 186, frame)
        for (y, active) in [(0, true), (21, false)] {
            let top = active ? titleTop : frame, bottom = active ? titleBottom : frameDark
            // 左上角、标题、平铺、右上角
            for (x, w) in [(0, 25), (26, 100), (127, 25), (153, 25)] {
                p.gradient(x, y, w, 20, top, bottom)
                p.fill(x, y, w, 1, active ? frameLight : frame)
                p.fill(x, y + 19, w, 1, frameDark)
            }
            let groove = active ? accentDim : frameLight.with(alpha: 0.4)
            for gy in stride(from: 6, through: 11, by: 2) {
                p.fill(4, y + gy, 21, 1, groove)
                p.fill(127, y + gy, 25, 1, groove)
                p.fill(153, y + gy, 10, 1, groove)
            }
            p.fill(0, y, 1, 20, frameLight)
            p.fill(177, y, 1, 20, frameDark)
            p.text("playlist", 26 + 50 - 15, y + 7, active ? accent : frameLight)
            // 右上角的关闭按钮位置
            p.inset(153 + 14, y + 3, 9, 9, frameDark)
        }
        // 关闭按钮按下态
        p.gradient(52, 42, 9, 9, buttonDownTop, buttonDownBottom)
        for i in 0..<5 { p.fill(54 + i, 44 + i, 1, 1, accent); p.fill(58 - i, 44 + i, 1, 1, accent) }
        // 左右边框（右边带滚动条槽）
        p.fill(0, 42, 12, 29, frame)
        p.fill(0, 42, 1, 29, frameLight)
        p.fill(11, 42, 1, 29, frameDark)
        // 纵向平铺，槽只画左右边，避免出现横向接缝
        p.fill(31, 42, 20, 29, frame)
        p.fill(31 + 7, 42, 10, 29, frameDark)
        p.fill(31 + 7, 42, 1, 29, DefaultSkin.frameDark)
        p.fill(31 + 16, 42, 1, 29, frameLight.with(alpha: 0.6))
        p.fill(50, 42, 1, 29, frameDark)
        // 滚动条滑块
        for (x, selected) in [(52, false), (61, true)] {
            p.gradient(x, 53, 8, 18, selected ? accent : buttonTop, selected ? accentDim : buttonBottom)
            p.bevel(x, 53, 8, 18, light: selected ? accent : frameLight, dark: frameDark)
        }
        // 底部
        p.fill(179, 0, 25, 38, frame)
        p.fill(179, 0, 25, 1, frameLight)
        p.fill(179, 37, 25, 1, frameDark)
        // 左下角：ADD REM SEL MISC
        p.fill(0, 72, 125, 38, frame)
        p.fill(0, 72, 125, 1, frameLight)
        p.fill(0, 72, 1, 38, frameLight)
        p.fill(0, 109, 125, 1, frameDark)
        for (x, label) in [(14, "add"), (43, "rem"), (72, "sel"), (101, "misc")] {
            p.gradient(x, 72 + 8, 22, 18, buttonTop, buttonBottom)
            p.bevel(x, 72 + 8, 22, 18, light: frameLight, dark: frameDark)
            p.text(label, x + 11 - (label.count * 4 - 1) / 2, 72 + 15, icon)
        }
        // 右下角：时间显示 + LIST
        p.fill(126, 72, 150, 38, frame)
        p.fill(126, 72, 150, 1, frameLight)
        p.fill(126, 109, 150, 1, frameDark)
        p.fill(275, 72, 1, 38, frameDark)
        p.inset(126 + 5, 72 + 8, 92, 11, lcd)
        p.inset(126 + 5, 72 + 21, 92, 10, lcd)
        p.gradient(126 + 106, 72 + 8, 22, 18, buttonTop, buttonBottom)
        p.bevel(126 + 106, 72 + 8, 22, 18, light: frameLight, dark: frameDark)
        p.text("list", 126 + 106 + 4, 72 + 15, icon)
        // 可视化区
        p.fill(205, 0, 75, 38, frame)
        p.inset(207, 10, 71, 20, lcd)
    }
}

extension SkinColor {
    func with(alpha: CGFloat) -> SkinColor { SkinColor(r, g, b, alpha) }
}

/// 左上原点的像素画笔
final class Painter {
    let size: CGSize
    private let ctx: CGContext
    private let height: Int

    init(_ size: CGSize) {
        self.size = size
        height = Int(size.height)
        ctx = Skin.makeContext(width: Int(size.width), height: height)!
    }

    func image() -> CGImage { ctx.makeImage()! }

    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: x, y: height - y - h, width: w, height: h)
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: SkinColor) {
        guard w > 0, h > 0 else { return }
        ctx.setFillColor(c.cgColor)
        ctx.fill(rect(x, y, w, h))
    }

    func stroke(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: SkinColor) {
        fill(x, y, w, 1, c); fill(x, y + h - 1, w, 1, c)
        fill(x, y, 1, h, c); fill(x + w - 1, y, 1, h, c)
    }

    /// 凸起边框：左上亮、右下暗
    func bevel(_ x: Int, _ y: Int, _ w: Int, _ h: Int, light: SkinColor, dark: SkinColor) {
        fill(x, y, w, 1, light); fill(x, y, 1, h, light)
        fill(x, y + h - 1, w, 1, dark); fill(x + w - 1, y, 1, h, dark)
    }

    /// 凹陷面板
    func inset(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: SkinColor) {
        fill(x, y, w, h, c)
        bevel(x, y, w, h, light: DefaultSkin.frameDark, dark: DefaultSkin.frameLight.with(alpha: 0.6))
    }

    func gradient(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ top: SkinColor, _ bottom: SkinColor) {
        for row in 0..<h {
            fill(x, y + row, w, 1, DefaultSkin.mix(top, bottom, h > 1 ? CGFloat(row) / CGFloat(h - 1) : 0))
        }
    }

    /// 横向三角形（left 为 true 时尖端朝左）
    func triangle(left: Bool, x: Int, y: Int, w: Int, h: Int, _ c: SkinColor) {
        let half = CGFloat(h) / 2
        for row in 0..<h {
            let dist = abs(CGFloat(row) + 0.5 - half)
            let len = Int((CGFloat(w) * (1 - dist / half)).rounded())
            guard len > 0 else { continue }
            fill(left ? x + w - len : x, y + row, len, 1, c)
        }
    }

    func triangleUp(x: Int, y: Int, w: Int, h: Int, _ c: SkinColor) {
        for row in 0..<h {
            let len = max(1, Int(CGFloat(w) * CGFloat(row + 1) / CGFloat(h)))
            fill(x + (w - len) / 2, y + row, len, 1, c)
        }
    }

    func glyph(_ c: Character, _ x: Int, _ y: Int, _ color: SkinColor) {
        guard let rows = PixelFont.glyphs[c] else { return }
        for (ry, row) in rows.enumerated() {
            for (rx, bit) in row.enumerated() where bit == "x" {
                fill(x + rx, y + ry, 1, 1, color)
            }
        }
    }

    /// 3x5 像素字，字距 4
    func text(_ s: String, _ x: Int, _ y: Int, _ color: SkinColor) {
        for (i, c) in s.lowercased().enumerated() { glyph(c, x + i * 4, y, color) }
    }
}

/// 原创 3x5 像素字体
enum PixelFont {
    static let glyphs: [Character: [String]] = {
        let table: [(Character, String)] = [
            ("a", ".x. x.x xxx x.x x.x"), ("b", "xx. x.x xx. x.x xx."), ("c", ".xx x.. x.. x.. .xx"),
            ("d", "xx. x.x x.x x.x xx."), ("e", "xxx x.. xx. x.. xxx"), ("f", "xxx x.. xx. x.. x.."),
            ("g", ".xx x.. x.x x.x .xx"), ("h", "x.x x.x xxx x.x x.x"), ("i", "xxx .x. .x. .x. xxx"),
            ("j", "..x ..x ..x x.x .x."), ("k", "x.x x.x xx. x.x x.x"), ("l", "x.. x.. x.. x.. xxx"),
            ("m", "x.x xxx xxx x.x x.x"), ("n", "xx. x.x x.x x.x x.x"), ("o", ".x. x.x x.x x.x .x."),
            ("p", "xx. x.x xx. x.. x.."), ("q", ".x. x.x x.x xx. .xx"), ("r", "xx. x.x xx. x.x x.x"),
            ("s", ".xx x.. .x. ..x xx."), ("t", "xxx .x. .x. .x. .x."), ("u", "x.x x.x x.x x.x xxx"),
            ("v", "x.x x.x x.x x.x .x."), ("w", "x.x x.x xxx xxx x.x"), ("x", "x.x x.x .x. x.x x.x"),
            ("y", "x.x x.x .x. .x. .x."), ("z", "xxx ..x .x. x.. xxx"),
            ("0", "xxx x.x x.x x.x xxx"), ("1", ".x. xx. .x. .x. xxx"), ("2", "xx. ..x .x. x.. xxx"),
            ("3", "xx. ..x .x. ..x xx."), ("4", "x.x x.x xxx ..x ..x"), ("5", "xxx x.. xx. ..x xx."),
            ("6", ".xx x.. xxx x.x xxx"), ("7", "xxx ..x .x. .x. .x."), ("8", "xxx x.x xxx x.x xxx"),
            ("9", "xxx x.x xxx ..x xx."),
            ("\"", "x.x x.x ... ... ..."), ("@", ".x. xxx xxx x.. .xx"), ("…", "... ... ... ... x.x"),
            (".", "... ... ... ... .x."), (":", "... .x. ... .x. ..."), ("(", "..x .x. .x. .x. ..x"),
            (")", "x.. .x. .x. .x. x.."), ("-", "... ... xxx ... ..."), ("'", ".x. .x. ... ... ..."),
            ("!", ".x. .x. .x. ... .x."), ("_", "... ... ... ... xxx"), ("+", "... .x. xxx .x. ..."),
            ("\\", "x.. x.. .x. ..x ..x"), ("/", "..x ..x .x. x.. x.."), ("[", "xx. x.. x.. x.. xx."),
            ("]", ".xx ..x ..x ..x .xx"), ("^", ".x. x.x ... ... ..."), ("&", ".x. x.x .x. x.x .xx"),
            ("%", "x.x ..x .x. x.. x.x"), (",", "... ... ... .x. x.."), ("=", "... xxx ... xxx ..."),
            ("$", ".xx xx. .x. .xx xx."), ("#", "x.x xxx x.x xxx x.x"), ("å", ".x. ... xxx x.x x.x"),
            ("ö", "x.x ... xxx x.x xxx"), ("ä", "x.x ... xxx xxx x.x"), ("?", "xx. ..x .x. ... .x."),
            ("*", "x.x .x. x.x ... ..."), (" ", "... ... ... ... ..."),
        ]
        var m: [Character: [String]] = [:]
        for (c, pattern) in table { m[c] = pattern.split(separator: " ").map(String.init) }
        return m
    }()
}
