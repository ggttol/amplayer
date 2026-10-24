// 生成 App 图标（1024x1024 PNG）：swift Tools/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
// 背景：石墨渐变
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x3A3F4B), color(0x15171C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
// 显示屏
ctx.setFillColor(color(0x07110C))
ctx.fill(CGRect(x: 112, y: 300, width: 800, height: 520))
ctx.setStrokeColor(color(0x4A4F5A)); ctx.setLineWidth(12)
ctx.stroke(CGRect(x: 112, y: 300, width: 800, height: 520))
// 频谱柱：16 格像素
let heights = [5, 8, 11, 9, 13, 10, 7, 12, 9, 6, 8, 5]
let px = 20
for (i, h) in heights.enumerated() {
    for row in 0..<h {
        let t = CGFloat(row) / 13
        let c: CGColor = t > 0.75 ? color(0xFF5E5B) : (t > 0.5 ? color(0xFFD166) : color(0x3CF0A0))
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: 172 + i * 57, y: 340 + row * (px + 6), width: 50, height: px))
    }
}
// 底部 "MP9" 像素字
let glyphs: [[String]] = [
    ["x...x", "xx.xx", "x.x.x", "x...x", "x...x"],
    ["xxxx.", "x...x", "xxxx.", "x....", "x...."],
    [".xxx.", "x...x", ".xxxx", "....x", ".xxx."],
]
ctx.setFillColor(color(0x3CF0A0))
let cell = 28
for (g, rows) in glyphs.enumerated() {
    for (r, row) in rows.enumerated() {
        for (c, ch) in row.enumerated() where ch == "x" {
            ctx.fill(CGRect(x: 262 + g * 6 * cell + c * cell, y: 220 - r * cell - 40, width: cell - 2, height: cell - 2))
        }
    }
}
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
