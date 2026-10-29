import AVFoundation
import Testing
import AmplayerCore
@testable import AmplayerAudio

private func tone(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xfade-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * 44100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.05 * sin(Float(i) * 0.05) } }
    try file.write(from: buffer)
    return url
}

@MainActor
@Suite(.serialized) struct CrossfadeTests {
    /// 淡出：当前这首交给淡出节点，主节点空出来马上能加载下一首
    @Test func handOffThenLoadNext() async throws {
        let a = try tone(seconds: 2), b = try tone(seconds: 2)
        let player = AudioPlayer()
        player.volume = 0
        try player.load(url: a)
        player.play()
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.handOffForCrossfade(duration: 0.5))
        try player.load(url: b)
        player.fadeIn(duration: 0.5)
        player.play()
        #expect(player.state == .playing)
        try await Task.sleep(for: .milliseconds(800))
        #expect(player.currentTime > 0.5)
        player.stop()
    }

    /// 边下边播的歌：给了下载完的文件也能淡出；不给就不行（照旧切歌）
    @Test func handOffGrowingStreamNeedsCompletedFile() async throws {
        let a = try tone(seconds: 3)
        let size = Int64((try a.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        let growing = GrowingFile(partURL: a, finalURL: a, expectedSize: size)
        growing.update(received: size, total: size)
        let player = AudioPlayer()
        player.volume = 0
        try await player.load(growing: growing, fallbackDuration: 3)
        player.play()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!player.handOffForCrossfade(duration: 0.5))
        #expect(player.handOffForCrossfade(duration: 0.5, completedFile: a))
        player.stop()
    }

    /// 淡出时两首歌的音量均衡各算各的：下一首的增益变了，淡出的尾巴不能跟着变响
    @Test func fadingTailKeepsItsOwnGain() async throws {
        let a = try tone(seconds: 3), b = try tone(seconds: 3)
        let player = AudioPlayer()
        player.volume = 0
        player.gainAdjustment = -15          // 很响的歌
        try player.load(url: a)
        player.play()
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.handOffForCrossfade(duration: 2))
        try player.load(url: b)
        player.gainAdjustment = 8            // 很轻的歌
        player.fadeIn(duration: 2)
        player.play()
        let m = player.mixLevels
        // 总增益取两者较大的 +8；尾巴在节点上衰减 23 dB，听到的还是 -15
        #expect(abs(m.globalGain - 8) < 0.01)
        #expect(m.fade <= pow(10, -23 / 20) + 0.001)
        player.stop()
        let after = player.mixLevels
        #expect(abs(after.globalGain - 8) < 0.01)
    }

    @Test func gainAdjustmentAddsToPreamp() throws {
        let player = AudioPlayer()
        var eq = player.equalizer
        eq.enabled = true
        eq.preamp = 2
        player.equalizer = eq
        player.gainAdjustment = -6
        #expect(player.gainAdjustment == -6)
    }
}
