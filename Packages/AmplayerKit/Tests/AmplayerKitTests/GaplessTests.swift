import AVFoundation
import Testing
@testable import AmplayerAudio

/// 生成一段正弦波 WAV
private func makeTone(_ name: String, seconds: Double, rate: Double = 44100, channels: AVAudioChannelCount = 2) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gapless-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.05 * sin(Float(i) * 0.05) }
    }
    try file.write(from: buffer)
    return url
}

@MainActor
@Suite(.serialized) struct GaplessTests {
    @Test func queuedNextPlaysWithoutStopping() async throws {
        let a = try makeTone("a", seconds: 0.6), b = try makeTone("b", seconds: 0.6)
        let player = AudioPlayer()
        player.volume = 0
        var events: [String] = []
        var timeAfterAdvance: TimeInterval = -1
        player.onAdvancedToNext = { url in
            events.append("advanced:\(url == b)")
            timeAfterAdvance = player.currentTime
        }
        player.onFinished = { events.append("finished") }
        try player.load(url: a)
        player.play()
        #expect(player.enqueueNext(url: b))
        #expect(player.hasQueuedNext)
        // 已经排了一首，不能再排
        #expect(!player.enqueueNext(url: b))
        for _ in 0..<40 where events.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(events == ["advanced:true", "finished"])
        // 衔接后时间从第二首的开头算，不是接着第一首累加
        #expect(timeAfterAdvance >= 0 && timeAfterAdvance < 0.3)
    }

    @Test func seekCancelsQueuedNext() throws {
        let a = try makeTone("a", seconds: 2), b = try makeTone("b", seconds: 2)
        let player = AudioPlayer()
        player.volume = 0
        try player.load(url: a)
        player.play()
        #expect(player.enqueueNext(url: b))
        player.seek(to: 1)
        #expect(!player.hasQueuedNext)
        player.stop()
    }

    @Test func differentFormatFallsBack() throws {
        let a = try makeTone("a", seconds: 1), b = try makeTone("b", seconds: 1, rate: 48000)
        let player = AudioPlayer()
        try player.load(url: a)
        #expect(!player.enqueueNext(url: b))
    }
}
