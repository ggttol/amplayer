import Foundation

public enum SourceFactory {
    /// 根据配置创建来源，密码从 Keychain 读取
    public static func make(_ config: SourceConfig, password: String? = nil) -> any MediaSource {
        let pw = password ?? CredentialStore.password(for: config.id)
        switch config.kind {
        case .local: return LocalSource(config: config)
        case .webdav: return WebDAVSource(config: config, password: pw)
        case .smb: return SMBSource(config: config, password: pw)
        case .subsonic: return SubsonicSource(config: config, password: pw)
        case .jellyfin, .emby: return JellyfinSource(config: config, password: pw)
        case .synology: return SynologySource(config: config, password: pw)
        case .dlna: return DLNASource(config: config)
        }
    }
}
