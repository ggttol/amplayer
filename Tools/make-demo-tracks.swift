// 生成内置示例曲（原创，代码合成的芯片音乐风格）：swift Tools/make-demo-tracks.swift App/Resources/Demo
// 输出 WAV，之后用 afconvert 转成 AAC（.m4a）。
import AVFoundation
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rate = 44100.0

struct Song {
    var name: String
    var bpm: Double
    /// 和弦根音（MIDI 音高），每个和弦一小节
    var chords: [Int]
    /// 每小节 8 个八分音符的旋律（相对和弦根音的半音，nil 为休止）
    var melody: [[Int?]]
    var bars: Int
    var lead: (Double) -> Double
}

func freq(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
func square(_ phase: Double, duty: Double = 0.5) -> Double { phase.truncatingRemainder(dividingBy: 1) < duty ? 1 : -1 }
func triangle(_ phase: Double) -> Double { let p = phase.truncatingRemainder(dividingBy: 1); return 4 * abs(p - 0.5) - 1 }

func render(_ song: Song) throws {
    let beat = 60 / song.bpm, bar = beat * 4, eighth = beat / 2
    let seconds = bar * Double(song.bars) + 1.5
    let frames = Int(seconds * rate)
    var left = [Float](repeating: 0, count: frames), right = left
    var noise: UInt32 = 0x1234_5678
    func rnd() -> Double { noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5; return Double(noise) / Double(UInt32.max) * 2 - 1 }

    for i in 0..<frames {
        let t = Double(i) / rate
        let barIndex = Int(t / bar)
        guard barIndex < song.bars else {
            // 结尾淡出的长音
            continue
        }
        let root = song.chords[barIndex % song.chords.count]
        let inBar = t - Double(barIndex) * bar
        let fadeIn = min(1, t / 1.0), fadeOut = min(1, (bar * Double(song.bars) - t) / 2.0)
        let master = fadeIn * max(0, fadeOut)

        // 低音：三角波，八分音符根音/五度交替
        let step = Int(inBar / eighth)
        let bassNote = root - 24 + (step % 2 == 0 ? 0 : 7)
        let stepT = inBar - Double(step) * eighth
        let bass = triangle(freq(bassNote) * t) * exp(-stepT * 6) * 0.32

        // 琶音：方波快速分解和弦（十六分音符的一半）
        let arpStep = Int(inBar / (eighth / 2))
        let arpNote = root + [0, 4, 7, 12][arpStep % 4] + (song.chords[barIndex % song.chords.count] % 2 == 0 ? 0 : 0)
        let arpT = inBar - Double(arpStep) * eighth / 2
        let arp = square(freq(arpNote) * t, duty: 0.25) * exp(-arpT * 18) * 0.07

        // 旋律
        var leadSample = 0.0
        let phrase = song.melody[barIndex % song.melody.count]
        if let interval = phrase[step % 8] {
            let note = root + 12 + interval
            let env = min(1, stepT * 60) * exp(-stepT * 3)
            let vibrato = sin(t * 2 * .pi * 5.5) * 0.004 * min(1, stepT * 4)
            leadSample = song.lead(freq(note) * (1 + vibrato) * t) * env * 0.14
        }

        // 鼓：底鼓（下滑正弦）、军鼓（噪声）、踩镲（短噪声）
        let beatIndex = Int(inBar / beat)
        let beatT = inBar - Double(beatIndex) * beat
        var drums = 0.0
        if beatIndex % 2 == 0 { drums += sin(2 * .pi * (55 + 90 * exp(-beatT * 30)) * beatT) * exp(-beatT * 9) * 0.45 }
        if beatIndex % 2 == 1 { drums += rnd() * exp(-beatT * 18) * 0.16 }
        let hatT = inBar - Double(step) * eighth
        drums += rnd() * exp(-hatT * 90) * 0.05

        let mono = (bass + drums) * master
        left[i] = Float(mono + (leadSample * 0.9 + arp * 0.6) * master)
        right[i] = Float(mono + (leadSample * 0.7 + arp * 1.0) * master)
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        buffer.floatChannelData![0][i] = max(-1, min(1, left[i]))
        buffer.floatChannelData![1][i] = max(-1, min(1, right[i]))
    }
    let url = outDir.appendingPathComponent("\(song.name).wav")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    print("wrote \(url.lastPathComponent) (\(String(format: "%.1f", seconds))s)")
}

// 第一首：明亮的 C 大调，I–V–vi–IV
try render(Song(
    name: "Amplayer - Pixel Sunrise", bpm: 124,
    chords: [60, 67, 69, 65],
    melody: [
        [0, nil, 4, 7, 9, 7, 4, nil],
        [2, nil, 4, 2, 0, nil, -3, nil],
        [0, 4, 7, 12, 11, 7, 4, 2],
        [0, nil, 0, 2, 4, nil, nil, nil],
    ],
    bars: 16,
    lead: { square($0, duty: 0.5) }
))

// 第二首：夜色感的 A 小调，i–VI–III–VII
try render(Song(
    name: "Amplayer - Night Drive", bpm: 104,
    chords: [57, 53, 60, 55],
    melody: [
        [0, nil, 3, nil, 7, 5, 3, nil],
        [7, nil, 5, 3, 0, nil, nil, nil],
        [3, 5, 7, 10, 7, nil, 5, 3],
        [2, nil, 3, 2, -2, nil, nil, nil],
    ],
    bars: 16,
    lead: { triangle($0) * 0.8 + square($0, duty: 0.125) * 0.35 }
))
