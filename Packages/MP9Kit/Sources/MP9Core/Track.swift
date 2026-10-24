import Foundation

/// 一首曲目，可能来自本地文件、网络协议、媒体服务器或网盘。
public struct Track: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    /// 所属来源（MediaSource）的标识
    public var sourceID: String
    /// 在来源内部的路径或对象 ID
    public var path: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?

    public init(
        id: String,
        sourceID: String,
        path: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// Winamp 风格的显示名："艺术家 - 标题"
    public var displayName: String {
        if let artist, !artist.isEmpty { return "\(artist) - \(title)" }
        return title
    }
}
