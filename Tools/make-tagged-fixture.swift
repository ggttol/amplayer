// 生成带标签的测试曲目（界面测试用）：swift Tools/make-tagged-fixture.swift 输入.m4a 输出.m4a
import AVFoundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: output)

func item(_ key: AVMetadataKey, _ value: String) -> AVMetadataItem {
    let m = AVMutableMetadataItem()
    m.keySpace = .common
    m.key = key as NSString
    m.value = value as NSString
    return m
}

let asset = AVURLAsset(url: input)
let sem = DispatchSemaphore(value: 0)
Task {
    let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)!
    export.metadata = [item(.commonKeyTitle, "带标签的歌"), item(.commonKeyArtist, "测试艺术家"), item(.commonKeyAlbumName, "测试专辑")]
    do {
        try await export.export(to: output, as: .m4a)
        print("wrote \(output.lastPathComponent)")
    } catch {
        print("failed: \(error)")
    }
    sem.signal()
}
sem.wait()
