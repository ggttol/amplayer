import Foundation
import Testing
@testable import AmplayerCore
@testable import AmplayerSources

@Test func parsesSyncedLyricsWithMetadataAndMultipleStamps() throws {
    let text = """
    [ti:晴天]
    [ar:周杰伦]
    [00:01.50]故事的小黄花
    [00:05.00][00:40.25]从出生那年就飘着
    [01:02:30]第三种时间格式
    """
    let lyrics = try #require(Lyrics.parse(text))
    #expect(lyrics.isSynced)
    #expect(lyrics.lines.map(\.text) == ["故事的小黄花", "从出生那年就飘着", "从出生那年就飘着", "第三种时间格式"])
    #expect(lyrics.lines.map { $0.time! } == [1.5, 5, 40.25, 62.3].map { $0 })
    #expect(lyrics.index(at: 0.5) == nil)
    #expect(lyrics.index(at: 1.5) == 0)
    #expect(lyrics.index(at: 30) == 1)
    #expect(lyrics.index(at: 500) == 3)
}

@Test func mergesSameTimestampTranslationsAndAppliesOffset() throws {
    let text = """
    [offset:500]
    [00:10.00]Hello
    [00:10.00]你好
    [00:12.00]<00:12.00>逐<00:12.50>字
    """
    let lyrics = try #require(Lyrics.parse(text))
    #expect(lyrics.lines.count == 2)
    #expect(lyrics.lines[0].text == "Hello\n你好")
    #expect(lyrics.lines[0].time == 9.5)
    #expect(lyrics.lines[1].text == "逐字")
    // 写回 LRC 再解析结果不变
    #expect(Lyrics.parse(lyrics.lrcText) == lyrics)
}

@Test func plainTextAndEmptyLyrics() throws {
    let plain = try #require(Lyrics.parse("第一行\n\n第二行\n"))
    #expect(!plain.isSynced)
    #expect(plain.lines.map(\.text) == ["第一行", "第二行"])
    #expect(plain.index(at: 10) == nil)
    #expect(Lyrics.parse("[ti:x]\n[00:01.00]\n") == nil)
    #expect(Lyrics.parse("   ") == nil)
}

@Test func decodesCommonEncodings() throws {
    let text = "[00:01.00]故事的小黄花"
    let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    #expect(Lyrics.decode(try #require(text.data(using: gbk))) == text)
    #expect(Lyrics.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
    #expect(Lyrics.decode(try #require(text.data(using: .utf16))) == text)
}

@Test func findsSiblingLrcNextToAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("专辑"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("专辑/01 晴天.flac"))
    try Data("[00:01.00]故事的小黄花".utf8).write(to: root.appendingPathComponent("专辑/01 晴天.lrc"))
    try Data().write(to: root.appendingPathComponent("专辑/02 无词.flac"))
    let source = LocalSource(root: root)
    let hit = Track(sourceID: "local", path: "/专辑/01 晴天.flac", title: "晴天")
    let miss = Track(sourceID: "local", path: "/专辑/02 无词.flac", title: "无词")
    #expect(await source.lyrics(for: hit) == "[00:01.00]故事的小黄花")
    #expect(await source.lyrics(for: miss) == nil)
    #expect(LocalSource.removingExtension("fs:/music/a.b/song.ape") == "fs:/music/a.b/song")
    #expect(LocalSource.removingExtension("/music/a.b/noext") == nil)
}

@Test func simplifiesTraditionalChinese() throws {
    let lyrics = try #require(Lyrics.parse("[00:01.00]故事的小黃花\n[00:02.00]從出生那年就飄著\n[00:03.00]Hello"))
    #expect(lyrics.simplified().lines.map(\.text) == ["故事的小黄花", "从出生那年就飘着", "Hello"])
}
