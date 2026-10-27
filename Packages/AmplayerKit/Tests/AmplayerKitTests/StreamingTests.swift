import AVFoundation
import Foundation
import Testing
@testable import AmplayerAudio
@testable import AmplayerCache
@testable import AmplayerCore
@testable import AmplayerSources

/// 写一段 FLAC（或 WAV），返回路径和帧数
private func makeAudio(ext: String, seconds: Double = 3) throws -> (URL, AVAudioFramePosition) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-src-\(UUID().uuidString).\(ext)")
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    var settings: [String: Any] = [AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2]
    switch ext {
    case "flac": settings[AVFormatIDKey] = kAudioFormatFLAC; settings[AVLinearPCMBitDepthKey] = 16
    default: settings = pcm.settings
    }
    let frames = AVAudioFrameCount(44100 * seconds)
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float.random(in: -0.3...0.3) } }
        try file.write(from: buffer)
    }
    return (url, AVAudioFramePosition(frames))
}

/// 模拟下载：后台把 source 一块块拷到 part，并更新 GrowingFile
private func simulateDownload(from source: URL, to file: GrowingFile, chunk: Int = 16 * 1024, delay: TimeInterval = 0.005, startAfter: Int = 0) -> Thread {
    let data = try! Data(contentsOf: source)
    FileManager.default.createFile(atPath: file.partURL.path, contents: nil)
    let thread = Thread {
        let handle = try! FileHandle(forWritingTo: file.partURL)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunk)
            try! handle.write(contentsOf: data[offset..<end])
            offset = end
            file.update(received: Int64(offset), total: Int64(data.count))
            if offset >= startAfter { Thread.sleep(forTimeInterval: delay) }
        }
        try! handle.close()
        try? FileManager.default.moveItem(at: file.partURL, to: file.finalURL)
        file.finish()
    }
    return thread
}

private func growingFile(ext: String, size: Int64) -> GrowingFile {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("stream-dst-\(UUID().uuidString).\(ext)")
    return GrowingFile(partURL: base.appendingPathExtension("part"), finalURL: base, expectedSize: size)
}

