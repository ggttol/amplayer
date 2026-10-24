import Testing
@testable import AmplayerCore

private func queue(_ n: Int) -> PlayQueue {
    PlayQueue(tracks: (0..<n).map { Track(sourceID: "t", path: "/\($0).mp3", title: "T\($0)") })
}

@Test func removingCurrentContinuesWithFollowingTrack() {
    var q = queue(5)
    q.select(index: 2)
    q.remove(at: [2])
    #expect(q.currentIndex == nil)
    // 原来的第 4 首（T3）现在在下标 2
    #expect(q.advance(auto: false)?.title == "T3")
}

@Test func removingCurrentAndEarlierTracksShiftsResumePosition() {
    var q = queue(6)
    q.select(index: 3)
    q.remove(at: [0, 1, 3])
    #expect(q.advance(auto: false)?.title == "T4")
}

@Test func removingLastCurrentResumesAtNewLast() {
    var q = queue(3)
    q.select(index: 2)
    q.remove(at: [2])
    #expect(q.advance(auto: false)?.title == "T1")
}

@Test func selectingClearsResumePosition() {
    var q = queue(4)
    q.select(index: 1)
    q.remove(at: [1])
    q.select(index: 0)
    #expect(q.advance(auto: false)?.title == "T2")
}

@Test func moveKeepsCurrentTrack() {
    var q = queue(4)
    q.select(index: 1)
    q.move(from: [3], to: 0)
    #expect(q.tracks.map(\.title) == ["T3", "T0", "T1", "T2"])
    #expect(q.current?.title == "T1")
}
