import AVFoundation
import MP9Core

/// 从本地音频文件读取标签（标题、艺术家、专辑、音轨号、时长、封面）
public enum MetadataReader {
    public struct Result: Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var trackNumber: Int?
        public var duration: TimeInterval?
        public var artwork: Data?
    }

    public static func read(url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        var result = Result()
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            result.duration = duration.seconds
        }
        var items: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                items += (try? await asset.loadMetadata(for: format)) ?? []
            }
        }
        for item in items {
            let key = item.commonKey?.rawValue ?? (item.key as? String) ?? ""
            let identifier = item.identifier?.rawValue ?? ""
            switch key.lowercased() {
            case "title" where result.title == nil:
                result.title = try? await item.load(.stringValue)
            case "artist" where result.artist == nil:
                result.artist = try? await item.load(.stringValue)
            case "albumname" where result.album == nil, "album" where result.album == nil:
                result.album = try? await item.load(.stringValue)
            case "artwork" where result.artwork == nil:
                result.artwork = try? await item.load(.dataValue)
            default:
                break
            }
            if result.trackNumber == nil, identifier.lowercased().contains("track") {
                if let n = try? await item.load(.numberValue) {
                    result.trackNumber = n.intValue
                } else if let s = try? await item.load(.stringValue) {
                    result.trackNumber = Int(s.split(separator: "/").first ?? "")
                }
            }
        }
        return result
    }

    /// 把读到的标签合并进曲目（不覆盖来源已提供的信息）
    public static func merge(_ result: Result, into track: Track, preferFileTags: Bool) -> Track {
        var t = track
        func pick(_ current: String?, _ new: String?) -> String? {
            guard let new, !new.isEmpty else { return current }
            if preferFileTags { return new }
            return (current?.isEmpty ?? true) ? new : current
        }
        if let title = result.title, !title.isEmpty, preferFileTags || t.title.isEmpty { t.title = title }
        t.artist = pick(t.artist, result.artist)
        t.album = pick(t.album, result.album)
        t.trackNumber = t.trackNumber ?? result.trackNumber
        if let d = result.duration, d > 0 { t.duration = d }
        return t
    }
}
