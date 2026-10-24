import Foundation

public enum SourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case local, webdav, smb, subsonic, jellyfin, emby, synology, dlna, aliyun, baidu

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: "本机文件"
        case .webdav: "WebDAV / Alist / OpenList"
        case .smb: "SMB 共享"
        case .subsonic: "Subsonic / Navidrome"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .synology: "群晖 Audio Station"
        case .dlna: "UPnP / DLNA 媒体服务器"
        case .aliyun: "阿里云盘"
        case .baidu: "百度网盘"
        }
    }

    public var symbol: String {
        switch self {
        case .local: "iphone"
        case .webdav: "globe"
        case .smb: "externaldrive.connected.to.line.below"
        case .subsonic: "music.note.house"
        case .jellyfin, .emby: "play.tv"
        case .synology: "server.rack"
        case .dlna: "dot.radiowaves.left.and.right"
        case .aliyun, .baidu: "icloud"
        }
    }

    /// 表单需要哪些字段
    public var needsURL: Bool { self != .local && self != .aliyun && self != .baidu }
    public var needsCredentials: Bool { [.webdav, .smb, .subsonic, .jellyfin, .emby, .synology].contains(self) }
    public var usesOAuth: Bool { self == .aliyun || self == .baidu }

    public var urlPlaceholder: String {
        switch self {
        case .webdav: "https://nas.local:5006/music 或 http://alist:5244/dav"
        case .smb: "smb://192.168.1.10/Music"
        case .subsonic: "https://music.example.com"
        case .jellyfin: "http://192.168.1.10:8096"
        case .emby: "http://192.168.1.10:8096/emby"
        case .synology: "https://192.168.1.10:5001"
        case .dlna: "http://192.168.1.10:8200/rootDesc.xml"
        default: ""
        }
    }
}

/// 用户添加的一个来源。密码/令牌不在这里，存在 Keychain。
public struct SourceConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: SourceKind
    public var name: String
    public var url: String
    public var username: String
    /// 是否信任自签名证书（NAS 常见）
    public var allowInsecureTLS: Bool

    public init(id: String = UUID().uuidString, kind: SourceKind, name: String, url: String = "", username: String = "", allowInsecureTLS: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.username = username
        self.allowInsecureTLS = allowInsecureTLS
    }

    public static let localID = "local"
    public static let local = SourceConfig(id: localID, kind: .local, name: "本机文件")

    /// 去掉末尾斜杠的基础 URL
    public func baseURL() throws -> URL {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = (kind == .smb ? "smb://" : "http://") + s }
        guard let u = URL(string: s), u.host != nil else { throw SourceError.invalidURL(url) }
        return u
    }
}
