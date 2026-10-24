import Foundation
import AmplayerCore

/// 来源中的一个条目：目录或可播放的音频文件。
public struct SourceItem: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case directory, audio }

    public var id: String { path }
    /// 在来源内部的路径或对象 ID（目录可再次传给 list）
    public var path: String
    public var name: String
    public var kind: Kind
    public var size: Int64?
    /// 媒体服务器类来源直接提供的曲目信息
    public var title: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var duration: TimeInterval?
    public var fileExtension: String?
    public var artworkRef: String?

    public init(
        path: String, name: String, kind: Kind, size: Int64? = nil,
        title: String? = nil, artist: String? = nil, album: String? = nil,
        trackNumber: Int? = nil, duration: TimeInterval? = nil,
        fileExtension: String? = nil, artworkRef: String? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.fileExtension = fileExtension
        self.artworkRef = artworkRef
    }

    public func makeTrack(sourceID: String) -> Track {
        Track(
            sourceID: sourceID,
            path: path,
            title: title ?? Track.title(fromFileName: name),
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            duration: duration,
            fileSize: size,
            fileExtension: fileExtension ?? (name as NSString).pathExtension,
            artworkRef: artworkRef
        )
    }
}

public enum SourceError: LocalizedError, Sendable {
    case invalidURL(String)
    case http(Int, String?)
    case authenticationFailed(String?)
    case notConfigured(String)
    case unsupported(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): "地址无效：\(s)"
        case .http(let code, let detail): "服务器返回 HTTP \(code)" + (detail.map { "：\($0)" } ?? "")
        case .authenticationFailed(let detail): "登录失败" + (detail.map { "：\($0)" } ?? "")
        case .notConfigured(let s): s
        case .unsupported(let s): "暂不支持：\(s)"
        case .protocolError(let s): "协议错误：\(s)"
        }
    }
}

/// 所有来源（本地、WebDAV、SMB、Subsonic、Jellyfin/Emby、群晖、DLNA、网盘）的统一接口。
public protocol MediaSource: Sendable {
    var config: SourceConfig { get }

    /// 浏览起点
    var rootPath: String { get }

    /// 列出某个目录下的条目；根目录用 rootPath
    func list(path: String) async throws -> [SourceItem]

    /// 把音频文件完整下载到本地路径
    func download(path: String, to destination: URL) async throws

    /// 文件本身就在本机时返回其 URL（本地来源无需缓存）
    func localURL(path: String) -> URL?

    /// 封面图请求
    func artworkRequest(ref: String) async throws -> URLRequest?

    /// 测试连接与登录
    func testConnection() async throws
}

extension MediaSource {
    public var id: String { config.id }
    public var displayName: String { config.name }
    public var rootPath: String { "/" }
    public func localURL(path: String) -> URL? { nil }
    public func artworkRequest(ref: String) async throws -> URLRequest? { nil }
    public func testConnection() async throws { _ = try await list(path: "/") }

    /// 递归列出目录下所有可播放曲目（用于“添加整个文件夹”和建库）
    public func collectTracks(path: String, maxDepth: Int = 8, limit: Int = 5000) async throws -> [Track] {
        var result: [Track] = []
        var seenTracks = Set<String>()
        var visited = Set<String>()
        var stack: [(String, Int)] = [(path, 0)]
        while let (current, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard visited.insert(current).inserted else { continue }
            let items = try await list(path: current).sortedForBrowsing()
            let dirs = items.filter { $0.kind == .directory }
            let audio = items.filter { $0.kind == .audio }
            // 媒体服务器的虚拟目录（艺术家/专辑/随机）会重复出现同一首，按 ID 去重
            for item in audio where seenTracks.insert(item.path).inserted {
                result.append(item.makeTrack(sourceID: config.id))
            }
            if result.count >= limit { break }
            if depth < maxDepth {
                for d in dirs.reversed() { stack.append((d.path, depth + 1)) }
            }
        }
        return result
    }
}

extension Array where Element == SourceItem {
    /// 目录在前、按名称自然排序；只保留可播放的音频
    public func sortedForBrowsing() -> [SourceItem] {
        filter { $0.kind == .directory || AudioFormats.playable.contains(($0.fileExtension ?? ($0.name as NSString).pathExtension).lowercased()) }
            .sorted { a, b in
                if a.kind != b.kind { return a.kind == .directory }
                if let ta = a.trackNumber, let tb = b.trackNumber, ta != tb { return ta < tb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
