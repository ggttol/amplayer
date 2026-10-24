import Foundation
import MP9Core

/// 群晖 Audio Station Web API
///
/// 路径约定：`/` 根；`folders` 或 `folder/<dir_id>` 按文件夹浏览；`albums` 全部专辑；
/// `album/<专辑名>\u{1F}<专辑艺术家>` 专辑内曲目；曲目 `song/<music_id>`
public final class SynologySource: MediaSource, @unchecked Sendable {
    public let config: SourceConfig
    private let password: String
    private let http: HTTPClient
    private let lock = NSLock()
    private var sid: String?
    /// SYNO.API.Info 返回的 API → (路径, 最高版本)
    private var apiInfo: [String: (path: String, maxVersion: Int)] = [:]

    private static let separator: Character = "\u{1F}"

    public convenience init(config: SourceConfig, password: String?) {
        self.init(config: config, password: password, http: .forConfig(config))
    }

    init(config: SourceConfig, password: String?, http: HTTPClient) {
        self.config = config
        self.password = password ?? ""
        self.http = http
    }

    public func list(path: String) async throws -> [SourceItem] {
        switch path {
        case "/", "":
            return [
                SourceItem(path: "folders", name: "文件夹", kind: .directory),
                SourceItem(path: "albums", name: "专辑", kind: .directory),
                SourceItem(path: "playlists", name: "播放列表", kind: .directory),
            ]
        case "folders":
            return try await folder(id: nil)
        case "albums":
            let data = try await call("SYNO.AudioStation.Album", method: "list", version: 3, params: [
                ("library", "shared"), ("offset", "0"), ("limit", "5000"), ("sort_by", "name"), ("sort_direction", "ASC"),
            ])
            return data.array("albums").compactMap { a in
                guard let name = a.string("name") else { return nil }
                let artist = a.string("album_artist") ?? a.string("display_artist") ?? ""
                return SourceItem(path: "album/\(name)\(Self.separator)\(artist)", name: artist.isEmpty ? name : "\(name) — \(artist)", kind: .directory)
            }
        case "playlists":
            let data = try await call("SYNO.AudioStation.Playlist", method: "list", version: 3, params: [
                ("library", "all"), ("offset", "0"), ("limit", "1000"),
            ])
            return data.array("playlists").compactMap { p in
                guard let id = p.string("id") else { return nil }
                return SourceItem(path: "playlist/\(id)", name: p.string("name") ?? id, kind: .directory)
            }
        default:
            break
        }
        if path.hasPrefix("folder/") {
            return try await folder(id: String(path.dropFirst("folder/".count)))
        }
        if path.hasPrefix("album/") {
            let parts = path.dropFirst("album/".count).split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            var params: [(String, String)] = [
                ("library", "shared"), ("offset", "0"), ("limit", "5000"), ("album", parts.first ?? ""),
                ("additional", "song_tag,song_audio"), ("sort_by", "track"), ("sort_direction", "ASC"),
            ]
            if parts.count > 1, !parts[1].isEmpty { params.append(("album_artist", parts[1])) }
            let data = try await call("SYNO.AudioStation.Song", method: "list", version: 3, params: params)
            return data.array("songs").compactMap(songItem)
        }
        if path.hasPrefix("playlist/") {
            let id = String(path.dropFirst("playlist/".count))
            let data = try await call("SYNO.AudioStation.Playlist", method: "getinfo", version: 3, params: [
                ("id", id), ("library", "all"), ("additional", "songs_song_tag,songs_song_audio"),
            ])
            let songs = data.array("playlists").first?.dict("additional")?.array("songs") ?? []
            return songs.compactMap(songItem)
        }
        throw SourceError.protocolError("未知路径 \(path)")
    }

    public func download(path: String, to destination: URL) async throws {
        guard path.hasPrefix("song/") else { throw SourceError.protocolError("不是曲目：\(path)") }
        let id = String(path.dropFirst("song/".count))
        let sid = try await login()
        let (apiPath, maxVersion) = try await info("SYNO.AudioStation.Stream")
        let ext = destination.pathExtension.isEmpty ? "mp3" : destination.pathExtension
        // stream.cgi 后面带上 0.<扩展名>，与官方客户端一致
        let url = try config.baseURL()
            .appendingPathComponent("webapi").appendingPathComponent(apiPath).appendingPathComponent("0.\(ext)")
            .appendingQuery([
                ("api", "SYNO.AudioStation.Stream"), ("version", "\(min(maxVersion, 2))"), ("method", "stream"),
                ("id", id), ("_sid", sid),
            ])
        try await http.download(URLRequest(url: url), to: destination)
    }

    public func artworkRequest(ref: String) async throws -> URLRequest? {
        let sid = try await login()
        let (apiPath, maxVersion) = try await info("SYNO.AudioStation.Cover")
        let url = try config.baseURL().appendingPathComponent("webapi").appendingPathComponent(apiPath).appendingQuery([
            ("api", "SYNO.AudioStation.Cover"), ("version", "\(min(maxVersion, 3))"), ("method", "getsongcover"),
            ("id", ref), ("library", "shared"), ("_sid", sid),
        ])
        return URLRequest(url: url)
    }