@Suite(.serialized) struct StreamingTests {
    @Test(arguments: ["flac", "wav"])
    func decodesWhileDownloading(ext: String) async throws {
        let (src, frames) = try makeAudio(ext: ext)
        let size = try Int64(Data(contentsOf: src).count)
        let file = growingFile(ext: ext, size: size)
        let thread = simulateDownload(from: src, to: file)
        thread.start()
        try await file.waitAsync(forFirst: 64 * 1024)
        #expect(!file.isFinished)
        let stream = try await GrowingFileStream.open(file, fallbackDuration: nil)
        #expect(stream.format.sampleRate == 44100)
        #expect(abs(stream.length - frames) < 4410)
        // 在后台读完整首：读到还没下载的地方会等
        let total = try await Task.detached {
            var sum = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: stream.format, frameCapacity: 8192)!
            while true {
                let n = try stream.read(into: buffer)
                if n == 0 { break }
                sum += n
            }
            return sum
        }.value
        #expect(AVAudioFramePosition(total) == frames)
        #expect(file.receivedBytes == size)
    }

    @Test func interruptWakesBlockedRead() async throws {
        let (src, _) = try makeAudio(ext: "flac", seconds: 5)
        let data = try Data(contentsOf: src)
        let file = growingFile(ext: "flac", size: Int64(data.count))
        // 只给开头 64 KB，后面一直不来
        try data.prefix(64 * 1024).write(to: file.partURL)
        file.update(received: 64 * 1024, total: Int64(data.count))
        let stream = try await GrowingFileStream.open(file, fallbackDuration: nil)
        let started = Date()
        let reader = Task.detached { () -> Bool in
            let buffer = AVAudioPCMBuffer(pcmFormat: stream.format, frameCapacity: 8192)!
            do {
                while try stream.read(into: buffer) > 0 {}
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        stream.interrupt()
        let finishedNormally = await reader.value
        #expect(!finishedNormally)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func playerStartsBeforeDownloadFinishes() async throws {
        let (src, _) = try makeAudio(ext: "flac", seconds: 4)
        let size = try Int64(Data(contentsOf: src).count)
        let file = growingFile(ext: "flac", size: size)
        let thread = simulateDownload(from: src, to: file, delay: 0.02, startAfter: 64 * 1024)
        thread.start()
        try await file.waitAsync(forFirst: 64 * 1024)
        let player = await AudioPlayer()
        await MainActor.run { player.volume = 0 }
        try await player.load(growing: file, fallbackDuration: nil)
        await MainActor.run { player.play() }
        #expect(!file.isFinished)
        try await Task.sleep(for: .milliseconds(600))
        let time = await MainActor.run { player.currentTime }
        #expect(time > 0.2)
        // 跳到后面（还没下载到）：不能卡住主线程
        let before = Date()
        await MainActor.run { player.seek(to: 3.5) }
        #expect(Date().timeIntervalSince(before) < 0.5)
        await MainActor.run { player.stop() }
    }
}

/// 慢慢写 .part 的假来源，测 AudioCache.playable 不等下载完
private final class SlowSource: MediaSource, @unchecked Sendable {
    let config = SourceConfig(id: "slow", kind: .webdav, name: "Slow")
    let payload: Data
    var rootPath: String { "/" }
    init(payload: Data) { self.payload = payload }
    func list(path: String) async throws -> [SourceItem] { [] }

    func download(path: String, to destination: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        fm.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        var offset = 0
        while offset < payload.count {
            let end = min(payload.count, offset + 64 * 1024)
            try handle.write(contentsOf: payload[offset..<end])
            offset = end
            DownloadProgress.report?(Int64(offset), Int64(payload.count))
            try await Task.sleep(for: .milliseconds(30))
        }
        try handle.close()
        try fm.moveItem(at: part, to: destination)
    }
}

@Test func cacheHandsOutGrowingFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-cache-\(UUID().uuidString)")
    let cache = AudioCache(cacheDirectory: root.appendingPathComponent("c"), offlineDirectory: root.appendingPathComponent("o"))
    let source = SlowSource(payload: Data(repeating: 1, count: 2 * 1024 * 1024))
    let track = Track(sourceID: "slow", path: "/a.flac", title: "a")
    let playable = try await cache.playable(for: track, source: source)
    guard case .growing(let file) = playable else {
        Issue.record("应该边下边播")
        return
    }
    #expect(!file.isFinished)
    #expect(file.receivedBytes >= AudioCache.streamHead)
    // 同一首再要：接上同一个下载
    let url = try await cache.localURL(for: track, source: source)
    #expect(file.isFinished)
    #expect(try Data(contentsOf: url).count == 2 * 1024 * 1024)
    // 下完以后直接给完整文件
    if case .complete = try await cache.playable(for: track, source: source) {} else { Issue.record("应该是完整文件") }
}

/// FLAC 头里总采样数写 0（转码工具常见）：AVAudioFile 认为 0 帧，要改用逐块解码，不能静悄悄不出声
@MainActor
@Test func playsFlacWithUnknownLength() async throws {
    let (src, frames) = try makeAudio(ext: "flac", seconds: 2)
    var data = try Data(contentsOf: src)
    // STREAMINFO 从第 8 字节开始；总采样数是它第 13 字节低 4 位 + 第 14～17 字节
    data[8 + 13] &= 0xF0
    for i in 14...17 { data[8 + i] = 0 }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nolen-\(UUID().uuidString).ape")
    try data.write(to: url)
    #expect(try AVAudioFile(forReading: url).length == 0)
    let player = AudioPlayer()
    player.volume = 0
    try player.load(url: url)
    let duration = try #require(player.info?.duration)
    #expect(abs(duration - Double(frames) / 44100) < 0.2)
    player.play()
    try await Task.sleep(for: .milliseconds(600))
    #expect(player.currentTime > 0.2)
    player.stop()
}

/// 换歌时取消别的下载，被取消的那首之后还能重新下
@Test func cancelsAbandonedDownloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-cancel-\(UUID().uuidString)")
    let cache = AudioCache(cacheDirectory: root.appendingPathComponent("c"), offlineDirectory: root.appendingPathComponent("o"))
    let source = SlowSource(payload: Data(repeating: 2, count: 4 * 1024 * 1024))
    let a = Track(sourceID: "slow", path: "/a.flac", title: "a"), b = Track(sourceID: "slow", path: "/b.flac", title: "b")
    guard case .growing(let fa) = try await cache.playable(for: a, source: source) else { Issue.record("a 应该边下边播"); return }
    await cache.cancelDownloads(except: [b.id])
    #expect(fa.error != nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await cache.cachedURL(for: a) == nil)
    // 再点 a：重新下载，能下完
    let url = try await cache.localURL(for: a, source: source)
    #expect(try Data(contentsOf: url).count == 4 * 1024 * 1024)
}
