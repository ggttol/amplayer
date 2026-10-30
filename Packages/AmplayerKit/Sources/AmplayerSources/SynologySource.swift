import Foundation
import AmplayerCore

/// 群晖 DSM：File Station 浏览共享文件夹（不依赖索引）+ Audio Station 曲库（有索引时提供专辑、标签、封面）
///
/// 地址可以是 https://IP:5001，也可以是 QuickConnect ID。
///
/// 路径约定：
/// - `/` 根：共享文件夹列表，Audio Station 有曲目时再加“专辑 / 文件夹 / 播放列表”入口
/// - `fs:<路径>` File Station 目录或文件（例如 `fs:/music/周杰伦/晴天.flac`）
/// - `as:folders`、`as:folder/<dir_id>`、`as:albums`、`as:album/<专辑>\u{1F}<专辑艺术家>`、`as:playlists`、`as:playlist/<id>`
/// - Audio Station 曲目 `song/<music_id>`
public final class SynologySource: MediaSource, @unchecked Sendable {
    public let config: SourceConfig
    private let password: String
    private let http: HTTPClient
    private let quickConnect: QuickConnectResolver
    private let lock = NSLock()
    private var sid: String?
    private var resolvedBase: URL?
    /// SYNO.API.Info 返回的 API → (路径, 最高版本)
    private var apiInfo: [String: (path: String, maxVersion: Int)] = [:]
    private var audioStationHasSongs: Bool?

    private static let separator: Character = "\u{1F}"
    /// 共享文件夹列表里隐藏的系统共享
    private static let hiddenShares: Set<String> = [
        "docker", "surveillance", "web", "web_packages", "activebackupforbusiness", "netbackup", "homes", "usbshare",
    ]
    private static let apis = [
        "SYNO.API.Auth", "SYNO.FileStation.List", "SYNO.FileStation.Download",
        "SYNO.AudioStation.Folder", "SYNO.AudioStation.Album", "SYNO.AudioStation.Song",
        "SYNO.AudioStation.Stream", "SYNO.AudioStation.Playlist", "SYNO.AudioStation.Cover",
    ]

    public convenience init(config: SourceConfig, password: String?) {
        self.init(config: config, password: password, http: .forConfig(config), quickConnect: .shared)
    }

    init(config: SourceConfig, password: String?, http: HTTPClient, quickConnect: QuickConnectResolver = .shared) {
        self.config = config
        self.password = password ?? ""
        self.http = http
        self.quickConnect = quickConnect
    }

    /// 地址栏填的是 QuickConnect ID 时返回 ID
    public var quickConnectID: String? {
        let lower = config.url.lowercased()
        if lower.contains("://") && !lower.contains("quickconnect.") { return nil }
        return QuickConnectResolver.quickConnectID(from: config.url)
    }

    // MARK: 浏览

    public func list(path: String) async throws -> [SourceItem] {
        if path == "/" || path.isEmpty {
            var items = try await shares()
            if try await hasAudioStationSongs() {
                items += [
                    SourceItem(path: "as:albums", name: String(localized: "Audio Station · 专辑"), kind: .directory),
                    SourceItem(path: "as:folders", name: String(localized: "Audio Station · 文件夹"), kind: .directory),
                    SourceItem(path: "as:playlists", name: String(localized: "Audio Station · 播放列表"), kind: .directory),
                ]
            }
            return items
        }
        if path.hasPrefix("fs:") { return try await fileStationList(String(path.dropFirst(3))) }
        return try await audioStationList(path)
    }

    public func download(path: String, to destination: URL) async throws {
        if path.hasPrefix("fs:") {
            let url = try await endpoint("SYNO.FileStation.Download", method: "download", version: 2, params: [
                ("path", String(path.dropFirst(3))), ("mode", "download"),
            ])
            try await withSessionRetry { sid in
                try await self.http.download(URLRequest(url: url.withSID(sid)), to: destination)
                try Self.rejectErrorPayload(at: destination)
            }
            return
        }
        guard path.hasPrefix("song/") else { throw SourceError.protocolError(String(localized: "不是曲目：\(path)")) }
        let id = String(path.dropFirst("song/".count))
        let (apiPath, maxVersion) = try await info("SYNO.AudioStation.Stream")
        let ext = destination.pathExtension.isEmpty ? "mp3" : destination.pathExtension
        // stream.cgi 后面带上 0.<扩展名>，与官方客户端一致
        let url = try await baseURL().appendingPathComponent("webapi").appendingPathComponent(apiPath).appendingPathComponent("0.\(ext)")
            .appendingQuery([("api", "SYNO.AudioStation.Stream"), ("version", "\(min(maxVersion, 2))"), ("method", "stream"), ("id", id)])
        try await withSessionRetry { sid in
            try await self.http.download(URLRequest(url: url.withSID(sid)), to: destination)
            try Self.rejectErrorPayload(at: destination)
        }
    }