    public func testConnection() async throws {
        lock.withLock { sid = nil }
        _ = try await login()
    }

    // MARK: 协议

    private func folder(id: String?) async throws -> [SourceItem] {
        var params: [(String, String)] = [
            ("library", "shared"), ("offset", "0"), ("limit", "5000"), ("sort_by", "title"), ("sort_direction", "ASC"),
            ("additional", "song_tag,song_audio"),
        ]
        if let id { params.append(("id", id)) }
        let data = try await call("SYNO.AudioStation.Folder", method: "list", version: 3, params: params)
        return data.array("items").compactMap { i in
            guard let itemID = i.string("id") else { return nil }
            if i.string("type") == "folder" {
                return SourceItem(path: "folder/\(itemID)", name: i.string("title") ?? itemID, kind: .directory)
            }
            return songItem(i)
        }
    }

    private func songItem(_ s: [String: Any]) -> SourceItem? {
        guard let id = s.string("id") else { return nil }
        let filePath = s.string("path") ?? ""
        let fileName = (filePath as NSString).lastPathComponent
        let tag = s.dict("additional")?.dict("song_tag")
        let audio = s.dict("additional")?.dict("song_audio")
        let title = tag?.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? s.string("title") ?? Track.title(fromFileName: fileName)
        let ext = (fileName as NSString).pathExtension.isEmpty ? "mp3" : (fileName as NSString).pathExtension
        return SourceItem(
            path: "song/\(id)", name: fileName.isEmpty ? "\(title).\(ext)" : fileName, kind: .audio,
            size: audio?.int("filesize").map(Int64.init), title: title,
            artist: tag?.string("artist").flatMap { $0.isEmpty ? nil : $0 },
            album: tag?.string("album").flatMap { $0.isEmpty ? nil : $0 },
            trackNumber: tag?.int("track").flatMap { $0 > 0 ? $0 : nil },
            duration: audio?.double("duration"), fileExtension: ext, artworkRef: id
        )
    }

    private func info(_ api: String) async throws -> (String, Int) {
        if let cached = lock.withLock({ apiInfo[api] }) { return cached }
        let names = "SYNO.API.Auth,SYNO.AudioStation.Folder,SYNO.AudioStation.Album,SYNO.AudioStation.Song,SYNO.AudioStation.Stream,SYNO.AudioStation.Playlist,SYNO.AudioStation.Cover"
        let url = try config.baseURL().appendingPathComponent("webapi/query.cgi").appendingQuery([
            ("api", "SYNO.API.Info"), ("version", "1"), ("method", "query"), ("query", names),
        ])
        let json = try await http.json(for: URLRequest(url: url))
        guard json["success"] as? Bool == true, let data = json.dict("data") else {
            throw SourceError.protocolError("不是群晖 DSM，或未安装 Audio Station")
        }
        var parsed: [String: (String, Int)] = [:]
        for (key, value) in data {
            if let v = value as? [String: Any], let p = v.string("path") {
                parsed[key] = (p, v.int("maxVersion") ?? 1)
            }
        }
        lock.withLock { apiInfo = parsed }
        guard let result = parsed[api] else { throw SourceError.unsupported("NAS 上没有 \(api)，请安装 Audio Station") }
        return result
    }

    private func login() async throws -> String {
        if let sid = lock.withLock({ sid }) { return sid }
        let (apiPath, maxVersion) = try await info("SYNO.API.Auth")
        let url = try config.baseURL().appendingPathComponent("webapi").appendingPathComponent(apiPath).appendingQuery([
            ("api", "SYNO.API.Auth"), ("version", "\(min(maxVersion, 6))"), ("method", "login"),
            ("account", config.username), ("passwd", password), ("session", "AudioStation"), ("format", "sid"),
        ])
        let json = try await http.json(for: URLRequest(url: url))
        guard json["success"] as? Bool == true, let newSID = json.dict("data")?.string("sid") else {
            let code = json.dict("error")?.int("code") ?? -1
            let reason: String = switch code {
            case 400: "账号或密码错误"
            case 401: "账号已停用"
            case 402: "没有权限"
            case 403, 404, 406: "账号开启了两步验证，请为 MP9 单独建一个未开启两步验证的账号"
            case 407: "IP 已被封锁"
            default: "错误码 \(code)"
            }
            throw SourceError.authenticationFailed(reason)
        }
        lock.withLock { sid = newSID }
        return newSID
    }

    private func call(_ api: String, method: String, version: Int, params: [(String, String)]) async throws -> [String: Any] {
        let sid = try await login()
        let (apiPath, maxVersion) = try await info(api)
        let url = try config.baseURL().appendingPathComponent("webapi").appendingPathComponent(apiPath).appendingQuery(
            [("api", api), ("version", "\(min(maxVersion, version))"), ("method", method), ("_sid", sid)] + params
        )
        let json = try await http.json(for: URLRequest(url: url))
        guard json["success"] as? Bool == true else {
            let code = json.dict("error")?.int("code") ?? -1
            if code == 106 || code == 119 {
                lock.withLock { self.sid = nil }
                throw SourceError.authenticationFailed("会话已过期，请重试")
            }
            throw SourceError.protocolError("\(api) 错误码 \(code)")
        }
        return json.dict("data") ?? [:]
    }
}
