import AVFoundation
import Foundation
import MonkeysAudio
import Testing
@testable import AmplayerAudio

/// 生成一段立体声 16 位 WAV，压缩成 APE，再逐帧解码比对（APE 是无损的，应完全一致）
@Test func apeRoundTripIsLossless() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amplayer-ape-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let wav = dir.appendingPathComponent("in.wav"), ape = dir.appendingPathComponent("out.ape")

    let sampleRate = 44_100.0, frames = 44_100 * 3
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let source = try #require(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!, frameCapacity: AVAudioFrameCount(frames)))
    source.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        let t = Double(i) / sampleRate
        // 量化到 16 位网格，便于精确比较
        source.floatChannelData![0][i] = Float((0.5 * sin(2 * .pi * 440 * t) * 32767).rounded() / 32768)
        source.floatChannelData![1][i] = Float((0.3 * sin(2 * .pi * 660 * t) * 32767).rounded() / 32768)
    }
    do {
        let out = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: source)
    }
    #expect(amp_ape_compress_wav_for_tests(wav.path, ape.path, 2000) == 0)
    let apeSize = try #require(try ape.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(apeSize < frames * 4, "APE 应该比原始 PCM 小")

    let stream = try APEStream(url: ape)
    #expect(stream.format.sampleRate == sampleRate)
    #expect(stream.format.channelCount == 2)
    #expect(stream.length == AVAudioFramePosition(frames))
    #expect(stream.bitsPerSample == 16)

    let decoded = try #require(AVAudioPCMBuffer(pcmFormat: stream.format, frameCapacity: 4096))
    var position = 0, maxError: Float = 0
    while true {
        let n = try stream.read(into: decoded)
        if n == 0 { break }
        for c in 0..<2 {
            for i in 0..<n {
                maxError = max(maxError, abs(decoded.floatChannelData![c][i] - source.floatChannelData![c][position + i]))
            }
        }
        position += n
    }
    #expect(position == frames)
    #expect(maxError < 1.0 / 32768 + 1e-7, "最大误差 \(maxError)")

    // 跳转到 2 秒处，第一帧应与原始数据一致
    try stream.seek(to: 88_200)
    _ = try stream.read(into: decoded)
    #expect(abs(decoded.floatChannelData![0][0] - source.floatChannelData![0][88_200]) < 1.0 / 32768 + 1e-7)

    // 标签读取：没有标签时返回 nil 而不是崩溃
    #expect(stream.tag("Title") == nil)
    let meta = MetadataReader.readAPE(url: ape)
    #expect(abs((meta.duration ?? 0) - 3) < 0.01)
}
