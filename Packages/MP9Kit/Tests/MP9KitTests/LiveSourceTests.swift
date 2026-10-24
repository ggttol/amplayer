import AVFoundation
import Foundation
import Testing
@testable import MP9Core
@testable import MP9Sources

/// 针对真实服务器的端到端测试，默认跳过。启动 Tools/test-servers.sh 里的容器后用 MP9_LIVE=1 swift test 运行。
private let live = ProcessInfo.processInfo.environment["MP9_LIVE"] == "1"
private let host = ProcessInfo.processInfo.environment["MP9_LIVE_HOST"] ?? "127.0.0.1"

/// 列根目录 → 递归收集曲目 → 下载第一首 → 用 AVAudioFile 解码验证
private func exercise(_ source: any MediaSource, expectAtLeast count: Int = 3) async throws -> [Track] {
    try await source.testConnection()
    let root = try await source.list(path: source.rootPath)
    #expect(!root.isEmpty, "\(source.config.kind) 根目录为空")
    let tracks = try await source.collectTracks(path: source.rootPath)
    #expect(tracks.count >= count, "\(source.config.kind) 只找到 \(tracks.count) 首")
    let track = try #require(tracks.first)
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp9-live-\(UUID().uuidString)")
        .appendingPathExtension(track.fileExtension.isEmpty ? "mp3" : track.fileExtension)
    defer { try? FileManager.default.removeItem(at: dest) }
    try await source.download(path: track.path, to: dest)
    let file = try AVAudioFile(forReading: dest)
    #expect(file.length > 44_100, "\(source.config.kind) 下载的文件太短")
    return tracks
}

@Suite(.enabled(if: live), .serialized)
struct LiveSourceTests {
    @Test func webDAV() async throws {
        let config = SourceConfig(kind: .webdav, name: "rclone", url: "http://\(host):18080/", username: "mp9")
        let tracks = try await exercise(WebDAVSource(config: config, password: "mp9pass"))
        #expect(tracks.contains { $0.title.contains("中文标题") })
    }

    @Test func webDAVWrongPassword() async throws {
        let config = SourceConfig(kind: .webdav, name: "rclone", url: "http://\(host):18080/", username: "mp9")
        await #expect(throws: SourceError.self) { try await WebDAVSource(config: config, password: "bad").list(path: "/") }
    }

    @Test func smb() async throws {
        let config = SourceConfig(kind: .smb, name: "samba", url: "smb://\(host)", username: "mp9")
        let source = SMBSource(config: config, password: "mp9pass")
        let shares = try await source.list(path: "/")
        #expect(shares.contains { $0.name == "Music" })
        _ = try await exercise(SMBSource(config: SourceConfig(kind: .smb, name: "samba", url: "smb://\(host)/Music", username: "mp9"), password: "mp9pass"))
    }

    @Test func subsonic() async throws {
        let config = SourceConfig(kind: .subsonic, name: "navidrome", url: "http://\(host):14533", username: "mp9")
        let source = SubsonicSource(config: config, password: "mp9pass")
        let artists = try await source.list(path: "artists")
        #expect(!artists.isEmpty)
        let random = try await source.list(path: "random")
        #expect(random.count >= 3)
        let song = try #require(random.first)
        #expect(song.duration ?? 0 > 0)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("mp9-live-sub.\(song.fileExtension ?? "mp3")")
        try await source.download(path: song.path, to: dest)
        #expect(try AVAudioFile(forReading: dest).length > 44_100)
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func jellyfin() async throws {
        let config = SourceConfig(kind: .jellyfin, name: "jellyfin", url: "http://\(host):18096", username: "mp9")
        let source = JellyfinSource(config: config, password: "mp9pass")
        let libraries = try await source.list(path: "/")
        let music = try #require(libraries.first { $0.path.hasPrefix("library/") })
        let albums = try await source.list(path: "albums/\(music.path.dropFirst("library/".count))")
        #expect(!albums.isEmpty)
        let tracks = try await source.collectTracks(path: "items/\(music.path.dropFirst("library/".count))")
        #expect(tracks.count >= 3)
        let track = try #require(tracks.first)
        #expect(track.duration ?? 0 > 0)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("mp9-live-jf.\(track.fileExtension)")
        try await source.download(path: track.path, to: dest)
        #expect(try AVAudioFile(forReading: dest).length > 44_100)
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func dlna() async throws {
        let config = SourceConfig(kind: .dlna, name: "rclone dlna", url: "http://\(host):17879/rootDesc.xml")
        _ = try await exercise(DLNASource(config: config))
    }
}
