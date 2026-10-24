import Foundation
import MP9Core

/// Jellyfin 与 Emby（两者 API 基本一致）
///
/// 路径约定：`/` 列出媒体库；`items/<parentId>` 文件夹浏览；`albums/<libraryId>` 库内全部专辑；曲目 `audio/<id>`
public final class JellyfinSource: MediaSource, @unchecked Sendable {
    public let config: SourceConfig
    private let password: String
    private let http: HTTPClient
    private let lock = NSLock()
    private var session: (token: String, userID: String)?

    public init(config: SourceConfig, password: String?) {
        self.config = config
        self.password = password ?? ""
        self.http = .forConfig(config)
    }

    public func list(path: String) async throws -> [SourceItem] {
        let (_, userID) = try await authenticate()
        if path == "/" || path.isEmpty {
            let json = try await get("Users/\(userID)/Views")
            return json.array("Items").compactMap { v in
                guard let id = v.string("Id") else { return nil }
                let type = v.string("CollectionType") ?? ""
                guard type.isEmpty || ["music", "folders", "playlists", "mixed"].contains(type) else { return nil }
                return SourceItem(path: type == "music" ? "library/\(id)" : "items/\(id)", name: v.string("Name") ?? id, kind: .directory)
            }
        }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw SourceError.protocolError("未知路径 \(path)") }
        let id = parts[1]
        switch parts[0] {
        case "library":
            return [
                SourceItem(path: "albums/\(id)", name: "全部专辑", kind: .directory),
                SourceItem(path: "artists/\(id)", name: "艺术家", kind: .directory),
                SourceItem(path: "items/\(id)", name: "文件夹", kind: .directory),
            ]
        case "albums":
            return try await items(userID: userID, query: [
                ("ParentId", id), ("Recursive", "true"), ("IncludeItemTypes", "MusicAlbum"), ("SortBy", "SortName"),
            ])
        case "artists":
            let json = try await get("Artists/AlbumArtists", [("ParentId", id), ("UserId", userID), ("SortBy", "SortName")])
            return json.array("Items").compactMap { a in
                guard let aid = a.string("Id") else { return nil }
                return SourceItem(path: "artist/\(aid)", name: a.string("Name") ?? aid, kind: .directory)
            }
        case "artist":
            return try await items(userID: userID, query: [
                ("AlbumArtistIds", id), ("Recursive", "true"), ("IncludeItemTypes", "MusicAlbum"), ("SortBy", "ProductionYear,SortName"),
            ])
        case "items":
            return try await items(userID: userID, query: [("ParentId", id), ("SortBy", "ParentIndexNumber,IndexNumber,SortName")])
        default:
            throw SourceError.protocolError("未知路径 \(path)")
        }
    }

    public func download(path: String, to destination: URL) async throws {
        guard path.hasPrefix("audio/") else { throw SourceError.protocolError("不是曲目：\(path)") }
        let (token, _) = try await authenticate()
        let id = String(path.dropFirst("audio/".count))
        let url = try config.baseURL().appendingPathComponent("Audio/\(id)/stream").appendingQuery([("static", "true"), ("api_key", token)])
        var request = URLRequest(url: url)
        authorize(&request, token: token)
        try await http.download(request, to: destination)
    }

    public func artworkRequest(ref: String) async throws -> URLRequest? {
        let (token, _) = try await authenticate()
        let url = try config.baseURL().appendingPathComponent("Items/\(ref)/Images/Primary").appendingQuery([("maxWidth", "600"), ("api_key", token)])
        return URLRequest(url: url)
    }

    public func testConnection() async throws {
        lock.withLock { session = nil }
        _ = try await authenticate()
    }

    // MARK: 协议

    private func items(userID: String, query: [(String, String)]) async throws -> [SourceItem] {
        let json = try await get("Users/\(userID)/Items", query + [("Fields", "MediaSources,Path,ParentId")])
        return json.array("Items").compactMap(item)
    }

    private func item(_ i: [String: Any]) -> SourceItem? {
        guard let id = i.string("Id") else { return nil }
        let name = i.string("Name") ?? id
        let type = i.string("Type") ?? ""
        if type == "Audio" {
            let container = (i.array("MediaSources").first?.string("Container") ?? i.string("Container") ?? "mp3")
                .split(separator: ",").first.map(String.init) ?? "mp3"
            let ticks = i.double("RunTimeTicks")
            let artists = i["Artists"] as? [String]
            return SourceItem(
                path: "audio/\(id)", name: "\(name).\(container)", kind: .audio,
                size: i.array("MediaSources").first?.int("Size").map(Int64.init),
                title: name, artist: i.string("AlbumArtist") ?? artists?.first, album: i.string("Album"),
                trackNumber: i.int("IndexNumber"), duration: ticks.map { $0 / 10_000_000 },
                fileExtension: container, artworkRef: i.string("AlbumId") ?? id
            )
        }
        if i["IsFolder"] as? Bool == true {
            let artist = i.string("AlbumArtist")
            let label = type == "MusicAlbum" && artist != nil ? "\(name) — \(artist!)" : name
            return SourceItem(path: "items/\(id)", name: label, kind: .directory, artworkRef: id)
        }
        return nil
    }

    /// Jellyfin 10.11+ 只认 Authorization 头；Emby 认 X-Emby-Authorization / X-Emby-Token，两者都发
    private func authorizationHeader(token: String? = nil) -> String {
        let device = ProcessInfo.processInfo.hostName.replacingOccurrences(of: "\"", with: "")
        var value = "MediaBrowser Client=\"MP9\", Device=\"\(device)\", DeviceId=\"mp9-\(config.id)\", Version=\"0.1\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    private func authorize(_ request: inout URLRequest, token: String) {
        let header = authorizationHeader(token: token)
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue(header, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
    }

    private func authenticate() async throws -> (String, String) {
        if let s = lock.withLock({ session }) { return s }
        let url = try config.baseURL().appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": config.username, "Pw": password])
        let json = try await http.json(for: request)
        guard let token = json.string("AccessToken"), let userID = json.dict("User")?.string("Id") else {
            throw SourceError.authenticationFailed("未返回令牌")
        }
        lock.withLock { session = (token, userID) }
        return (token, userID)
    }

    private func get(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        let (token, _) = try await authenticate()
        var request = URLRequest(url: try config.baseURL().appendingPathComponent(path).appendingQuery(query))
        authorize(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.json(for: request)
    }
}
