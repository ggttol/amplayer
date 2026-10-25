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
        return OnlineLyrics(session: URLSession(configuration: config), providers: [.lrclib])
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
        #expect(OnlineLyrics.decodeEntities("[00&#58;01.00]Don&apos;t &#x41;&amp;B") == "[00:01.00]Don't A&B")
    }
}

/// 模拟网易云、QQ 音乐、酷狗：搜索只给歌曲信息，歌词要再请求一次
final class MockChineseLyrics: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lyricRequests: [String] = []
    static let hosts: Set<String> = ["music.163.com", "u.y.qq.com", "c.y.qq.com", "lyrics.kugou.com"]

    override class func canInit(with request: URLRequest) -> Bool { hosts.contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var body: Any = [:]
        switch (url.host!, url.path) {
        case ("music.163.com", "/api/search/get"):
            body = ["result": ["songs": [
                ["id": 11, "name": "晴天 (原唱 周杰伦)", "artists": [["name": "翻唱歌手"]], "album": ["name": "翻唱"], "duration": 290_000],
                ["id": 12, "name": "纯音乐版", "artists": [["name": "周杰伦"]], "album": ["name": "x"], "duration": 269_000],
            ]]]
        case ("music.163.com", "/api/song/lyric"):
            Self.lyricRequests.append("netease:" + q["id"]!)
            body = ["lrc": ["lyric": "[00:00.00]翻唱版"]]
        case ("u.y.qq.com", _):
            body = ["req": ["code": 0, "data": ["body": ["song": ["list": [
                ["mid": "QQ1", "name": "晴天", "singer": [["name": "周杰伦"]], "album": ["name": "叶惠美"], "interval": 269],
            ]]]]]]
        case ("c.y.qq.com", _):
            Self.lyricRequests.append("qq:" + q["songmid"]!)
            body = ["retcode": 0, "lyric": "[ti&#58;晴天]\n[00&#58;29.00]故事的小黄花\n[00&#58;32.00]从出生那年就飘着"]
        case ("lyrics.kugou.com", "/search"):
            body = ["candidates": [["id": "77", "accesskey": "AK", "song": "晴天", "singer": "周杰伦", "duration": 269_000]]]
        case ("lyrics.kugou.com", "/download"):
            Self.lyricRequests.append("kugou:" + q["id"]! + "|" + q["accesskey"]!)
            body = ["content": Data("[00:00.00]纯音乐，请欣赏".utf8).base64EncodedString()]
        default:
            break
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ChineseLyricsTests {
    let client: OnlineLyrics = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockChineseLyrics.self]
        return OnlineLyrics(session: URLSession(configuration: config), providers: [.netease, .qq, .kugou])
    }()

    @Test func picksBestMatchAcrossProviders() async {
        MockChineseLyrics.lyricRequests = []
        let track = Track(sourceID: "x", path: "/a.flac", title: "晴天", artist: "周杰伦", duration: 269.4)
        let text = await client.lyrics(for: track)
        #expect(text?.hasPrefix("[ti:晴天]") == true)
        #expect(text?.contains("[00:29.00]故事的小黄花") == true)
        // QQ 音乐歌名、歌手、时长都对上，先拿它的，拿到同步歌词就不再请求别家
        #expect(MockChineseLyrics.lyricRequests == ["qq:QQ1"])
    }

    @Test func searchInterleavesAndLoads() async throws {
        let found = try await client.search(query: "周杰伦 晴天")
        #expect(found.map(\.id) == ["netease:11", "qq:QQ1", "kugou:77|AK", "netease:12"])
        #expect(found.allSatisfy { !$0.isLoaded })
        let kugou = try await client.load(found[2])
        #expect(kugou.isInstrumental)
        #expect(kugou.text == nil)
        let qq = try await client.load(found[1])
        #expect(qq.synced?.contains("故事的小黄花") == true)
    }
}

/// 连真实接口：AMP_LIVE_LYRICS=1 swift test --filter live
@Test(.enabled(if: ProcessInfo.processInfo.environment["AMP_LIVE_LYRICS"] == "1"))
func liveLRCLib() async throws {
    let track = Track(sourceID: "x", path: "/a.ape", title: "水手怕水", artist: "周杰伦", album: "惊叹号", duration: 160)
    let text = try #require(await OnlineLyrics.shared.lyrics(for: track))
    let lyrics = try #require(Lyrics.parse(text))
    #expect(lyrics.isSynced)
    #expect(text.contains("水手"))
}

/// 网易云、QQ 音乐、酷狗各自能搜到并下载到中文同步歌词
@Test(.enabled(if: ProcessInfo.processInfo.environment["AMP_LIVE_LYRICS"] == "1"), arguments: [OnlineLyrics.Provider.netease, .qq, .kugou])
func liveChineseProviders(_ provider: OnlineLyrics.Provider) async throws {
    let client = OnlineLyrics(providers: [provider])
    let track = Track(sourceID: "x", path: "/a.flac", title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269)
    let text = try #require(await client.lyrics(for: track))
    #expect(try #require(Lyrics.parse(text)).isSynced)
    #expect(text.contains("小黄花"))
}
