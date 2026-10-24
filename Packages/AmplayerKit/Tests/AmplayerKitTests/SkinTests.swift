import CoreGraphics
import Foundation
import Testing
@testable import AmplayerSkin

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
/// 快照输出目录（便于人工查看）
private let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("amplayer-skin-snapshots")

private func writeSnapshot(_ image: CGImage?, _ name: String) throws {
    let image = try #require(image)
    try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
    try #require(SkinPreview.pngData(image, scale: 3)).write(to: snapshotDir.appendingPathComponent(name))
}

@Test func defaultSkinHasAllSheets() throws {
    let skin = Skin.defaultSkin
    for sheet in SkinSheet.allCases {
        let image = try #require(skin.sheet(sheet), "缺少 \(sheet)")
        #expect(image.width == Int(sheet.size.width))
        #expect(image.height == Int(sheet.size.height))
    }
    #expect(skin.visColors.count == 24)
    #expect(skin.image(S.play) != nil)
    #expect(skin.image(S.eqSliderFrame(27)) != nil)
    #expect(skin.renderText("hello 123")?.width == 45)
    try writeSnapshot(SkinPreview.mainWindow(skin), "default-main.png")
    try writeSnapshot(SkinPreview.equalizerWindow(skin), "default-eq.png")
    for sheet in [SkinSheet.text, .pledit, .cbuttons, .shufrep] {
        try writeSnapshot(skin.sheet(sheet), "default-sheet-\(sheet.rawValue).png")
    }
}

@Test func visColorParsing() {
    let text = (0..<24).map { "\($0),\($0 * 2),\($0 * 3), // color \($0)" }.joined(separator: "\r\n")
    let colors = Skin.parseVisColors(text)
    #expect(colors.count == 24)
    #expect(colors[10] == SkinColor(r255: 10, g: 20, b: 30))
}

@Test func playlistStyleParsing() {
    let style = PlaylistStyle.parse("[Text]\r\nNormal=#00FF00\r\nCurrent=#FFFFFF\r\nNormalBG=#000000\r\nSelectedBG=0000C6FF\r\nFont=Arial")
    #expect(style.normal == SkinColor(r255: 0, g: 255, b: 0))
    #expect(style.selectedBackground == SkinColor(r255: 0, g: 0, b: 198))
}

@Test func fontLookupMatchesWebamp() {
    #expect(S.character("A")?.rect == CGRect(x: 0, y: 0, width: 5, height: 6))
    #expect(S.character("9")?.rect == CGRect(x: 45, y: 6, width: 5, height: 6))
    #expect(S.character("#")?.rect == CGRect(x: 150, y: 6, width: 5, height: 6))
    #expect(S.character("?")?.rect == CGRect(x: 15, y: 12, width: 5, height: 6))
    #expect(Skin.canRenderWithBitmapFont("Hello - World (1999)"))
    #expect(!Skin.canRenderWithBitmapFont("周杰伦"))
}

/// 用一个真实的 .wsz 验证 zip 解析与位图解码。素材不入库：放到 Fixtures/local/base-2.91.wsz，或用环境变量 AMP_TEST_WSZ 指定。
@Test func loadsRealWsz() throws {
    let url = ProcessInfo.processInfo.environment["AMP_TEST_WSZ"].map(URL.init(fileURLWithPath:))
        ?? fixtures.appendingPathComponent("local/base-2.91.wsz")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let data = try Data(contentsOf: url)
    let zip = try ZipArchive(data: data)
    #expect(zip.entry(named: "MAIN.BMP") != nil)
    let skin = try Skin.load(wszData: data, id: "base", name: "Base")
    let main = try #require(skin.sheet(.main))
    #expect(main.width == 275 && main.height == 116)
    #expect(skin.visColors.count == 24)
    try writeSnapshot(SkinPreview.mainWindow(skin), "base-main.png")
    try writeSnapshot(SkinPreview.equalizerWindow(skin), "base-eq.png")
}

/// 缺文件的皮肤用默认皮肤补齐
@Test func partialSkinFallsBack() throws {
    let skin = try Skin.load(wszData: makeZip(files: ["viscolor.txt": Data("1,2,3\n".utf8)]), id: "p", name: "Partial")
    #expect(skin.sheet(.main) != nil)
    #expect(skin.visColors.count == 24) // 不足 24 行时用默认配色
}

@Test func zipStoredEntries() throws {
    let zip = try ZipArchive(data: makeZip(files: ["Skin/PLEDIT.TXT": Data("Normal=#112233".utf8)]))
    #expect(String(data: try #require(zip.data(named: "pledit.txt")), encoding: .utf8) == "Normal=#112233")
}

/// 生成仅含 stored 条目的 zip
private func makeZip(files: [String: Data]) -> Data {
    var out = Data()
    var central = Data()
    func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    for (name, content) in files {
        let offset = out.count
        let nameData = Data(name.utf8)
        out += u32(0x04034B50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
        out += u32(content.count) + u32(content.count) + u16(nameData.count) + u16(0) + nameData + content
        central += u32(0x02014B50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
        central += u32(content.count) + u32(content.count) + u16(nameData.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + nameData
    }
    let cdOffset = out.count
    out += central
    out += u32(0x06054B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(cdOffset) + u16(0)
    return out
}