    public func lyrics(for track: Track) async -> String? {
        if track.path.hasPrefix("fs:") { return await siblingLyrics(of: track.path) }
        guard track.path.hasPrefix("song/") else { return nil }
        let id = String(track.path.dropFirst("song/".count))
        guard let data = try? await call("SYNO.AudioStation.Lyrics", method: "getlyrics", version: 2, params: [("id", id)]),
              let text = data.string("lyrics"), Lyrics.parse(text) != nil else { return nil }
        return text
    }

    public func artworkRequest(ref: String) async throws -> URLRequest? {
        let url = try await endpoint("SYNO.AudioStation.Cover", method: "getsongcover", version: 3, params: [("id", ref), ("library", "shared")])
        return URLRequest(url: url.withSID(try await login()))
    }

    public func testConnection() async throws {
        lock.withLock { sid = nil; resolvedBase = nil; apiInfo = [:]; audioStationHasSongs = nil }
        if let id = quickConnectID { await quickConnect.invalidate(id) }
        _ = try await login()
    }

    /// 当前实际连接的地址（QuickConnect 解析后的结果），用于界面显示
    public func connectedAddress() async throws -> URL { try await baseURL() }

    // MARK: File Station

    private func shares() async throws -> [SourceItem] {
        let data = try await call("SYNO.FileStation.List", method: "list_share", version: 2, params: [
            ("sort_by", "name"), ("offset", "0"), ("limit", "1000"),
        ])
        return data.array("shares").compactMap { s in
            guard let name = s.string("name"), let path = s.string("path"),
                  !Self.hiddenShares.contains(name.lowercased()), !name.hasPrefix("@"), !name.hasPrefix("#") else { return nil }
            return SourceItem(path: "fs:\(path)", name: name, kind: .directory)
        }
    }

    private func fileStationList(_ folder: String) async throws -> [SourceItem] {
        var items: [SourceItem] = []
        var offset = 0
        let pageSize = 2000
        while true {
            let data = try await call("SYNO.FileStation.List", method: "list", version: 2, params: [
                ("folder_path", folder), ("offset", "\(offset)"), ("limit", "\(pageSize)"),
                ("sort_by", "name"), ("sort_direction", "asc"), ("additional", "[\"size\"]"),
            ])
            let files = data.array("files")
            for f in files {
                guard let name = f.string("name"), let path = f.string("path"), !name.hasPrefix("@"), !name.hasPrefix("#") else { continue }
                if f["isdir"] as? Bool == true {
                    items.append(SourceItem(path: "fs:\(path)", name: name, kind: .directory))
                } else {
                    items.append(SourceItem(path: "fs:\(path)", name: name, kind: .audio, size: f.dict("additional")?.int("size").map(Int64.init)))
                }
            }
            offset += files.count
            if files.isEmpty || offset >= (data.int("total") ?? 0) { break }
        }
        return items
    }

    // MARK: Audio Station

    private func hasAudioStationSongs() async throws -> Bool {
        if let cached = lock.withLock({ audioStationHasSongs }) { return cached }
        var has = false
        if (try? await info("SYNO.AudioStation.Song")) != nil,
           let data = try? await call("SYNO.AudioStation.Song", method: "list", version: 3, params: [("library", "all"), ("offset", "0"), ("limit", "1")]) {
            has = (data.int("total") ?? 0) > 0
        }
        lock.withLock { audioStationHasSongs = has }
        return has
    }

