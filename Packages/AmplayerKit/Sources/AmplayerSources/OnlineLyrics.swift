import Foundation
import AmplayerCore

/// 在线歌词：LRCLIB（https://lrclib.net，开放 API，社区歌词），加上网易云音乐、QQ 音乐、酷狗的公开网页接口（中文歌多）。
/// 几家同时查，按歌名、歌手、时长打分，挑最像的一条；带时间轴的优先。
public struct OnlineLyrics: Sendable {
    public enum Provider: String, Sendable, CaseIterable, Hashable {
        case lrclib, netease, qq, kugou

        public var name: String {
            switch self {
            case .lrclib: "LRCLIB"
            case .netease: "网易云音乐"
            case .qq: "QQ 音乐"
            case .kugou: "酷狗"
            }
        }
    }

    public struct Result: Sendable, Identifiable, Hashable {
        public var provider: Provider
        /// 该来源自己的歌曲编号（酷狗是“id|accesskey”）
        public var key: String
        public var title: String
        public var artist: String
        public var album: String
        public var duration: TimeInterval?
        public var synced: String?
        public var plain: String?
        public var isInstrumental: Bool
        /// 搜索结果只有歌曲信息时为 false，要再 load 一次拿歌词
        public var isLoaded: Bool

        public var id: String { provider.rawValue + ":" + key }
        /// 优先用带时间轴的
        public var text: String? { synced ?? plain }
    }

    public static let shared = OnlineLyrics()

    private let lrclib = URL(string: "https://lrclib.net/api")!
    private let session: URLSession
    private let providers: [Provider]

