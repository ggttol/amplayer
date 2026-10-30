import Foundation

/// 音效：在经典 10 段均衡器之后的一串处理（音色、混响、回声、环绕、动态、变速变调、黑胶底噪）。
/// 全部用系统自带的音频单元实现。
public struct SoundEffects: Codable, Sendable, Equatable {
    public enum Reverb: String, Codable, Sendable, CaseIterable, Identifiable {
        case room, studio, hall, largeHall, cathedral, plate
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .room: String(localized: "小房间")
            case .studio: String(localized: "录音棚")
            case .hall: String(localized: "音乐厅")
            case .largeHall: String(localized: "大型场馆")
            case .cathedral: String(localized: "教堂")
            case .plate: String(localized: "板式（KTV）")
            }
        }
    }

    /// 当前选中的预设；手动改过参数后为 custom
    public var presetID: String
    /// 低音、人声（中频临场感）、高音：-12…12 dB
    public var bass: Float
    public var vocal: Float
    public var treble: Float
    /// 混响：0…100（干湿比）
    public var reverbType: Reverb
    public var reverbMix: Float
    /// 回声：0…100，延时秒数
    public var echoMix: Float
    public var echoTime: Float
    /// 环绕：声像绕头旋转的幅度 0…1 和速度（每秒转几圈）
    public var surround: Float
    public var surroundSpeed: Float
    /// 响度均衡（压缩 + 提升），夜间小声听也清楚
    public var loudness: Bool
    /// 黑胶底噪（细微的沙沙声和爆豆声）0…1
    public var vinylNoise: Float
    /// 变速（不变调）0.5…2.0；变调（不变速）-12…12 半音
    public var rate: Float
    public var pitch: Float

    public init(presetID: String = "off", bass: Float = 0, vocal: Float = 0, treble: Float = 0,
                reverbType: Reverb = .hall, reverbMix: Float = 0, echoMix: Float = 0, echoTime: Float = 0.25,
                surround: Float = 0, surroundSpeed: Float = 0.1, loudness: Bool = false, vinylNoise: Float = 0,
                rate: Float = 1, pitch: Float = 0) {
        self.presetID = presetID
        self.bass = bass
        self.vocal = vocal
        self.treble = treble
        self.reverbType = reverbType
        self.reverbMix = reverbMix
        self.echoMix = echoMix
        self.echoTime = echoTime
        self.surround = surround
        self.surroundSpeed = surroundSpeed
        self.loudness = loudness
        self.vinylNoise = vinylNoise
        self.rate = rate
        self.pitch = pitch
    }

    public static let off = SoundEffects()

    /// 有没有任何处理（全关时整条链旁路，不额外耗电）
    public var isNeutral: Bool {
        var s = self
        s.presetID = SoundEffects.off.presetID
        return s == .off
    }

    /// 只改变速、变调时保留当前音效
    public var withoutTempo: SoundEffects {
        var s = self
        s.rate = 1
        s.pitch = 0
        return s
    }
}

/// 一键音效
public struct SoundEffectPreset: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    /// SF Symbols 图标名
    public var symbol: String
    public var effects: SoundEffects

    public static let custom = "custom"

    public static let all: [SoundEffectPreset] = {
        func make(_ id: String, _ name: String, _ detail: String, _ symbol: String, _ build: (inout SoundEffects) -> Void) -> SoundEffectPreset {
            var e = SoundEffects(presetID: id)
            build(&e)
            return SoundEffectPreset(id: id, name: name, detail: detail, symbol: symbol, effects: e)
        }
        return [
            make("off", String(localized: "原声"), String(localized: "不加任何处理"), "waveform") { _ in },
            make("bass", String(localized: "超重低音"), String(localized: "下潜更深，鼓点更有力"), "speaker.wave.3.fill") { e in
                e.bass = 9; e.treble = 1; e.loudness = true
            },
            make("vocal", String(localized: "清澈人声"), String(localized: "人声靠前，齿音柔和"), "music.mic") { e in
                e.vocal = 5; e.bass = -2; e.treble = 2
            },
            make("surround3d", String(localized: "3D 环绕"), String(localized: "声场变宽，像在房间里听音箱"), "dot.radiowaves.left.and.right") { e in
                e.reverbType = .room; e.reverbMix = 14; e.echoMix = 6; e.echoTime = 0.03
                e.surround = 0.35; e.surroundSpeed = 0.05; e.bass = 2
            },
            make("orbit8d", String(localized: "8D 旋转"), String(localized: "声音绕着头转圈，戴耳机听"), "arrow.triangle.2.circlepath") { e in
                e.surround = 1; e.surroundSpeed = 0.12; e.reverbType = .room; e.reverbMix = 12
            },
            make("concert", String(localized: "演唱会"), String(localized: "大型场馆的空间感"), "music.note.house.fill") { e in
                e.reverbType = .largeHall; e.reverbMix = 32; e.bass = 3; e.vocal = 1; e.surround = 0.15; e.surroundSpeed = 0.03
            },
            make("ktv", "KTV", String(localized: "包厢里的混响和回声"), "music.quarternote.3") { e in
                e.reverbType = .plate; e.reverbMix = 26; e.echoMix = 18; e.echoTime = 0.18; e.vocal = 3
            },
            make("studio", String(localized: "录音棚"), String(localized: "紧凑、干净，适合细听"), "slider.horizontal.3") { e in
                e.reverbType = .studio; e.reverbMix = 8; e.loudness = true; e.bass = 1; e.treble = 2
            },
            make("vinyl", String(localized: "黑胶唱机"), String(localized: "温暖的中频和细微底噪"), "opticaldisc") { e in
                e.treble = -5; e.bass = 2; e.vocal = 1; e.vinylNoise = 0.6; e.reverbType = .room; e.reverbMix = 6
            },
            make("lofi", "Lo-Fi", String(localized: "复古、放松，慢一点"), "cup.and.saucer.fill") { e in
                e.treble = -8; e.bass = 3; e.vinylNoise = 0.35; e.rate = 0.92; e.pitch = -1.4; e.reverbType = .room; e.reverbMix = 10
            },
            make("edm", String(localized: "电音舞曲"), String(localized: "低音和高音都推上去，带点回声"), "bolt.fill") { e in
                e.bass = 7; e.treble = 5; e.vocal = -1; e.echoMix = 14; e.echoTime = 0.24; e.surround = 0.25; e.surroundSpeed = 0.25; e.loudness = true
            },
            make("night", String(localized: "夜间轻柔"), String(localized: "压住突然的大声，小音量也听得清"), "moon.stars.fill") { e in
                e.loudness = true; e.treble = -3; e.bass = -1; e.vocal = 2
            },
        ]
    }()

    public static func preset(_ id: String) -> SoundEffectPreset? { all.first { $0.id == id } }
}
