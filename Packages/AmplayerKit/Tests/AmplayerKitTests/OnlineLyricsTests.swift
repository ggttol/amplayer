import Foundation
import Testing
@testable import AmplayerCore
@testable import AmplayerSources

/// 模拟 lrclib.net：/get 先回一次 503，再按参数返回；/search 返回候选
final class MockLRCLib: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var getCalls = 0
    nonisolated(unsafe) static var lastQuery: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lrclib.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        Self.lastQuery = q
        var code = 200
        var body: Any = []
        if url.path.hasSuffix("/get") {
            Self.getCalls += 1
            if Self.getCalls == 1 {
                code = 503
                body = ["message": "busy"]
            } else if q["track_name"] == "晴天" {
                body = ["id": 1, "trackName": "晴天", "artistName": "周杰伦", "albumName": "叶惠美", "duration": 269.0,
                        "instrumental": false, "syncedLyrics": "[00:01.00]故事的小黄花", "plainLyrics": "故事的小黄花"]
            } else {
                code = 404
                body = ["message": "not found"]
            }
        } else {
            body = [
                ["id": 2, "trackName": "水手怕水", "artistName": "周杰伦", "albumName": "Live", "duration": 200.0,
                 "instrumental": false, "syncedLyrics": "[00:01.00]现场版", "plainLyrics": "现场版"],
                ["id": 3, "trackName": "水手怕水", "artistName": "周杰伦", "albumName": "惊叹号", "duration": 161.0,
                 "instrumental": false, "syncedLyrics": "[00:01.00]大海真可怕", "plainLyrics": "大海真可怕"],
                ["id": 4, "trackName": "别的歌", "artistName": "周杰伦", "duration": 161.0, "instrumental": false, "plainLyrics": "x"],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct OnlineLyricsTests {
    let client: OnlineLyrics = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLRCLib.self]
        return OnlineLyrics(session: URLSession(configuration: config))
    }()

    @Test func exactMatchRetriesWhenBusy() async {
        MockLRCLib.getCalls = 0
        let track = Track(sourceID: "x", path: "/a.flac", title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269.4)
        #expect(await client.lyrics(for: track) == "[00:01.00]故事的小黄花")
        #expect(MockLRCLib.getCalls == 2)
        #expect(MockLRCLib.lastQuery["duration"] == "269")
    }

    @Test func searchPicksClosestDuration() async {
        MockLRCLib.getCalls = 1
        // 文件名带编号和“歌手 - ”，没有艺术家标签
        let track = Track(sourceID: "x", path: "/a.ape", title: "08.周杰伦 - 水手怕水", duration: 160.5)
        #expect(await client.lyrics(for: track) == "[00:01.00]大海真可怕")
    }

    @Test func cleansTitles() {
        func clean(_ title: String, _ artist: String? = nil) -> (String, String?) {
            OnlineLyrics.cleanedTitleAndArtist(Track(sourceID: "x", path: "/a", title: title, artist: artist))
        }
        #expect(clean("08.周杰伦 - 水手怕水") == ("水手怕水", "周杰伦"))
        #expect(clean("01 - 晴天", "周杰伦") == ("晴天", "周杰伦"))
        #expect(clean("Hotel California", "Eagles") == ("Hotel California", "Eagles"))
        // 歌名本身带“ - ”且和歌手不一致时不拆
        #expect(clean("Part 1 - Intro", "Band") == ("Part 1 - Intro", "Band"))
        #expect(OnlineLyrics.normalize("Ｈｅｌｌｏ， World!") == "helloworld")
    }
}

/// 连真实 lrclib.net：AMP_LIVE_LYRICS=1 swift test --filter liveLRCLib
@Test(.enabled(if: ProcessInfo.processInfo.environment["AMP_LIVE_LYRICS"] == "1"))
func liveLRCLib() async throws {
    let track = Track(sourceID: "x", path: "/a.ape", title: "水手怕水", artist: "周杰伦", album: "惊叹号", duration: 160)
    let text = try #require(await OnlineLyrics.shared.lyrics(for: track))
    let lyrics = try #require(Lyrics.parse(text))
    #expect(lyrics.isSynced)
    #expect(text.contains("水手"))
}
