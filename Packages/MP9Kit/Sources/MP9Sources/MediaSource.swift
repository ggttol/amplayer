import Foundation
import MP9Core

/// 来源中的一个条目：目录或可播放的音频文件。
public struct SourceItem: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case directory, audio }

    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: Kind
    public var size: Int64?

    public init(path: String, name: String, kind: Kind, size: Int64? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
    }
}

/// 所有来源（本地、WebDAV、SMB、Subsonic、Jellyfin、群晖、DLNA、网盘）的统一接口。
public protocol MediaSource: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// 列出某个目录下的条目
    func list(path: String) async throws -> [SourceItem]

    /// 读取文件的一段字节，供边下边播缓存使用
    func read(path: String, range: Range<Int64>) async throws -> Data
}
