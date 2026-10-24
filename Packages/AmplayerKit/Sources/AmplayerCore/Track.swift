import Foundation

/// 一首曲目，可能来自本地文件、网络协议、媒体服务器或网盘。
public struct Track: Identifiable, Hashable, Sendable, Codable {
    /// 稳定标识：来源 ID + 路径
    public var id: String
    /// 所属来源（MediaSource）的标识
    public var sourceID: String
    /// 在来源内部的路径或对象 ID
    public var path: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var duration: TimeInterval?
    public var fileSize: Int64?
    /// 文件扩展名（小写，不含点），决定缓存文件名，便于解码器识别格式
    public var fileExtension: String
    /// 封面：来源内部的封面 ID 或 URL
    public var artworkRef: String?

    public init(
        sourceID: String,
        path: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        duration: TimeInterval? = nil,
        fileSize: Int64? = nil,
        fileExtension: String? = nil,
        artworkRef: String? = nil
    ) {
        self.id = Track.makeID(sourceID: sourceID, path: path)
        self.sourceID = sourceID
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.fileSize = fileSize
        self.fileExtension = (fileExtension ?? (path as NSString).pathExtension).lowercased()
        self.artworkRef = artworkRef
    }

    public static func makeID(sourceID: String, path: String) -> String {
        "\(sourceID):\(path)"
    }

    /// Winamp 风格的显示名："艺术家 - 标题"
    public var displayName: String {
        if let artist, !artist.isEmpty { return "\(artist) - \(title)" }
        return title
    }

    /// 播放列表文件里引用曲目用的 URI：amplayer://<sourceID>/<path>
    public var uri: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "amplayer://\(sourceID)\(encoded.hasPrefix("/") ? "" : "/")\(encoded)"
    }

    /// 从 amplayer:// URI 解析出来源和路径
    public static func parseURI(_ uri: String) -> (sourceID: String, path: String)? {
        guard uri.hasPrefix("amplayer://") else { return nil }
        let rest = uri.dropFirst("amplayer://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let sourceID = String(rest[..<slash])
        let rawPath = String(rest[slash...])
        return (sourceID, rawPath.removingPercentEncoding ?? rawPath)
    }

    /// 由文件名推断标题："01 - Artist - Title.mp3" → "Artist - Title"
    public static func title(fromFileName name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if let range = base.range(of: #"^\d{1,3}[\s.\-_]+"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        return base.isEmpty ? name : base
    }
}

/// 播放器能解码的文件扩展名（AVAudioFile / Core Audio 原生支持）
public enum AudioFormats {
    public static let playable: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "alac", "flac", "ape", "wav", "wave", "aif", "aiff", "aifc", "caf", "mp4", "opus", "ac3", "eac3",
    ]

    public static func isPlayable(_ fileName: String) -> Bool {
        playable.contains((fileName as NSString).pathExtension.lowercased())
    }
}

public enum TimeFormat {
    /// 123 秒 → "2:03"；超过一小时 → "1:02:03"
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
