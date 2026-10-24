import Testing
@testable import MP9Kit

@Test func displayNameIncludesArtist() {
    let track = Track(id: "1", sourceID: "local", path: "/a.mp3", title: "Song", artist: "Band")
    #expect(track.displayName == "Band - Song")
}

@Test func displayNameWithoutArtist() {
    let track = Track(id: "1", sourceID: "local", path: "/a.mp3", title: "Song")
    #expect(track.displayName == "Song")
}
