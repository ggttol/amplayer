import AMSMB2
import Foundation
import AmplayerCore

/// SMB2/3 共享（Windows 共享、各类 NAS、macOS 文件共享）
///
/// 路径格式 `/<共享名>/<目录>/...`。URL 里带共享名时（smb://host/Music）根目录直接进入该共享。
public final class SMBSource: MediaSource, @unchecked Sendable {
    public let config: SourceConfig
    private let password: String?
    private let lock = NSLock()
    private var managers: [String: SMB2Manager] = [:]

    public init(config: SourceConfig, password: String?) {
        self.config = config
        self.password = password
    }

    /// URL 中指定的共享名和子目录
    private var fixedPrefix: String? {
        guard let url = try? config.baseURL() else { return nil }
        let p = url.path
        return p.isEmpty || p == "/" ? nil : p
    }

    public var rootPath: String { fixedPrefix ?? "/" }

    public func list(path: String) async throws -> [SourceItem] {
        let (share, inner) = split(path)
        guard let share else {
            let manager = try makeManager()
            let shares = try await manager.listShares()
            return shares
                .filter { !$0.name.hasSuffix("$") }
                .map { SourceItem(path: "/\($0.name)", name: $0.name, kind: .directory) }
        }
        let manager = try await connected(share: share)
        let entries = try await manager.contentsOfDirectory(atPath: inner)
        return entries.compactMap { e in
            guard let name = e[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let child = "/\(share)" + (inner == "/" ? "" : inner) + "/\(name)"
            if (e[.isDirectoryKey] as? Bool) == true {
                return SourceItem(path: child, name: name, kind: .directory)
            }
            let size = (e[.fileSizeKey] as? Int64) ?? (e[.fileSizeKey] as? NSNumber)?.int64Value
            return SourceItem(path: child, name: name, kind: .audio, size: size)
        }
    }

    public func download(path: String, to destination: URL) async throws {
        let (share, inner) = split(path)
        guard let share else { throw SourceError.protocolError("路径缺少共享名：\(path)") }
        let manager = try await connected(share: share)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.appendingPathExtension("part")
        try? fm.removeItem(at: tmp)
        try await manager.downloadItem(atPath: inner, to: tmp, progress: nil)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    public func testConnection() async throws {
        _ = try await list(path: rootPath)
    }

    // MARK: 连接

    /// "/Music/A/b.mp3" → ("Music", "/A/b.mp3")
    private func split(_ path: String) -> (String?, String) {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let share = comps.first else { return (nil, "/") }
        let rest = comps.dropFirst().joined(separator: "/")
        return (share, "/" + rest)
    }

    private func makeManager() throws -> SMB2Manager {
        let base = try config.baseURL()
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = base.host
        comps.port = base.port
        guard let url = comps.url else { throw SourceError.invalidURL(config.url) }
        let credential = config.username.isEmpty
            ? URLCredential(user: "guest", password: "", persistence: .forSession)
            : URLCredential(user: config.username, password: password ?? "", persistence: .forSession)
        guard let manager = SMB2Manager(url: url, credential: credential) else { throw SourceError.invalidURL(config.url) }
        return manager
    }

    private func connected(share: String) async throws -> SMB2Manager {
        if let m = lock.withLock({ managers[share] }) { return m }
        let manager = try makeManager()
        do {
            try await manager.connectShare(name: share)
        } catch {
            throw SourceError.authenticationFailed(error.localizedDescription)
        }
        lock.withLock { managers[share] = manager }
        return manager
    }
}
