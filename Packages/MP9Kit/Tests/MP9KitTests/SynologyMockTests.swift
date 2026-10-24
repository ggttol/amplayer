import Foundation
import Testing
@testable import MP9Sources

/// 模拟 DSM Web API（按官方文档与社区资料的响应格式），验证群晖来源的请求流程
final class MockDSM: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var expireOnce = false
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let api = q["api"] ?? ""
        Self.lock.withLock { Self.log.append("\(url.path) \(api) \(q["method"] ?? "")") }
        var body: Any = ["success": false, "error": ["code": 102]]
        var raw: Data?
        switch api {
        case "SYNO.API.Info":
            body = ["success": true, "data": [
                "SYNO.API.Auth": ["path": "entry.cgi", "maxVersion": 7, "minVersion": 1],
                "SYNO.AudioStation.Folder": ["path": "AudioStation/folder.cgi", "maxVersion": 3, "minVersion": 1],
                "SYNO.AudioStation.Stream": ["path": "AudioStation/stream.cgi", "maxVersion": 2, "minVersion": 1],
                "SYNO.AudioStation.Album": ["path": "AudioStation/album.cgi", "maxVersion": 3, "minVersion": 1],
                "SYNO.AudioStation.Song": ["path": "AudioStation/song.cgi", "maxVersion": 3, "minVersion": 1],
            ]]
        case "SYNO.API.Auth":
            body = q["passwd"] == "good"
                ? ["success": true, "data": ["sid": "SID123"]]
                : ["success": false, "error": ["code": 400]]
        case "SYNO.AudioStation.Folder":
            if Self.lock.withLock({ let e = Self.expireOnce; Self.expireOnce = false; return e }) {
                body = ["success": false, "error": ["code": 119]]
            } else if q["_sid"] != "SID123" {
                body = ["success": false, "error": ["code": 106]]
            } else if q["id"] == nil {
                body = ["success": true, "data": ["items": [
                    ["id": "dir_1", "title": "流行", "type": "folder", "path": "/music/流行"],
                ], "offset": 0, "total": 1]]
            } else {
                body = ["success": true, "data": ["items": [
                    ["id": "music_9", "title": "song.flac", "type": "file", "path": "/music/流行/01 song.flac",
                     "additional": ["song_tag": ["title": "晴天", "artist": "周杰伦", "album": "叶惠美", "track": 1],
                                    "song_audio": ["duration": 269, "filesize": 3000, "bitrate": 900000]]],
                ], "offset": 0, "total": 1]]
            }
        case "SYNO.AudioStation.Stream":
            raw = Data("FLACDATA".utf8)
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

@Suite(.serialized)
struct SynologyMockTests {
    private func source(password: String) -> SynologySource {
        SynologySource(config: SourceConfig(kind: .synology, name: "DS", url: "https://nas.local:5001", username: "u"),
                       password: password, http: HTTPClient(protocolClasses: [MockDSM.self]))
    }

    @Test func browseAndStream() async throws {
        MockDSM.log = []
        let s = source(password: "good")
        let root = try await s.list(path: "folders")
        #expect(root.first?.path == "folder/dir_1")
        #expect(root.first?.name == "流行")
        let songs = try await s.list(path: "folder/dir_1")
        let song = try #require(songs.first)
        #expect(song.path == "song/music_9")
        #expect(song.title == "晴天")
        #expect(song.artist == "周杰伦")
        #expect(song.duration == 269)
        #expect(song.fileExtension == "flac")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("syno-\(UUID().uuidString).flac")
        try await s.download(path: song.path, to: dest)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "FLACDATA")
        try? FileManager.default.removeItem(at: dest)
        // 接口路径来自 SYNO.API.Info；stream.cgi 后带 0.<扩展名>
        #expect(MockDSM.log.contains("/webapi/entry.cgi SYNO.API.Auth login"))
        #expect(MockDSM.log.contains("/webapi/AudioStation/stream.cgi/0.flac SYNO.AudioStation.Stream stream"))
    }

    @Test func wrongPassword() async {
        await #expect(throws: SourceError.self) { try await source(password: "bad").testConnection() }
    }

    @Test func expiredSessionIsReported() async throws {
        let s = source(password: "good")
        _ = try await s.list(path: "folders")
        MockDSM.expireOnce = true
        await #expect(throws: SourceError.self) { try await s.list(path: "folders") }
        // 会话失效后重新登录即可继续
        #expect(try await s.list(path: "folders").count == 1)
    }
}
