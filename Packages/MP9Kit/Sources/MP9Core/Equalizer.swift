import Foundation

/// 10 段均衡器设置。增益单位 dB，范围 -12...+12（与经典播放器一致）。
public struct EqualizerSettings: Codable, Sendable, Equatable {
    public static let frequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    public static let bandLabels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
    public static let range: ClosedRange<Float> = -12...12

    public var enabled: Bool
    public var preamp: Float
    public var bands: [Float]

    public init(enabled: Bool = true, preamp: Float = 0, bands: [Float] = Array(repeating: 0, count: 10)) {
        self.enabled = enabled
        self.preamp = preamp
        self.bands = bands.count == 10 ? bands : Array(repeating: 0, count: 10)
    }

    public static let flat = EqualizerSettings()

    /// 把 dB 映射到 0...1（滑块位置，1 为 +12dB）
    public static func normalized(_ db: Float) -> Float {
        (db.clamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public static func decibels(fromNormalized value: Float) -> Float {
        range.lowerBound + value.clamped(to: 0...1) * (range.upperBound - range.lowerBound)
    }
}

public struct EqualizerPreset: Identifiable, Codable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var preamp: Float
    public var bands: [Float]

    public init(name: String, preamp: Float = 0, bands: [Float]) {
        self.name = name
        self.preamp = preamp
        self.bands = bands
    }

    /// 常用预设（数值为本项目自定，单位 dB）
    public static let builtIn: [EqualizerPreset] = [
        .init(name: "Flat", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(name: "Classical", bands: [0, 0, 0, 0, 0, 0, -4.5, -4.5, -4.5, -6]),
        .init(name: "Club", bands: [0, 0, 5, 3.5, 3.5, 3.5, 2, 0, 0, 0]),
        .init(name: "Dance", bands: [6, 4.5, 1.5, 0, 0, -3.5, -4.5, -4.5, 0, 0]),
        .init(name: "Full Bass", preamp: -3, bands: [6, 6, 6, 3.5, 1, -2.5, -5, -6, -6.5, -6.5]),
        .init(name: "Full Treble", preamp: -3, bands: [-6, -6, -6, -2.5, 1.5, 6.5, 9, 9, 9, 9.5]),
        .init(name: "Bass & Treble", preamp: -2, bands: [4.5, 3.5, 0, -4.5, -3, 1, 5, 6.5, 7, 7]),
        .init(name: "Headphones", bands: [3, 6.5, 3, -2, -1.5, 1, 3, 6, 7.5, 8.5]),
        .init(name: "Large Hall", bands: [6.5, 6.5, 3.5, 3.5, 0, -3, -3, -3, 0, 0]),
        .init(name: "Live", bands: [-3, 0, 2.5, 3, 3.5, 3.5, 2.5, 1.5, 1.5, 1]),
        .init(name: "Party", bands: [4.5, 4.5, 0, 0, 0, 0, 0, 0, 4.5, 4.5]),
        .init(name: "Pop", bands: [-1, 3, 4.5, 5, 3.5, 0, -1.5, -1.5, -1, -1]),
        .init(name: "Reggae", bands: [0, 0, 0, -3.5, 0, 4, 4, 0, 0, 0]),
        .init(name: "Rock", bands: [5, 3, -3.5, -5, -2, 2.5, 5.5, 7, 7, 7]),
        .init(name: "Ska", bands: [-1.5, -3, -2.5, 0, 2.5, 3.5, 5.5, 6, 7, 6]),
        .init(name: "Soft", bands: [3, 1, 0, -1.5, 0, 2.5, 5, 6, 7, 7.5]),
        .init(name: "Soft Rock", bands: [2.5, 2.5, 1.5, 0, -2.5, -3.5, -2, 0, 1.5, 5.5]),
        .init(name: "Techno", bands: [5, 3.5, 0, -3.5, -3, 0, 5, 6, 6, 5.5]),
        .init(name: "Vocal", bands: [-2, -3, -3, 1.5, 4, 4, 3, 1.5, 0, -2]),
    ]
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
