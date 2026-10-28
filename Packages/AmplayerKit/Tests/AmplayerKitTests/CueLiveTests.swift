import Foundation
import Testing
@testable import AmplayerAudio
@testable import AmplayerCache
@testable import AmplayerCore
@testable import AmplayerSources

/// 真实服务器上的 CUE 分轨（边转码边发、不知道大小）：SUBSONIC_URL / USER / PASS / CUE_ALBUM 都设置时才跑
@Test func cueTrackStreamsLive() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["SUBSONIC_URL"], let user = env["SUBSONIC_USER"], let pass = env["SUBSONIC_PASS"], let albumID = env["CUE_ALBUM"] else { return }
    var config = SourceConfig(kind: .subsonic, name: "live", url: url)
    config.username = user
    let source = SubsonicSource(config: config, password: pass)
    let songs = try await source.album(id: albumID).songs
    let song = try #require(songs.dropFirst(Int.random(in: 0..<max(1, songs.count))).first)
    let track = song.makeTrack(sourceID: config.id)
    #expect(track.fileSize == nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cue-live-\(UUID().uuidString)")
    let cache = AudioCache(cacheDirectory: root.appendingPathComponent("c"), offlineDirectory: root.appendingPathComponent("o"))
    let started = Date()
    guard case .growing(let file) = try await cache.playable(for: track, source: source) else {
        Issue.record("CUE 分轨应该边下边播")
        return
    }
    let gotHead = Date().timeIntervalSince(started)
    let stream = try await GrowingFileStream.open(file, fallbackDuration: track.duration)
    let wait = Date().timeIntervalSince(started)
    print("cue live: \(song.title ?? "") 收到开头 \(String(format: "%.1f", gotHead)) 秒，能播放 \(String(format: "%.1f", wait)) 秒，已收到 \(file.receivedBytes / 1024) KB，下载完：\(file.isFinished)")
    #expect(stream.length > 0)
    _ = try await cache.localURL(for: track, source: source)
}
