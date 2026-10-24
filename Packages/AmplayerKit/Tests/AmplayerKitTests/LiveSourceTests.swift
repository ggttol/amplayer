import AVFoundation
import Foundation
import Testing
@testable import AmplayerAudio
@testable import AmplayerCore
@testable import AmplayerSources

/// 针对真实服务器的端到端测试，默认跳过。启动 Tools/test-servers.sh 里的容器后用 AMP_LIVE=1 swift test 运行。
private let live = ProcessInfo.processInfo.environment["AMP_LIVE"] == "1"
private let host = ProcessInfo.processInfo.environment["AMP_LIVE_HOST"] ?? "127.0.0.1"

/// 列根目录 → 递归收集曲目 → 下载第一首 → 用 AVAudioFile 解码验证
private func exercise(_ source: any MediaSource, expectAtLeast count: Int = 3) async throws -> [Track] {
    try await source.testConnection()
    let root = try await source.list(path: source.rootPath)
    #expect(!root.isEmpty, "\(source.config.kind) 根目录为空")
    let tracks = try await source.collectTracks(path: source.rootPath)
    #expect(tracks.count >= count, "\(source.config.kind) 只找到 \(tracks.count) 首")
    let track = try #require(tracks.first)
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("amplayer-live-\(UUID().uuidString)")
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
        let config = SourceConfig(kind: .webdav, name: "rclone", url: "http://\(host):18080/", username: "amplayer")
        let tracks = try await exercise(WebDAVSource(config: config, password: "amplayerpass"))
        #expect(tracks.contains { $0.title.contains("中文标题") })
    }

    @Test func webDAVWrongPassword() async throws {
        let config = SourceConfig(kind: .webdav, name: "rclone", url: "http://\(host):18080/", username: "amplayer")
        await #expect(throws: SourceError.self) { try await WebDAVSource(config: config, password: "bad").list(path: "/") }
    }

    @Test func smb() async throws {
        let config = SourceConfig(kind: .smb, name: "samba", url: "smb://\(host)", username: "amplayer")
        let source = SMBSource(config: config, password: "amplayerpass")
        let shares = try await source.list(path: "/")
        #expect(shares.contains { $0.name == "Music" })
        _ = try await exercise(SMBSource(config: SourceConfig(kind: .smb, name: "samba", url: "smb://\(host)/Music", username: "amplayer"), password: "amplayerpass"))
    }

    @Test func subsonic() async throws {
        let config = SourceConfig(kind: .subsonic, name: "navidrome", url: "http://\(host):14533", username: "amplayer")
        let source = SubsonicSource(config: config, password: "amplayerpass")
        let artists = try await source.list(path: "artists")
        #expect(!artists.isEmpty)
        let random = try await source.list(path: "random")
        #expect(random.count >= 3)
        let song = try #require(random.first)
        #expect(song.duration ?? 0 > 0)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("amplayer-live-sub.\(song.fileExtension ?? "mp3")")
        try await source.download(path: song.path, to: dest)
        #expect(try AVAudioFile(forReading: dest).length > 44_100)
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func jellyfin() async throws {
        let config = SourceConfig(kind: .jellyfin, name: "jellyfin", url: "http://\(host):18096", username: "amplayer")
        let source = JellyfinSource(config: config, password: "amplayerpass")
        let libraries = try await source.list(path: "/")
        let music = try #require(libraries.first { $0.path.hasPrefix("library/") })
        let albums = try await source.list(path: "albums/\(music.path.dropFirst("library/".count))")
        #expect(!albums.isEmpty)
        let tracks = try await source.collectTracks(path: "items/\(music.path.dropFirst("library/".count))")
        #expect(tracks.count >= 3)
        let track = try #require(tracks.first)
        #expect(track.duration ?? 0 > 0)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("amplayer-live-jf.\(track.fileExtension)")
        try await source.download(path: track.path, to: dest)
        #expect(try AVAudioFile(forReading: dest).length > 44_100)
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func dlna() async throws {
        let config = SourceConfig(kind: .dlna, name: "rclone dlna", url: "http://\(host):17879/rootDesc.xml")
        _ = try await exercise(DLNASource(config: config))
    }
}

/// 真实群晖 NAS：AMP_SYNO_URL、AMP_SYNO_USER、AMP_SYNO_PASS，可选 AMP_SYNO_QC（QuickConnect ID）
/// 凭据只从环境变量读取，不要写进代码。
private let env = ProcessInfo.processInfo.environment
private let synoEnabled = env["AMP_SYNO_URL"] != nil && env["AMP_SYNO_PASS"] != nil

@Suite(.enabled(if: synoEnabled), .serialized)
struct LiveSynologyTests {
    private func source(url: String) -> SynologySource {
        SynologySource(config: SourceConfig(kind: .synology, name: "NAS", url: url, username: env["AMP_SYNO_USER"] ?? ""), password: env["AMP_SYNO_PASS"])
    }

    /// 在共享文件夹里找第一首较小的可播放曲目
    private func firstPlayable(_ s: SynologySource) async throws -> SourceItem {
        var queue = try await s.list(path: "/").filter { $0.path.hasPrefix("fs:") }
        var visited = 0
        while !queue.isEmpty, visited < 40 {
            let dir = queue.removeFirst()
            visited += 1
            let items = try await s.list(path: dir.path).sortedForBrowsing()
            if let song = items.first(where: { $0.kind == .audio && ($0.size ?? 0) < 15_000_000 && ["mp3", "m4a", "flac"].contains(($0.name as NSString).pathExtension.lowercased()) }) {
                return song
            }
            queue += items.filter { $0.kind == .directory }
        }
        throw SourceError.protocolError("没找到可播放曲目")
    }

    private func downloadAndDecode(_ s: SynologySource, _ song: SourceItem) async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("amplayer-syno-\(UUID().uuidString).\((song.name as NSString).pathExtension)")
        defer { try? FileManager.default.removeItem(at: dest) }
        try await s.download(path: song.path, to: dest)
        let file = try AVAudioFile(forReading: dest)
        #expect(file.length > 44_100 * 10, "\(song.name) 太短")
    }

    @Test func directURL() async throws {
        let s = source(url: env["AMP_SYNO_URL"]!)
        try await s.testConnection()
        let root = try await s.list(path: "/")
        print("SYNO root:", root.map(\.name))
        #expect(root.contains { $0.path.hasPrefix("fs:") })
        let song = try await firstPlayable(s)
        print("SYNO song:", song.path, song.size ?? 0)
        try await downloadAndDecode(s, song)
    }

    @Test(.enabled(if: env["AMP_SYNO_QC"] != nil)) func quickConnect() async throws {
        let id = env["AMP_SYNO_QC"]!
        let resolved = try await QuickConnectResolver.shared.resolve(id)
        print("QuickConnect \(id) →", resolved)
        let s = source(url: id)
        try await s.testConnection()
        #expect(try await s.connectedAddress() == resolved)
        let song = try await firstPlayable(s)
        try await downloadAndDecode(s, song)
    }
}

