import Foundation
import AmplayerCore

// Subsonic 曲库接口：给“音乐服务器”式的浏览界面用（专辑封面墙、艺术家、播放列表、流派、收藏、搜索）。
// 只用标准 Subsonic API（1.16）和 ID3 接口，Navidrome、Airsonic、Gonic 等都支持。

public struct SubsonicAlbum: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artistID: String?
    public var year: Int?
    public var genre: String?
    public var coverArt: String?
    public var songCount: Int?
    public var duration: TimeInterval?
    public var starred: Bool
}

public struct SubsonicArtist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var albumCount: Int?
    public var coverArt: String?
    public var starred: Bool

    public init(id: String, name: String, albumCount: Int? = nil, coverArt: String? = nil, starred: Bool = false) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.coverArt = coverArt
        self.starred = starred
    }
}

public struct SubsonicArtistIndex: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var artists: [SubsonicArtist]

    public init(name: String, artists: [SubsonicArtist]) {
        self.name = name
        self.artists = artists
    }
}

public struct SubsonicPlaylist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var songCount: Int?
    public var duration: TimeInterval?
    public var coverArt: String?
    public var owner: String?
}

public struct SubsonicGenre: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var songCount: Int
    public var albumCount: Int
}

/// 搜索结果、收藏：艺术家 + 专辑 + 歌曲
public struct SubsonicResults: Sendable {
    public var artists: [SubsonicArtist] = []
    public var albums: [SubsonicAlbum] = []
    public var songs: [SourceItem] = []
    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
    public init() {}
}

/// getAlbumList2 的各种排法
public enum SubsonicAlbumList: Hashable, Sendable {
    case newest, recent, frequent, random, highest, alphabetical, starred
    case genre(String)
    case years(Int, Int)

    var params: [String: String] {
        switch self {
        case .newest: ["type": "newest"]
        case .recent: ["type": "recent"]
        case .frequent: ["type": "frequent"]
        case .random: ["type": "random"]
        case .highest: ["type": "highest"]
        case .alphabetical: ["type": "alphabeticalByName"]
        case .starred: ["type": "starred"]
        case .genre(let g): ["type": "byGenre", "genre": g]
        case .years(let from, let to): ["type": "byYear", "fromYear": String(from), "toYear": String(to)]
        }
    }

    /// 随机列表每次都不同，不能分页
    public var isPaged: Bool { self != .random }
}

extension SubsonicSource {
    // MARK: 专辑

    public func albums(_ list: SubsonicAlbumList, size: Int = 40, offset: Int = 0) async throws -> [SubsonicAlbum] {
        var params = list.params
        params["size"] = String(size)
        params["offset"] = String(offset)
        let body = try await call("getAlbumList2", params)
        return (body.dict("albumList2")?.array("album") ?? []).compactMap(Self.album)
    }

    /// 专辑信息和曲目（按碟号、音轨号排好）
    public func album(id: String) async throws -> (album: SubsonicAlbum, songs: [SourceItem]) {
        let body = try await call("getAlbum", ["id": id])
        guard let a = body.dict("album"), let album = Self.album(a) else { throw SourceError.protocolError("找不到专辑") }
        return (album, a.array("song").compactMap(songItem))
    }

    // MARK: 艺术家

    public func artistIndex() async throws -> [SubsonicArtistIndex] {
        let body = try await call("getArtists")
        return (body.dict("artists")?.array("index") ?? []).compactMap { index in
            let artists = index.array("artist").compactMap(Self.artist)
            guard !artists.isEmpty else { return nil }
            return SubsonicArtistIndex(name: index.string("name") ?? "#", artists: artists)
        }
    }

    public func artist(id: String) async throws -> (artist: SubsonicArtist, albums: [SubsonicAlbum]) {
        let body = try await call("getArtist", ["id": id])
        guard let a = body.dict("artist"), let artist = Self.artist(a) else { throw SourceError.protocolError("找不到艺术家") }
        let albums = a.array("album").compactMap(Self.album).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        return (artist, albums)
    }

    // MARK: 播放列表

    public func playlists() async throws -> [SubsonicPlaylist] {
        let body = try await call("getPlaylists")
        return (body.dict("playlists")?.array("playlist") ?? []).compactMap(Self.playlist)
    }

