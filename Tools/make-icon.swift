// 生成 App 图标（1024x1024 PNG）：swift Tools/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// 图案：一支辉光管（Nixie tube），灯丝弯成八分音符，橙色辉光。全部用代码绘制。
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ stops: [(UInt32, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: locations)!
}

// 背景：暖黑色，中心略亮
ctx.setFillColor(color(0x070504))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.drawRadialGradient(gradient([(0x3A1A08, 1), (0x140A05, 1), (0x070504, 1)], [0, 0.55, 1]),
                       startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 720, options: [.drawsAfterEndLocation])

// 玻璃管轮廓：顶部半圆，底部小圆角
let tubeLeft: CGFloat = 282, tubeRight: CGFloat = 742, tubeBottom: CGFloat = 196
let radius = (tubeRight - tubeLeft) / 2
let domeCenterY: CGFloat = 650
let tube = CGMutablePath()
tube.move(to: CGPoint(x: tubeLeft, y: tubeBottom + 30))
tube.addLine(to: CGPoint(x: tubeLeft, y: domeCenterY))
tube.addArc(center: CGPoint(x: 512, y: domeCenterY), radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
tube.addLine(to: CGPoint(x: tubeRight, y: tubeBottom + 30))
tube.addQuadCurve(to: CGPoint(x: tubeRight - 30, y: tubeBottom), control: CGPoint(x: tubeRight, y: tubeBottom))
tube.addLine(to: CGPoint(x: tubeLeft + 30, y: tubeBottom))
tube.addQuadCurve(to: CGPoint(x: tubeLeft, y: tubeBottom + 30), control: CGPoint(x: tubeLeft, y: tubeBottom))
tube.closeSubpath()

// 管内：深色玻璃 + 环境辉光 + 六边形阳极网
ctx.saveGState()
ctx.addPath(tube); ctx.clip()
ctx.setFillColor(color(0x0C0705))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.drawRadialGradient(gradient([(0xFF6A10, 0.50), (0xFF5A00, 0.16), (0xFF5A00, 0)], [0, 0.5, 1]),
                       startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 540), endRadius: 330, options: [])
ctx.setStrokeColor(color(0xFF8A3D, 0.10)); ctx.setLineWidth(2.5)
let hex: CGFloat = 26
let dx = hex * sqrt(3), dy = hex * 1.5
var row = 0
for y in stride(from: CGFloat(150), through: 960, by: dy) {
    let offset = row % 2 == 0 ? 0 : dx / 2
    for x in stride(from: CGFloat(240) + offset, through: 800, by: dx) {
        let p = CGMutablePath()
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3 + .pi / 6
            let pt = CGPoint(x: x + hex * cos(a), y: y + hex * sin(a))
            k == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        ctx.addPath(p)
    }
    row += 1
}
ctx.strokePath()
ctx.restoreGState()

// 灯丝：八分音符（符头椭圆、符干、符尾），像辉光管数字那样是空心线条
let note = CGMutablePath()
var headTransform = CGAffineTransform(translationX: 452, y: 372).rotated(by: -0.42)
note.addEllipse(in: CGRect(x: -88, y: -58, width: 176, height: 116), transform: headTransform)
note.move(to: CGPoint(x: 532, y: 404))
note.addLine(to: CGPoint(x: 532, y: 772))
note.addCurve(to: CGPoint(x: 646, y: 548), control1: CGPoint(x: 560, y: 690), control2: CGPoint(x: 700, y: 668))

ctx.setLineCap(.round); ctx.setLineJoin(.round)
func strokeNote(width: CGFloat, color c: CGColor, blur: CGFloat, glow: CGColor) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: glow)
    ctx.addPath(note); ctx.setStrokeColor(c); ctx.setLineWidth(width); ctx.strokePath()
    ctx.restoreGState()
}
strokeNote(width: 22, color: color(0xFF5A00), blur: 170, glow: color(0xFF5A00, 1))
strokeNote(width: 22, color: color(0xFF6A14), blur: 70, glow: color(0xFF6A10, 1))
strokeNote(width: 15, color: color(0xFFB060), blur: 18, glow: color(0xFFA04A, 1))
strokeNote(width: 6, color: color(0xFFF1D8), blur: 4, glow: color(0xFFE0B0, 1))

// 玻璃高光与描边
ctx.saveGState()
ctx.addPath(tube); ctx.clip()
let streak = CGMutablePath()
streak.addRoundedRect(in: CGRect(x: tubeLeft + 34, y: 300, width: 30, height: 382), cornerWidth: 17, cornerHeight: 17)
ctx.addPath(streak)
ctx.setFillColor(color(0xFFFFFF, 0.10)); ctx.fillPath()
ctx.addArc(center: CGPoint(x: 512, y: domeCenterY), radius: radius - 40, startAngle: .pi * 0.60, endAngle: .pi * 0.95, clockwise: false)
ctx.setStrokeColor(color(0xFFFFFF, 0.13)); ctx.setLineWidth(14); ctx.strokePath()
ctx.restoreGState()
ctx.addPath(tube)
ctx.setStrokeColor(color(0xFFD9B0, 0.28)); ctx.setLineWidth(5); ctx.strokePath()

// 底座：金属管座 + 顶面反光
let base = CGPath(roundedRect: CGRect(x: 250, y: 92, width: 524, height: 128), cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.saveGState()
ctx.addPath(base); ctx.clip()
ctx.drawLinearGradient(gradient([(0x3C342E, 1), (0x1A1512, 1), (0x0B0908, 1)], [0, 0.45, 1]),
                       start: CGPoint(x: 0, y: 220), end: CGPoint(x: 0, y: 92), options: [])
ctx.drawRadialGradient(gradient([(0xFF7A20, 0.35), (0xFF7A20, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 222), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 222), endRadius: 260, options: [])
ctx.setFillColor(color(0x000000, 0.35))
for i in 0..<9 { ctx.fill(CGRect(x: 290 + CGFloat(i) * 52, y: 118, width: 14, height: 48)) }
ctx.restoreGState()
ctx.addPath(base)
ctx.setStrokeColor(color(0xFFD9B0, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
