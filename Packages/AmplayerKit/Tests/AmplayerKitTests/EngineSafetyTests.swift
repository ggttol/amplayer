import AVFoundation
import Foundation
import Testing
@testable import AmplayerAudio
import AmplayerObjC

@MainActor
@Suite struct EngineSafetyTests {
    /// AVAudioEngine 抛的是 Objective-C 异常，要能接住而不是闪退
    @Test func catchesObjectiveCException() {
        let reason = AMPCatchException {
            NSException(name: .internalInconsistencyException, reason: "required condition is false", userInfo: nil).raise()
        }
        #expect(reason == "NSInternalInconsistencyException: required condition is false")
        #expect(AMPCatchException {} == nil)
    }

    /// 服务器上有把 FLAC 存成 .ape 的：按文件头认，不按扩展名
    @Test func loadsFlacNamedApe() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).ape")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 22050)!
            buffer.frameLength = 22050
            try file.write(from: buffer)
        }
        #expect(!AudioPlayer.isMonkeysAudio(url))
        let player = AudioPlayer()
        try player.load(url: url)
        #expect(player.info != nil)
    }

    @Test func detectsMonkeysAudioHeader() throws {
        let dir = FileManager.default.temporaryDirectory
        let plain = dir.appendingPathComponent("mac-\(UUID().uuidString).flac")
        try Data("MAC \u{0}\u{0}".utf8).write(to: plain)
        #expect(AudioPlayer.isMonkeysAudio(plain))
        // 前面带 20 字节的 ID3v2 标签
        let tagged = dir.appendingPathComponent("id3-\(UUID().uuidString).ape")
        var data = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 10]) + Data(count: 10)
        data += Data("MAC ".utf8)
        try data.write(to: tagged)
        #expect(AudioPlayer.isMonkeysAudio(tagged))
    }
}
