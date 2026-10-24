import AVFoundation
import Testing
@testable import AmplayerAudio
@testable import AmplayerCore

/// 用离线渲染测量音效链：同一段测试音，比较处理前后的音量
@MainActor
@Suite(.serialized) struct EffectsChainTests {
    let rate = 44100.0

    private func tone(_ freq: Double, seconds: Double, amplitude: Float = 0.3) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { b.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * freq * Double(i) / rate)) } }
        return b
    }

    /// 渲染 input（之后再渲染 tail 秒静音），返回左右声道 RMS（只算 from 秒之后的部分）
    private func render(_ input: AVAudioPCMBuffer, effects: SoundEffects, pan: Float = 0, tail: Double = 0, from: Double = 0.2) throws -> (left: Float, right: Float, tailRMS: Float) {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        engine.attach(player)
        engine.attach(eq)
        let chain = EffectsChain()
        chain.attach(to: engine)
        chain.connect(player: player, equalizer: eq, fileFormat: format, in: engine)
        chain.apply(effects)
        player.pan = pan
        try engine.start()
        player.scheduleBuffer(input, at: nil)
        player.play()
        let total = AVAudioFrameCount(Double(input.frameLength) + tail * rate)
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: total)!
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while out.frameLength < total {
            let n = min(4096, total - out.frameLength)
            _ = try engine.renderOffline(n, to: chunk)
            for c in 0..<2 {
                memcpy(out.floatChannelData![c] + Int(out.frameLength), chunk.floatChannelData![c], Int(chunk.frameLength) * 4)
            }
            out.frameLength += chunk.frameLength
        }
        engine.stop()
        func rms(_ c: Int, _ a: Int, _ b: Int) -> Float {
            guard b > a else { return 0 }
            var s: Float = 0
            for i in a..<b { s += out.floatChannelData![c][i] * out.floatChannelData![c][i] }
            return (s / Float(b - a)).squareRoot()
        }
        let start = Int(from * rate), end = Int(input.frameLength)
        let tailStart = end + Int(0.05 * rate)
        return (rms(0, start, end), rms(1, start, end), rms(0, min(tailStart, Int(total)), Int(total)))
    }

    @Test func neutralChainIsTransparent() throws {
        let input = tone(440, seconds: 1)
        let r = try render(input, effects: .off)
        let expected = Float(0.3 / 2.0.squareRoot())
        #expect(abs(r.left - expected) / expected < 0.08, "原声 RMS \(r.left)，期望约 \(expected)")
    }

    @Test func bassBoostRaisesLowTone() throws {
        let input = tone(60, seconds: 1, amplitude: 0.1)
        let flat = try render(input, effects: .off)
        var e = SoundEffects.off; e.bass = 12
        let boosted = try render(input, effects: e)
        #expect(boosted.left > flat.left * 2, "低音 +12dB：\(flat.left) → \(boosted.left)")
    }

    @Test func trebleCutLowersHighTone() throws {
        let input = tone(10000, seconds: 1)
        let flat = try render(input, effects: .off)
        var e = SoundEffects.off; e.treble = -12
        let cut = try render(input, effects: e)
        #expect(cut.left < flat.left * 0.5, "高音 -12dB：\(flat.left) → \(cut.left)")
    }

    @Test func balanceActuallyPans() throws {
        let input = tone(440, seconds: 1)
        let r = try render(input, effects: .off, pan: 1)
        #expect(r.left < r.right * 0.1, "平衡推到最右：左 \(r.left) 右 \(r.right)")
    }

    @Test func reverbLeavesATail() throws {
        let input = tone(440, seconds: 0.5)
        let dry = try render(input, effects: .off, tail: 0.6)
        var e = SoundEffects.off; e.reverbType = .largeHall; e.reverbMix = 50
        let wet = try render(input, effects: e, tail: 0.6)
        #expect(dry.tailRMS < 0.001)
        #expect(wet.tailRMS > 0.005, "混响余音 \(wet.tailRMS)")
    }

    @Test func vinylNoiseOnlyWhenEnabled() throws {
        let silence = tone(440, seconds: 1, amplitude: 0)
        let quiet = try render(silence, effects: .off)
        var e = SoundEffects.off; e.vinylNoise = 1
        let noisy = try render(silence, effects: e)
        #expect(quiet.left < 0.0001)
        #expect(noisy.left > 0.001, "黑胶底噪 \(noisy.left)")
    }

    @Test func presetsAreDistinctAndOffIsNeutral() {
        let all = SoundEffectPreset.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.first?.effects.isNeutral == true)
        #expect(all.dropFirst().allSatisfy { !$0.effects.isNeutral })
    }
}
