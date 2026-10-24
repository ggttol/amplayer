import CryptoKit
import Foundation
import MP9Core

/// Subsonic / OpenSubsonic 协议（Navidrome、Airsonic、Gonic、Ampache 等）
///
/// 路径约定：`/` 根目录；`artists`、`albums`、`playlists`；`artist/<id>`、`album/<id>`、`playlist/<id>`；曲目 `song/<id>`
public struct SubsonicSource: MediaSource {
    public let config: SourceConfig
    private let password: String
    private let http: HTTPClient

    public init(config: SourceConfig, password: String?) {
        self.config = config
        self.password = password ?? ""
        self.http = .forConfig(config)
    }

    public func list(path: String) async throws -> [SourceItem] {
        switch path {
        case "/", "":
            return [
                SourceItem(path: "artists", name: "艺术家", kind: .directory),
                SourceItem(path: "albums", name: "最近添加的专辑", kind: .directory),
                SourceItem(path: "playlists", name: "播放列表", kind: .directory),
                SourceItem(path: "random", name: "随机 100 首", kind: .directory),
            ]
        case "artists":
            let body = try await call("getArtists")
            let indexes = body.dict("artists")?.array("index") ?? []
            return indexes.flatMap { $0.array("artist") }.compactMap { a in
                guard let id = a.string("id"), let name = a.string("name") else { return nil }
                return SourceItem(path: "artist/\(id)", name: name, kind: .directory)
            }
        case "albums":
            let body = try await call("getAlbumList2", ["type": "newest", "size": "500"])
            return (body.dict("albumList2")?.array("album") ?? []).compactMap(albumItem)
        case "playlists":
            let body = try await call("getPlaylists")
            return (body.dict("playlists")?.array("playlist") ?? []).compactMap { p in
                guard let id = p.string("id") else { return nil }
                return SourceItem(path: "playlist/\(id)", name: p.string("name") ?? id, kind: .directory)
            }
        case "random":
            let body = try await call("getRandomSongs", ["size": "100"])
            return (body.dict("randomSongs")?.array("song") ?? []).compactMap(songItem)
        default:
            break
        }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw SourceError.protocolError("未知路径 \(path)") }
        let (kind, id) = (parts[0], parts[1])
        switch kind {
        case "artist":
            let body = try await call("getArtist", ["id": id])
            return (body.dict("artist")?.array("album") ?? []).compactMap(albumItem)
        case "album":
            let body = try await call("getAlbum", ["id": id])
            return (body.dict("album")?.array("song") ?? []).compactMap(songItem)
        case "playlist":
            let body = try await call("getPlaylist", ["id": id])
            return (body.dict("playlist")?.array("entry") ?? []).compactMap(songItem)
        default:
            throw SourceError.protocolError("未知路径 \(path)")
        }
    }

    public func download(path: String, to destination: URL) async throws {
        guard path.hasPrefix("song/") else { throw SourceError.protocolError("不是曲目：\(path)") }
        let id = String(path.dropFirst("song/".count))
        // format=raw 请求原始文件，不转码
        try await http.download(URLRequest(url: try endpoint("stream", ["id": id, "format": "raw"])), to: destination)
    }

    public func artworkRequest(ref: String) async throws -> URLRequest? {
        URLRequest(url: try endpoint("getCoverArt", ["id": ref, "size": "600"]))
    }

    public func testConnection() async throws {
        _ = try await call("ping")
    }

    // MARK: 协议

    private func albumItem(_ a: [String: Any]) -> SourceItem? {
        guard let id = a.string("id") else { return nil }
        let name = a.string("name") ?? a.string("title") ?? id
        let artist = a.string("artist")
        return SourceItem(path: "album/\(id)", name: artist.map { "\(name) — \($0)" } ?? name, kind: .directory, artworkRef: a.string("coverArt"))
    }

    private func songItem(_ s: [String: Any]) -> SourceItem? {
        guard let id = s.string("id"), s["isDir"] as? Bool != true else { return nil }
        let suffix = s.string("suffix") ?? (s.string("path").map { ($0 as NSString).pathExtension } ?? "mp3")
        let title = s.string("title") ?? id
        // Navidrome 对没有标签的文件返回占位符
        func clean(_ v: String?) -> String? {
            guard let v, !v.isEmpty, !(v.hasPrefix("[Unknown") && v.hasSuffix("]")) else { return nil }
            return v
        }
        return SourceItem(
            path: "song/\(id)", name: "\(title).\(suffix)", kind: .audio,
            size: s.int("size").map(Int64.init), title: title, artist: clean(s.string("artist")),
            album: clean(s.string("album")), trackNumber: s.int("track"),
            duration: s.double("duration"), fileExtension: suffix, artworkRef: s.string("coverArt")
        )
    }

    func endpoint(_ method: String, _ params: [String: String] = [:]) throws -> URL {
        let base = try config.baseURL().appendingPathComponent("rest").appendingPathComponent("\(method).view")
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var query: [(String, String)] = [
            ("u", config.username), ("t", token), ("s", salt), ("v", "1.16.1"), ("c", "MP9"), ("f", "json"),
        ]
        query += params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return base.appendingQuery(query)
    }

    private func call(_ method: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        let json = try await http.json(for: URLRequest(url: try endpoint(method, params)))
        guard let body = json.dict("subsonic-response") else { throw SourceError.protocolError("不是 Subsonic 响应") }
        if body.string("status") != "ok" {
            let error = body.dict("error")
            let message = error?.string("message")
            if let code = error?.int("code"), code == 40 || code == 41 { throw SourceError.authenticationFailed(message) }
            throw SourceError.protocolError(message ?? "未知错误")
        }
        return body
    }
}
