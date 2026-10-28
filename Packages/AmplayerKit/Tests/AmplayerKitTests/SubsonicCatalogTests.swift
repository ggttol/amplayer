import Foundation
import Testing
@testable import AmplayerCore
@testable import AmplayerSources

@Test func subsonicAlbumParsing() {
    let album = SubsonicSource.album([
        "id": "al-1", "name": "范特西", "artist": "周杰伦", "artistId": "ar-1", "year": 2001,
        "genre": "流行", "coverArt": "al-1", "songCount": 10, "duration": 2700.0, "starred": "2024-01-01T00:00:00Z",
    ])
    #expect(album?.name == "范特西")
    #expect(album?.year == 2001)
    #expect(album?.starred == true)
    #expect(SubsonicSource.album(["id": "x", "title": "T", "year": 0])?.year == nil)
    #expect(SubsonicSource.artist(["id": "ar-1", "name": "周杰伦", "albumCount": 15])?.albumCount == 15)
}

/// 真实 Subsonic 服务器：SUBSONIC_URL、SUBSONIC_USER、SUBSONIC_PASS 都设置时才跑
@Test func subsonicCatalogLive() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["SUBSONIC_URL"], let user = env["SUBSONIC_USER"], let pass = env["SUBSONIC_PASS"] else { return }
    var config = SourceConfig(kind: .subsonic, name: "live", url: url)
    config.username = user
    let source = SubsonicSource(config: config, password: pass)
    let newest = try await source.albums(.newest, size: 5)
    #expect(!newest.isEmpty)
    let page2 = try await source.albums(.newest, size: 5, offset: 5)
    #expect(Set(newest.map(\.id)).isDisjoint(with: page2.map(\.id)))
    let (album, songs) = try await source.album(id: newest[0].id)
    #expect(album.id == newest[0].id)
    #expect(!songs.isEmpty)
    if let cover = album.coverArt {
        let data = try await source.coverArt(id: cover, size: 120)
        #expect(data.count > 100)
    }
    let index = try await source.artistIndex()
    #expect(!index.isEmpty)
    let artist = index[0].artists[0]
    let detail = try await source.artist(id: artist.id)
    #expect(detail.artist.id == artist.id)
    _ = try await source.genres()
    _ = try await source.playlists()
    _ = try await source.starred()
    let found = try await source.search(artist.name)
    #expect(found.artists.contains { $0.id == artist.id })
    let random = try await source.randomSongs(size: 5)
    #expect(random.count <= 5)
    let root = try await source.list(path: "/")
    #expect(root.contains { $0.path == "genres" })
    print("live:", newest.map(\.name), index.count, "indexes")
}