    public init(session: URLSession? = nil, providers: [Provider] = Provider.allCases) {
        self.providers = providers
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Amplayer"
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            config.httpAdditionalHeaders = ["User-Agent": "\(app)/\(version)"]
            self.session = URLSession(configuration: config)
        }
    }

    /// 自动匹配：先按歌名+歌手+专辑+时长在 LRCLIB 精确查，再各家一起搜索挑最接近的
    public func lyrics(for track: Track) async -> String? {
        let (title, artist) = Self.cleanedTitleAndArtist(track)
        guard !title.isEmpty else { return nil }
        var plain: String?
        if providers.contains(.lrclib), let artist, let duration = track.duration, duration > 0 {
            var query = [("track_name", title), ("artist_name", artist), ("duration", String(Int(duration.rounded())))]
            if let album = track.album, !album.isEmpty { query.append(("album_name", album)) }
            if let hit = try? await lrclibGet(query), !hit.isInstrumental {
                if let synced = hit.synced { return synced }
                plain = hit.plain
            }
        }
        let keyword = [artist, title].compactMap { $0 }.joined(separator: " ")
        let candidates = await withTaskGroup(of: (Provider, [Result]).self) { group in
            for provider in providers {
                group.addTask {
                    if provider == .lrclib, let artist {
                        let found = (try? await lrclibSearch([("track_name", title), ("artist_name", artist)])) ?? []
                        if !found.isEmpty { return (provider, found) }
                    }
                    return (provider, (try? await search(provider, keyword: keyword, duration: track.duration)) ?? [])
                }
            }
            var all: [Provider: [Result]] = [:]
            for await (provider, found) in group { all[provider] = found }
            // 按固定顺序拼起来，分数相同时结果不随网络快慢变
            return providers.flatMap { all[$0] ?? [] }
        }
        // 从最像的开始拿歌词，拿到带时间轴的就用；都没有时间轴就用第一份纯文本
        for candidate in Self.ranked(candidates, title: title, artist: artist, duration: track.duration).prefix(6) {
            guard let loaded = try? await load(candidate), !loaded.isInstrumental else { continue }
            if let synced = loaded.synced { return synced }
            plain = plain ?? loaded.plain
        }
        return plain
    }

    /// 手动搜索：各家一起查，结果交错排列（每家最靠前的几条先出来）；全部失败才抛错
    public func search(query: String) async throws -> [Result] {
        let outcomes = await withTaskGroup(of: (Provider, Swift.Result<[Result], Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider, .success(try await search(provider, keyword: query, duration: nil))) } catch { return (provider, .failure(error)) }
                }
            }
            var all: [(Provider, Swift.Result<[Result], Error>)] = []
            for await outcome in group { all.append(outcome) }
            return all.sorted { a, b in providers.firstIndex(of: a.0)! < providers.firstIndex(of: b.0)! }
        }
        let lists = outcomes.compactMap { try? $0.1.get() }
        if lists.isEmpty, let failure = outcomes.first, case let .failure(error) = failure.1 { throw error }
        var merged: [Result] = []
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count { merged.append(list[i]) }
        }
        return merged
    }

    /// 补上歌词内容（LRCLIB 的搜索结果本来就带）
    public func load(_ result: Result) async throws -> Result {
        guard !result.isLoaded else { return result }
        var r = result
        let text: String?
        switch result.provider {
        case .lrclib:
            return result
        case .netease:
            text = try await neteaseLyrics(id: result.key)
        case .qq:
            text = try await qqLyrics(mid: result.key)
        case .kugou:
            text = try await kugouLyrics(key: result.key)
        }
        r.isLoaded = true
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, let parsed = Lyrics.parse(text) {
            // 纯音乐各家会放一句“纯音乐，请欣赏”
            if parsed.lines.count <= 2, parsed.lines.contains(where: { $0.text.contains("纯音乐") }) {
                r.isInstrumental = true
            } else if parsed.isSynced {
                r.synced = text
            } else {
                r.plain = text
            }
        }
        return r
    }

    // MARK: 匹配

    static func best(_ results: [Result], title: String, artist: String?, duration: TimeInterval?) -> Result? {
        ranked(results, title: title, artist: artist, duration: duration).first
    }

    /// 按相似度从高到低排，歌名对不上的去掉
    static func ranked(_ results: [Result], title: String, artist: String?, duration: TimeInterval?) -> [Result] {
        let wantTitle = normalize(title), wantArtist = artist.map(normalize)
        func score(_ r: Result) -> Double? {
            guard !r.isInstrumental, !r.isLoaded || r.text != nil else { return nil }
            var s = 0.0
            let t = normalize(r.title)
            guard !t.isEmpty else { return nil }
            if t == wantTitle { s += 4 } else if t.contains(wantTitle) || wantTitle.contains(t) { s += 2 } else { return nil }
            if let wantArtist {
                let a = normalize(r.artist)
                if a == wantArtist { s += 3 } else if !a.isEmpty, a.contains(wantArtist) || wantArtist.contains(a) { s += 1.5 }
            }
            if let duration, let d = r.duration {
                let diff = abs(d - duration)
                if diff <= 3 { s += 3 } else if diff <= 10 { s += 1 } else if diff > 30 { s -= 3 }
            }
            // 还没拿歌词的多半也有时间轴，分数略低于已确认带时间轴的
            if r.synced != nil { s += 2 } else if !r.isLoaded { s += 1.5 }
            return s
        }
        let scored = results.enumerated().compactMap { i, r in score(r).map { (r, $0, i) } }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    /// 去掉文件名里常见的编号、“歌手 - ”前缀
    static func cleanedTitleAndArtist(_ track: Track) -> (String, String?) {
        var title = track.title.trimmingCharacters(in: .whitespaces)
        var artist = track.artist?.trimmingCharacters(in: .whitespaces)
        if artist?.isEmpty == true { artist = nil }
        // “08.周杰伦 - 水手怕水” / “01 - 晴天”
        if let range = title.range(of: #"^\d{1,3}\s*[.\-_、 ]\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        if let dash = title.range(of: " - ") {
            let left = String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(title[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if artist == nil || normalize(left) == normalize(artist!) {
                artist = artist ?? left
                title = right
            }
        }
        return (title, artist)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]"#, with: "", options: .regularExpression)
    }

    // MARK: 各家接口

    private func search(_ provider: Provider, keyword: String, duration: TimeInterval?) async throws -> [Result] {
        switch provider {
        case .lrclib: try await lrclibSearch([("q", keyword)])
        case .netease: try await neteaseSearch(keyword)
        case .qq: try await qqSearch(keyword)
        case .kugou: try await kugouSearch(keyword, duration: duration)
        }
    }

    private func lrclibGet(_ query: [(String, String)]) async throws -> Result? {
        guard let data = try await fetch(Self.get(lrclib.appendingPathComponent("get"), query)),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.result(json)
    }

    private func lrclibSearch(_ query: [(String, String)]) async throws -> [Result] {
        guard let data = try await fetch(Self.get(lrclib.appendingPathComponent("search"), query)),
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap(Self.result)
    }

    private static let netease = URL(string: "https://music.163.com/api")!

    private func neteaseSearch(_ keyword: String) async throws -> [Result] {
        let request = Self.get(Self.netease.appendingPathComponent("search/get"), [("s", keyword), ("type", "1"), ("limit", "10")], referer: "https://music.163.com/")
        guard let data = try await fetch(request),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = (json["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { s in
            guard let id = s["id"] as? Int, let name = s["name"] as? String else { return nil }
            let artists = (s["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return Result(provider: .netease, key: String(id), title: name, artist: artists.joined(separator: "/"),
                          album: (s["album"] as? [String: Any])?["name"] as? String ?? "",
                          duration: (s["duration"] as? Double).map { $0 / 1000 }, isInstrumental: false, isLoaded: false)
        }
    }

    private func neteaseLyrics(id: String) async throws -> String? {
        let request = Self.get(Self.netease.appendingPathComponent("song/lyric"), [("id", id), ("lv", "1"), ("tv", "-1")], referer: "https://music.163.com/")
        guard let data = try await fetch(request),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let original = (json["lrc"] as? [String: Any])?["lyric"] as? String
        // 外文歌带中文翻译：同样的时间戳接在后面，解析时会合并成“原文\n译文”两行
        if let original, let translation = (json["tlyric"] as? [String: Any])?["lyric"] as? String,
           translation.contains("["), !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return original + "\n" + translation
        }
        return original
    }

    private func qqSearch(_ keyword: String) async throws -> [Result] {
        var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = ["req": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop",
                                           "param": ["query": keyword, "num_per_page": 10, "page_num": 1, "search_type": 0]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let data = try await fetch(request),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req = json["req"] as? [String: Any], let d = req["data"] as? [String: Any],
              let song = (d["body"] as? [String: Any])?["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let mid = s["mid"] as? String, let name = s["name"] as? String else { return nil }
            let singers = (s["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return Result(provider: .qq, key: mid, title: name, artist: singers.joined(separator: "/"),
                          album: (s["album"] as? [String: Any])?["name"] as? String ?? "",
                          duration: s["interval"] as? Double, isInstrumental: false, isLoaded: false)
        }
    }

    private func qqLyrics(mid: String) async throws -> String? {
        let request = Self.get(URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!,
                               [("songmid", mid), ("format", "json"), ("nobase64", "1")], referer: "https://y.qq.com/")
        guard let data = try await fetch(request),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyric = json["lyric"] as? String else { return nil }
        return Self.decodeEntities(lyric)
    }

    private func kugouSearch(_ keyword: String, duration: TimeInterval?) async throws -> [Result] {
        var query = [("ver", "1"), ("man", "yes"), ("client", "pc"), ("keyword", keyword), ("hash", "")]
        if let duration { query.append(("duration", String(Int(duration * 1000)))) }
        guard let data = try await fetch(Self.get(URL(string: "https://lyrics.kugou.com/search")!, query)),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["candidates"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let id = c["id"] as? String ?? (c["id"] as? Int).map(String.init), let access = c["accesskey"] as? String,
                  let song = c["song"] as? String else { return nil }
            return Result(provider: .kugou, key: id + "|" + access, title: song, artist: c["singer"] as? String ?? "", album: "",
                          duration: (c["duration"] as? Double).map { $0 / 1000 }, isInstrumental: false, isLoaded: false)
        }
    }

    private func kugouLyrics(key: String) async throws -> String? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let query = [("ver", "1"), ("client", "pc"), ("id", parts[0]), ("accesskey", parts[1]), ("fmt", "lrc"), ("charset", "utf8")]
        guard let data = try await fetch(Self.get(URL(string: "https://lyrics.kugou.com/download")!, query)),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String, let decoded = Data(base64Encoded: content) else { return nil }
        return Lyrics.decode(decoded)
    }

    // MARK: 请求

    private static func get(_ url: URL, _ query: [(String, String)], referer: String? = nil) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return request
    }

    /// 404 返回 nil；服务器忙（429/5xx）重试两次
    private func fetch(_ request: URLRequest) async throws -> Data? {
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return data
            case 404: return nil
            case 429 where attempt < 2, 500...599 where attempt < 2:
                try await Task.sleep(for: .milliseconds(800 * (attempt + 1)))
            default:
                throw SourceError.http(code, request.url?.host ?? "")
            }
        }
        return nil
    }

    /// QQ 音乐的歌词里标点是 &#58; 这样的实体
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        for (entity, char) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    static func result(_ j: [String: Any]) -> Result? {
        guard let id = j["id"] as? Int else { return nil }
        func text(_ key: String) -> String? {
            guard let s = j[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return Result(
            provider: .lrclib, key: String(id), title: text("trackName") ?? text("name") ?? "", artist: text("artistName") ?? "",
            album: text("albumName") ?? "", duration: j["duration"] as? Double,
            synced: text("syncedLyrics"), plain: text("plainLyrics"),
            isInstrumental: j["instrumental"] as? Bool ?? false, isLoaded: true
        )
    }
}