    private func audioStationList(_ path: String) async throws -> [SourceItem] {
        switch path {
        case "as:folders":
            return try await asFolder(id: nil)
        case "as:albums":
            let data = try await call("SYNO.AudioStation.Album", method: "list", version: 3, params: [
                ("library", "all"), ("offset", "0"), ("limit", "5000"), ("sort_by", "name"), ("sort_direction", "ASC"),
            ])
            return data.array("albums").compactMap { a in
                guard let name = a.string("name") else { return nil }
                let artist = a.string("album_artist") ?? a.string("display_artist") ?? ""
                return SourceItem(path: "as:album/\(name)\(Self.separator)\(artist)", name: artist.isEmpty ? name : "\(name) — \(artist)", kind: .directory)
            }
        case "as:playlists":
            let data = try await call("SYNO.AudioStation.Playlist", method: "list", version: 3, params: [
                ("library", "all"), ("offset", "0"), ("limit", "1000"),
            ])
            return data.array("playlists").compactMap { p in
                guard let id = p.string("id") else { return nil }
                return SourceItem(path: "as:playlist/\(id)", name: p.string("name") ?? id, kind: .directory)
            }
        default:
            break
        }
        if path.hasPrefix("as:folder/") {
            return try await asFolder(id: String(path.dropFirst("as:folder/".count)))
        }
        if path.hasPrefix("as:album/") {
            let parts = path.dropFirst("as:album/".count).split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            var params: [(String, String)] = [
                ("library", "all"), ("offset", "0"), ("limit", "5000"), ("album", parts.first ?? ""),
                ("additional", "song_tag,song_audio"), ("sort_by", "track"), ("sort_direction", "ASC"),
            ]
            if parts.count > 1, !parts[1].isEmpty { params.append(("album_artist", parts[1])) }
            let data = try await call("SYNO.AudioStation.Song", method: "list", version: 3, params: params)
            return data.array("songs").compactMap(songItem)
        }
        if path.hasPrefix("as:playlist/") {
            let id = String(path.dropFirst("as:playlist/".count))
            let data = try await call("SYNO.AudioStation.Playlist", method: "getinfo", version: 3, params: [
                ("id", id), ("library", "all"), ("additional", "songs_song_tag,songs_song_audio"),
            ])
            let songs = data.array("playlists").first?.dict("additional")?.array("songs") ?? []
            return songs.compactMap(songItem)
        }
        throw SourceError.protocolError(String(localized: "未知路径 \(path)"))
    }

