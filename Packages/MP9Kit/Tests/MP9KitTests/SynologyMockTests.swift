import Foundation
import Testing
@testable import MP9Sources

/// 模拟 DSM Web API（响应格式取自真实 DSM 7 抓包），验证群晖来源的请求流程
final class MockDSM: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var expireOnce = false
    nonisolated(unsafe) static var audioStationSongs = 1
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let body = request.httpBodyStreamData ?? request.httpBody, let s = String(data: body, encoding: .utf8) {
            for pair in s.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { q[kv[0]] = kv[1] }
            }
        }
        let api = q["api"] ?? ""
        Self.lock.withLock { Self.log.append("\(request.httpMethod ?? "GET") \(url.path) \(api) \(q["method"] ?? "")") }
        let validSID = q["_sid"] == "SID123"
        let expired = api != "SYNO.API.Auth" && api != "SYNO.API.Info" && Self.lock.withLock { let e = Self.expireOnce; Self.expireOnce = false; return e }
        var body: Any = ["success": false, "error": ["code": 102]]
        var raw: Data?
        switch api {
        case "SYNO.API.Info":
            body = ["success": true, "data": [
                "SYNO.API.Auth": ["path": "entry.cgi", "maxVersion": 7, "minVersion": 1],
                "SYNO.FileStation.List": ["path": "entry.cgi", "maxVersion": 2, "minVersion": 1],
                "SYNO.FileStation.Download": ["path": "entry.cgi", "maxVersion": 2, "minVersion": 1],
                "SYNO.AudioStation.Folder": ["path": "AudioStation/folder.cgi", "maxVersion": 3, "minVersion": 1],
                "SYNO.AudioStation.Stream": ["path": "AudioStation/stream.cgi", "maxVersion": 2, "minVersion": 1],
                "SYNO.AudioStation.Song": ["path": "AudioStation/song.cgi", "maxVersion": 3, "minVersion": 1],
            ]]
        case "SYNO.API.Auth":
            body = q["passwd"] == "p+&=!@#" && request.httpMethod == "POST"
                ? ["success": true, "data": ["sid": "SID123"]]
                : ["success": false, "error": ["code": 400]]
        case _ where expired || !validSID:
            body = ["success": false, "error": ["code": 119]]
        case "SYNO.FileStation.List" where q["method"] == "list_share":
            body = ["success": true, "data": ["offset": 0, "total": 3, "shares": [
                ["isdir": true, "name": "docker", "path": "/docker"],
                ["isdir": true, "name": "music", "path": "/music"],
                ["isdir": true, "name": "音乐", "path": "/音乐"],
            ]]]
        case "SYNO.FileStation.List":
            body = ["success": true, "data": ["offset": 0, "total": 2, "files": [
                ["isdir": true, "name": "周杰伦", "path": "\(q["folder_path"]!)/周杰伦"],
                ["isdir": false, "name": "晴天.flac", "path": "\(q["folder_path"]!)/晴天.flac", "additional": ["size": 1234]],
            ]]]
        case "SYNO.FileStation.Download":
            raw = Data("FLAC:\(q["path"] ?? "")".utf8)
        case "SYNO.AudioStation.Song":
            body = ["success": true, "data": ["offset": 0, "total": Self.audioStationSongs, "songs": []]]
        case "SYNO.AudioStation.Folder":
            body = ["success": true, "data": ["items": [
                ["id": "music_9", "title": "song.flac", "type": "file", "path": "/music/流行/01 song.flac",
                 "additional": ["song_tag": ["title": "晴天", "artist": "周杰伦", "album": "叶惠美", "track": 1],
                                "song_audio": ["duration": 269, "filesize": 3000]]],
            ], "offset": 0, "total": 1]]
        case "SYNO.AudioStation.Stream":
            raw = Data("STREAM".utf8)
        default:
            break
        }
        let data = raw ?? (try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol 拿到的 POST 请求体在 httpBodyStream 里
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite(.serialized)
struct SynologyMockTests {
    private func source(password: String = "p+&=!@#") -> SynologySource {
        SynologySource(config: SourceConfig(kind: .synology, name: "DS", url: "https://nas.local:5001", username: "u"),
                       password: password, http: HTTPClient(protocolClasses: [MockDSM.self]))
    }

    private func temp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("syno-\(UUID().uuidString).\(ext)")
    }

    @Test func rootListsSharesAndAudioStation() async throws {
        MockDSM.audioStationSongs = 1
        let root = try await source().list(path: "/")
        // docker 等系统共享被隐藏
        #expect(root.map(\.path) == ["fs:/music", "fs:/音乐", "as:albums", "as:folders", "as:playlists"])
    }

    @Test func rootHidesEmptyAudioStation() async throws {
        MockDSM.audioStationSongs = 0
        let root = try await source().list(path: "/")
        #expect(root.map(\.path) == ["fs:/music", "fs:/音乐"])
        MockDSM.audioStationSongs = 1
    }

    @Test func fileStationBrowseAndDownload() async throws {
        MockDSM.log = []
        let s = source()
        let items = try await s.list(path: "fs:/music")
        #expect(items.map(\.path) == ["fs:/music/周杰伦", "fs:/music/晴天.flac"])
        #expect(items[1].kind == .audio && items[1].size == 1234)
        let dest = temp("flac")
        try await s.download(path: "fs:/music/晴天.flac", to: dest)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "FLAC:/music/晴天.flac")
        try? FileManager.default.removeItem(at: dest)
        // 密码用 POST 提交，不出现在 URL 里
        #expect(MockDSM.log.contains("POST /webapi/entry.cgi SYNO.API.Auth login"))
    }

    @Test func audioStationSongAndStream() async throws {
        MockDSM.log = []
        let s = source()
        let song = try #require(try await s.list(path: "as:folders").first)
        #expect(song.path == "song/music_9" && song.title == "晴天" && song.artist == "周杰伦" && song.duration == 269)
        let dest = temp("flac")
        try await s.download(path: song.path, to: dest)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "STREAM")
        try? FileManager.default.removeItem(at: dest)
        #expect(MockDSM.log.contains("GET /webapi/AudioStation/stream.cgi/0.flac SYNO.AudioStation.Stream stream"))
    }

    @Test func wrongPassword() async {
        await #expect(throws: SourceError.self) { try await source(password: "bad").testConnection() }
    }

    @Test func expiredSessionReloginsTransparently() async throws {
        let s = source()
        _ = try await s.list(path: "fs:/music")
        MockDSM.expireOnce = true
        #expect(try await s.list(path: "fs:/music").count == 2)
    }

    @Test func expiredSessionDuringDownloadIsNotCached() async throws {
        let s = source()
        _ = try await s.list(path: "fs:/music")
        MockDSM.expireOnce = true
        let dest = temp("flac")
        try await s.download(path: "fs:/music/晴天.flac", to: dest)
        // 第一次拿到的是 JSON 错误，应自动重新登录并下载到真正的文件
        #expect(try String(contentsOf: dest, encoding: .utf8) == "FLAC:/music/晴天.flac")
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func quickConnectIDDetection() {
        #expect(QuickConnectResolver.quickConnectID(from: "myds") == "myds")
        #expect(QuickConnectResolver.quickConnectID(from: " QuickConnect.to/myds ") == "myds")
        #expect(QuickConnectResolver.quickConnectID(from: "https://quickconnect.cn/myds/") == "myds")
        #expect(QuickConnectResolver.quickConnectID(from: "myds.quickconnect.cn") == "myds")
        #expect(QuickConnectResolver.quickConnectID(from: "https://nas.example.com:5001") == nil)
        #expect(QuickConnectResolver.quickConnectID(from: "192.168.2.10") == nil)
        #expect(QuickConnectResolver.quickConnectID(from: "nas.local:5001") == nil)
        #expect(SynologySource(config: SourceConfig(kind: .synology, name: "x", url: "https://nas.example.com:5001"), password: nil).quickConnectID == nil)
        #expect(SynologySource(config: SourceConfig(kind: .synology, name: "x", url: "myds"), password: nil).quickConnectID == "myds")
    }

    @Test func quickConnectCandidates() {
        // 结构取自 cnc.quickconnect.cn 的真实响应（地址已替换）
        let raw: [String: Any] = [
            "server": ["ddns": "NULL", "fqdn": "NULL", "external": ["ip": "1.2.3.4"], "interface": [["ip": "192.168.2.10"]]],
            "service": ["port": 5001, "ext_port": 49925, "pingpong_desc": ["example.com:49925", "1.2.3.4:49925"]],
            "smartdns": ["host": "ID.direct.quickconnect.cn", "lan": ["192-168-2-10.ID.direct.quickconnect.cn"], "lanv6": []],
        ]
        let list = QuickConnectResolver.candidates(from: .init(raw: raw, controlHost: "cnc.quickconnect.cn"))
        #expect(list.map(\.url.absoluteString) == [
            "https://192-168-2-10.ID.direct.quickconnect.cn:5001",
            "https://example.com:49925",
            "https://ID.direct.quickconnect.cn:49925",
            "https://ID.direct.quickconnect.cn:5001",
        ])
    }

    @Test func formBodyEscapesSpecialCharacters() {
        #expect(String(data: SynologySource.formBody([("passwd", "a+b&c=d !@#")]), encoding: .utf8) == "passwd=a%2Bb%26c%3Dd%20%21%40%23")
    }
}
