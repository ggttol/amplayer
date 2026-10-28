import Foundation
import Testing
@testable import AmplayerCore
@testable import AmplayerKit

@Test func lyricsOffsetDescription() {
    #expect(PlayerController.describeLyricsOffset(0) == "歌词时间未调整")
    #expect(PlayerController.describeLyricsOffset(0.5) == "歌词提前 0.5 秒")
    #expect(PlayerController.describeLyricsOffset(-1) == "歌词延后 1 秒")
    #expect(PlayerController.describeLyricsOffset(-1.5) == "歌词延后 1.5 秒")
}

@MainActor
@Test func lyricsOffsetIsPerTrackAndShiftsLyricsTime() {
    let key = "amplayer.lyricsOffsets"
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.removeObject(forKey: key)

    let player = PlayerController(sources: SourceStore())
    let a = Track(sourceID: "t", path: "/a.mp3", title: "A")
    let b = Track(sourceID: "t", path: "/b.mp3", title: "B")
    player.setQueue([a, b], startAt: 0, autoplay: false)
    player.adjustLyricsOffset(by: 0.5)
    player.adjustLyricsOffset(by: 0.5)
    #expect(player.lyricsOffset == 1)
    #expect(player.lyricsTime == player.audio.currentTime + 1)
    #expect((UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[a.id] == 1)
    player.adjustLyricsOffset(by: -0.3)
    #expect(player.lyricsOffset == 0.7)
    player.resetLyricsOffset()
    #expect(player.lyricsOffset == 0)
    // 归零后不再占存档
    #expect((UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[a.id] == nil)
}
