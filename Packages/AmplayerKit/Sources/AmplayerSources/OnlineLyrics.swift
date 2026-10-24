import Foundation
import AmplayerCore

/// 在线歌词：LRCLIB（https://lrclib.net，开放 API，无需 Key，歌词由社区提供）
public struct OnlineLyrics: Sendable {
    public struct Result: Sendable, Identifiable, Hashable {
        public var id: Int
        public var title: String
        public var artist: String
        public var album: String
        public var duration: TimeInterval?
        public var synced: String?
        public var plain: String?
        public var isInstrumental: Bool

        /// 优先用带时间轴的
        public var text: String? { synced ?? plain }
    }

    public static let shared = OnlineLyrics()

    private let base = URL(string: "https://lrclib.net/api")!
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.httpAdditionalHeaders = ["User-Agent": "Amplayer/0.1 (https://github.com/ggttol/amplayer)"]
            self.session = URLSession(configuration: config)
        }
    }

    /// 自动匹配：先按歌名+歌手+专辑+时长精确查，再搜索挑最接近的
    public func lyrics(for track: Track) async -> String? {
        let (title, artist) = Self.cleanedTitleAndArtist(track)
        guard !title.isEmpty else { return nil }
        if let artist, let duration = track.duration, duration > 0 {
            var query = [("track_name", title), ("artist_name", artist), ("duration", String(Int(duration.rounded())))]
            if let album = track.album, !album.isEmpty { query.append(("album_name", album)) }
            if let hit = try? await get(query), let text = hit.text, !hit.isInstrumental { return text }
        }
        var candidates: [Result] = []
        if let artist {
            candidates = (try? await search([("track_name", title), ("artist_name", artist)])) ?? []
        }
        if candidates.isEmpty {
            candidates = (try? await search(query: [artist, title].compactMap { $0 }.joined(separator: " "))) ?? []
        }
        return Self.best(candidates, title: title, artist: artist, duration: track.duration)?.text
    }

    /// 手动搜索
    public func search(query: String) async throws -> [Result] {
        try await search([("q", query)])
    }

    // MARK: 匹配

    static func best(_ results: [Result], title: String, artist: String?, duration: TimeInterval?) -> Result? {
        let wantTitle = normalize(title), wantArtist = artist.map(normalize)
        func score(_ r: Result) -> Double? {
            guard !r.isInstrumental, r.text != nil else { return nil }
            var s = 0.0
            let t = normalize(r.title)
            if t == wantTitle { s += 4 } else if t.contains(wantTitle) || wantTitle.contains(t) { s += 2 } else { return nil }
            if let wantArtist {
                let a = normalize(r.artist)
                if a == wantArtist { s += 3 } else if a.contains(wantArtist) || wantArtist.contains(a) { s += 1.5 }
            }
            if let duration, let d = r.duration {
                let diff = abs(d - duration)
                if diff <= 3 { s += 3 } else if diff <= 10 { s += 1 } else if diff > 30 { s -= 3 }
            }
            if r.synced != nil { s += 2 }
            return s
        }
        return results.compactMap { r in score(r).map { (r, $0) } }.max { $0.1 < $1.1 }.map(\.0)
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

    // MARK: 请求

    private func get(_ query: [(String, String)]) async throws -> Result? {
        let data = try await request("get", query)
        guard let data, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.result(json)
    }

    private func search(_ query: [(String, String)]) async throws -> [Result] {
        guard let data = try await request("search", query),
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap(Self.result)
    }

    /// 404 返回 nil；服务器忙（429/503）重试两次
    private func request(_ path: String, _ query: [(String, String)]) async throws -> Data? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        let request = URLRequest(url: components.url!)
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return data
            case 404: return nil
            case 429, 500...599 where attempt < 2:
                try await Task.sleep(for: .milliseconds(800 * (attempt + 1)))
            default:
                throw SourceError.http(code, "lrclib.net")
            }
        }
        return nil
    }

    static func result(_ j: [String: Any]) -> Result? {
        guard let id = j["id"] as? Int else { return nil }
        func text(_ key: String) -> String? {
            guard let s = j[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return Result(
            id: id, title: text("trackName") ?? text("name") ?? "", artist: text("artistName") ?? "",
            album: text("albumName") ?? "", duration: j["duration"] as? Double,
            synced: text("syncedLyrics"), plain: text("plainLyrics"),
            isInstrumental: j["instrumental"] as? Bool ?? false
        )
    }
}
