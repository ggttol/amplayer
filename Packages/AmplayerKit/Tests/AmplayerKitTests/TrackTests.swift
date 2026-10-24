import Foundation
import Testing
@testable import AmplayerCore

@Test func displayNameIncludesArtist() {
    let track = Track(sourceID: "local", path: "/a.mp3", title: "Song", artist: "Band")
    #expect(track.displayName == "Band - Song")
    #expect(track.fileExtension == "mp3")
}

@Test func uriRoundTrip() {
    let track = Track(sourceID: "abc", path: "/音乐/A B#1.flac", title: "x")
    let parsed = Track.parseURI(track.uri)
    #expect(parsed?.sourceID == "abc")
    #expect(parsed?.path == "/音乐/A B#1.flac")
}

@Test func titleFromFileName() {
    #expect(Track.title(fromFileName: "01 - Artist - Title.mp3") == "Artist - Title")
    #expect(Track.title(fromFileName: "Song.flac") == "Song")
}

@Test func clockFormat() {
    #expect(TimeFormat.clock(123) == "2:03")
    #expect(TimeFormat.clock(3723) == "1:02:03")
}

private func tracks(_ n: Int) -> [Track] {
    (0..<n).map { Track(sourceID: "s", path: "/\($0).mp3", title: "\($0)") }
}

@Test func queueAdvanceAndRepeat() {
    var q = PlayQueue(tracks: tracks(3))
    q.select(index: 0)
    #expect(q.advance(auto: true)?.title == "1")
    #expect(q.advance(auto: true)?.title == "2")
    #expect(q.advance(auto: true) == nil) // 不循环时播完结束
    q.repeatMode = .all
    #expect(q.advance(auto: true)?.title == "0")
    q.repeatMode = .one
    #expect(q.advance(auto: true)?.title == "0")
    #expect(q.advance(auto: false)?.title == "1") // 手动下一首不受单曲循环影响
    #expect(q.goBack()?.title == "0")
}

@Test func queueShuffleVisitsAll() {
    var q = PlayQueue(tracks: tracks(20))
    q.select(index: 5)
    q.setShuffle(true)
    var seen: Set<String> = [q.current!.title]
    while let t = q.advance(auto: true) { seen.insert(t.title) }
    #expect(seen.count == 20)
}

@Test func queueRemoveAndMoveKeepCurrent() {
    var q = PlayQueue(tracks: tracks(5))
    q.select(index: 3)
    q.remove(at: IndexSet([0, 1]))
    #expect(q.current?.title == "3")
    #expect(q.currentIndex == 1)
    q.move(from: IndexSet([1]), to: 0)
    #expect(q.current?.title == "3")
    #expect(q.currentIndex == 0)
    q.remove(at: IndexSet([0]))
    #expect(q.current == nil)
}

@Test func m3uRoundTrip() {
    let entries = [PlaylistEntry(location: "amplayer://s/a.mp3", title: "A - B", duration: 200), PlaylistEntry(location: "http://x/y.flac")]
    let parsed = PlaylistFile.parseM3U(PlaylistFile.makeM3U(entries))
    #expect(parsed.count == 2)
    #expect(parsed[0] == entries[0])
    #expect(parsed[1].location == "http://x/y.flac")
}

@Test func plsParse() {
    let text = "[playlist]\nFile1=/a.mp3\nTitle1=A\nLength1=10\nFile2=/b.mp3\nNumberOfEntries=2\n"
    let parsed = PlaylistFile.parsePLS(text)
    #expect(parsed.map(\.location) == ["/a.mp3", "/b.mp3"])
    #expect(parsed[0].title == "A")
    #expect(parsed[0].duration == 10)
}

@Test func equalizerNormalization() {
    #expect(EqualizerSettings.normalized(12) == 1)
    #expect(EqualizerSettings.normalized(-12) == 0)
    #expect(EqualizerSettings.decibels(fromNormalized: 0.5) == 0)
    #expect(EqualizerPreset.builtIn.allSatisfy { $0.bands.count == 10 })
}