/// 用 NAS 上真实的 APE 验证解码：AMP_SYNO_APE 指定 File Station 路径
@Test(.enabled(if: synoEnabled && env["AMP_SYNO_APE"] != nil))
func liveSynologyAPE() async throws {
    let s = SynologySource(config: SourceConfig(kind: .synology, name: "NAS", url: env["AMP_SYNO_URL"]!, username: env["AMP_SYNO_USER"] ?? ""), password: env["AMP_SYNO_PASS"])
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("amplayer-live-\(UUID().uuidString).ape")
    defer { try? FileManager.default.removeItem(at: dest) }
    try await s.download(path: "fs:" + env["AMP_SYNO_APE"]!, to: dest)
    let stream = try APEStream(url: dest)
    let seconds = Double(stream.length) / stream.format.sampleRate
    let meta = MetadataReader.readAPE(url: dest)
    print("APE:", stream.format, "时长", seconds, "位深", stream.bitsPerSample, "标签", meta.title ?? "-", meta.artist ?? "-", meta.album ?? "-")
    #expect(seconds > 60)
    // 解码整首并测时间，确认手机上实时解码绰绰有余
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stream.format, frameCapacity: 16384))
    let start = Date()
    var total = 0, peak: Float = 0
    while true {
        let n = try stream.read(into: buffer)
        if n == 0 { break }
        total += n
        for i in stride(from: 0, to: n, by: 64) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
    }
    let elapsed = Date().timeIntervalSince(start)
    print("解码 \(total) 帧用时 \(String(format: "%.2f", elapsed))s，实时倍数 \(String(format: "%.0f", seconds / elapsed))x，峰值 \(peak)")
    #expect(total == Int(stream.length))
    #expect(peak > 0.05, "解码结果几乎是静音")
}