    private func asFolder(id: String?) async throws -> [SourceItem] {
        var params: [(String, String)] = [
            ("library", "shared"), ("offset", "0"), ("limit", "5000"), ("sort_by", "title"), ("sort_direction", "ASC"),
            ("additional", "song_tag,song_audio"),
        ]
        if let id { params.append(("id", id)) }
        let data = try await call("SYNO.AudioStation.Folder", method: "list", version: 3, params: params)
        return data.array("items").compactMap { i in
            guard let itemID = i.string("id") else { return nil }
            if i.string("type") == "folder" {
                return SourceItem(path: "as:folder/\(itemID)", name: i.string("title") ?? itemID, kind: .directory)
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

    // MARK: 连接与会话

    private func baseURL() async throws -> URL {
        if let url = lock.withLock({ resolvedBase }) { return url }
        let url: URL = if let id = quickConnectID { try await quickConnect.resolve(id) } else { try config.baseURL() }
        lock.withLock { resolvedBase = url }
        return url
    }

    private func info(_ api: String) async throws -> (String, Int) {
        if let cached = lock.withLock({ apiInfo[api] }) { return cached }
        let url = try await baseURL().appendingPathComponent("webapi/query.cgi").appendingQuery([
            ("api", "SYNO.API.Info"), ("version", "1"), ("method", "query"), ("query", Self.apis.joined(separator: ",")),
        ])
        let json: [String: Any]
        do {
            json = try await http.json(for: URLRequest(url: url))
        } catch let error as URLError {
            await dropConnection()
            throw SourceError.http(0, String(localized: "连不上 NAS：\(error.localizedDescription)"))
        }
        guard json["success"] as? Bool == true, let data = json.dict("data") else {
            throw SourceError.protocolError(String(localized: "这不是群晖 DSM 地址"))
        }
        var parsed: [String: (String, Int)] = [:]
        for (key, value) in data {
            if let v = value as? [String: Any], let p = v.string("path") { parsed[key] = (p, v.int("maxVersion") ?? 1) }
        }
        lock.withLock { apiInfo = parsed }
        guard let result = parsed[api] else {
            throw SourceError.unsupported(api.hasPrefix("SYNO.AudioStation") ? String(localized: "NAS 上没有 Audio Station") : String(localized: "NAS 不支持 \(api)"))
        }
        return result
    }

    /// 网络错误后重新解析 QuickConnect（例如从家里 Wi-Fi 换到蜂窝网络）
    private func dropConnection() async {
        lock.withLock { resolvedBase = nil; apiInfo = [:] }
        if let id = quickConnectID { await quickConnect.invalidate(id) }
    }

    private func login() async throws -> String {
        if let sid = lock.withLock({ sid }) { return sid }
        let (apiPath, maxVersion) = try await info("SYNO.API.Auth")
        var request = URLRequest(url: try await baseURL().appendingPathComponent("webapi").appendingPathComponent(apiPath))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // 用 POST 提交，避免密码出现在 URL 和服务器访问日志里
        request.httpBody = Self.formBody([
            ("api", "SYNO.API.Auth"), ("version", "\(min(maxVersion, 6))"), ("method", "login"),
            ("account", config.username), ("passwd", password), ("session", "AudioStation"), ("format", "sid"),
        ])
        let json = try await http.json(for: request)
        guard json["success"] as? Bool == true, let newSID = json.dict("data")?.string("sid") else {
            throw SourceError.authenticationFailed(Self.loginError(json.dict("error")?.int("code") ?? -1))
        }
        lock.withLock { sid = newSID }
        return newSID
    }

    /// application/x-www-form-urlencoded（对 + & = 等字符全部转义）
    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func loginError(_ code: Int) -> String {
        switch code {
        case 400: String(localized: "账号或密码错误")
        case 401: String(localized: "账号已停用")
        case 402: String(localized: "没有权限")
        case 403, 404, 406: String(localized: "账号开启了两步验证，请为 Amplayer 单独建一个未开启两步验证的账号")
        case 407: String(localized: "IP 已被 NAS 自动封锁（多次登录失败），请在 DSM“安全性 › 账户”里解除")
        case 408, 409, 410: String(localized: "密码已过期，请先在 DSM 网页里修改密码")
        default: String(localized: "错误码 \(code)")
        }
    }

    private func endpoint(_ api: String, method: String, version: Int, params: [(String, String)]) async throws -> URL {
        let (apiPath, maxVersion) = try await info(api)
        return try await baseURL().appendingPathComponent("webapi").appendingPathComponent(apiPath).appendingQuery(
            [("api", api), ("version", "\(min(maxVersion, version))"), ("method", method)] + params
        )
    }

    /// 会话过期（106/107/119）时自动重新登录再试一次
    private func call(_ api: String, method: String, version: Int, params: [(String, String)]) async throws -> [String: Any] {
        let url = try await endpoint(api, method: method, version: version, params: params)
        for attempt in 0..<2 {
            let json = try await http.json(for: URLRequest(url: url.withSID(try await login())))
            if json["success"] as? Bool == true { return json.dict("data") ?? [:] }
            let code = json.dict("error")?.int("code") ?? -1
            if [106, 107, 119].contains(code), attempt == 0 {
                lock.withLock { sid = nil }
                continue
            }
            throw SourceError.protocolError(Self.apiError(api, code))
        }
        throw SourceError.authenticationFailed(String(localized: "会话已过期"))
    }

    /// 下载时会话过期，DSM 返回的是 HTTP 200 + JSON 错误而不是文件；识别出来后重新登录再试一次
    private func withSessionRetry(_ body: (String) async throws -> Void) async throws {
        for attempt in 0..<2 {
            do {
                try await body(try await login())
            } catch SourceError.http(let code, _) where (code == 401 || code == 403) && attempt == 0 {
                lock.withLock { sid = nil }
                continue
            }
            return
        }
    }

    /// 下载结果其实是 DSM 的 JSON 错误时抛出（并删除该文件）
    static func rejectErrorPayload(at url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 4096, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == false else { return }
        try? FileManager.default.removeItem(at: url)
        let code = json.dict("error")?.int("code") ?? -1
        throw SourceError.http([105, 106, 107, 119].contains(code) ? 401 : 404, String(localized: "DSM 错误码 \(code)"))
    }

    static func apiError(_ api: String, _ code: Int) -> String {
        if api.hasPrefix("SYNO.FileStation") {
            switch code {
            case 105, 407: return String(localized: "没有访问这个文件夹的权限")
            case 408: return String(localized: "文件或文件夹不存在")
            default: break
            }
        }
        if api == "SYNO.AudioStation.Folder" && code == 401 {
            return String(localized: "Audio Station 还没有索引这个文件夹，可以改用共享文件夹浏览")
        }
        return String(localized: "\(api) 错误码 \(code)")
    }
}

private extension URL {
    func withSID(_ sid: String) -> URL { appendingQuery([("_sid", sid)]) }
}