    public func playlist(id: String) async throws -> (playlist: SubsonicPlaylist, songs: [SourceItem]) {
        let body = try await call("getPlaylist", ["id": id])
        guard let p = body.dict("playlist"), let playlist = Self.playlist(p) else { throw SourceError.protocolError("找不到播放列表") }
        return (playlist, p.array("entry").compactMap(songItem))
    }

    // MARK: 流派、收藏、搜索、随机

    /// 按专辑数从多到少
    public func genres() async throws -> [SubsonicGenre] {
        let body = try await call("getGenres")
        return (body.dict("genres")?.array("genre") ?? []).compactMap { g in
            guard let name = g.string("value"), !name.isEmpty else { return nil }
            return SubsonicGenre(name: name, songCount: g.int("songCount") ?? 0, albumCount: g.int("albumCount") ?? 0)
        }
        .sorted { ($0.albumCount, $0.songCount) > ($1.albumCount, $1.songCount) }
    }

    public func starred() async throws -> SubsonicResults {
        let body = try await call("getStarred2")
        return results(body.dict("starred2"))
    }

    public func search(_ query: String, artists: Int = 12, albums: Int = 24, songs: Int = 50) async throws -> SubsonicResults {
        let body = try await call("search3", [
            "query": query, "artistCount": String(artists), "albumCount": String(albums), "songCount": String(songs),
        ])
        return results(body.dict("searchResult3"))
    }

    public func randomSongs(size: Int = 100, genre: String? = nil) async throws -> [SourceItem] {
        var params = ["size": String(size)]
        if let genre { params["genre"] = genre }
        let body = try await call("getRandomSongs", params)
        return (body.dict("randomSongs")?.array("song") ?? []).compactMap(songItem)
    }

    /// 收藏 / 取消收藏（歌曲用 songID，专辑用 albumID，艺术家用 artistID）
    public func setStarred(_ starred: Bool, songID: String? = nil, albumID: String? = nil, artistID: String? = nil) async throws {
        var params: [String: String] = [:]
        if let songID { params["id"] = songID }
        if let albumID { params["albumId"] = albumID }
        if let artistID { params["artistId"] = artistID }
        _ = try await call(starred ? "star" : "unstar", params)
    }

    /// 封面图片（size 是边长像素）
    public func coverArt(id: String, size: Int) async throws -> Data {
        let (data, _) = try await http.data(for: URLRequest(url: try endpoint("getCoverArt", ["id": id, "size": String(size)])))
        return data
    }

    // MARK: 解析

    private func results(_ dict: [String: Any]?) -> SubsonicResults {
        var r = SubsonicResults()
        guard let dict else { return r }
        r.artists = dict.array("artist").compactMap(Self.artist)
        r.albums = dict.array("album").compactMap(Self.album)
        r.songs = dict.array("song").compactMap(songItem)
        return r
    }

    static func album(_ a: [String: Any]) -> SubsonicAlbum? {
        guard let id = a.string("id") else { return nil }
        return SubsonicAlbum(
            id: id, name: a.string("name") ?? a.string("title") ?? id,
            artist: a.string("artist"), artistID: a.string("artistId"),
            year: a.int("year").flatMap { $0 > 0 ? $0 : nil }, genre: a.string("genre"),
            coverArt: a.string("coverArt"), songCount: a.int("songCount"), duration: a.double("duration"),
            starred: a["starred"] != nil
        )
    }

    static func artist(_ a: [String: Any]) -> SubsonicArtist? {
        guard let id = a.string("id"), let name = a.string("name") else { return nil }
        return SubsonicArtist(id: id, name: name, albumCount: a.int("albumCount"), coverArt: a.string("coverArt"), starred: a["starred"] != nil)
    }

    static func playlist(_ p: [String: Any]) -> SubsonicPlaylist? {
        guard let id = p.string("id") else { return nil }
        return SubsonicPlaylist(id: id, name: p.string("name") ?? id, songCount: p.int("songCount"),
                                duration: p.double("duration"), coverArt: p.string("coverArt"), owner: p.string("owner"))
    }
}
