import AVFoundation
import Testing
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
