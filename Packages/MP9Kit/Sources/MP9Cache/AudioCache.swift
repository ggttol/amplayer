import CryptoKit
import Foundation
import MP9Core
import MP9Sources

/// 网络曲目的本地缓存
///
/// - 普通缓存在 Caches 目录，按最近使用时间做 LRU 淘汰，系统空间不足时也可能被清掉；
/// - “离线下载”的曲目放在 Application Support，不会被淘汰。
public actor AudioCache {
    public static let shared = AudioCache()

    public let cacheDirectory: URL
    public let offlineDirectory: URL
    /// 缓存上限（字节）
    public var limit: Int64

    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(
        cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCache", isDirectory: true),
        offlineDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true),
        limit: Int64 = 2 * 1024 * 1024 * 1024
    ) {
        self.cacheDirectory = cacheDirectory
        self.offlineDirectory = offlineDirectory
        self.limit = limit
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
        var offline = offlineDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? offline.setResourceValues(values)
    }

    public func setLimit(_ bytes: Int64) {
        limit = bytes
        evictIfNeeded()
    }

    /// 缓存文件名：哈希 + 原扩展名（解码器依赖扩展名识别格式）
    nonisolated public func fileName(for track: Track) -> String {
        let digest = SHA256.hash(data: Data(track.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = track.fileExtension.isEmpty ? "mp3" : track.fileExtension
        return "\(digest).\(ext)"
    }

    /// 已在本地（缓存或离线）时返回路径
    public func cachedURL(for track: Track) -> URL? {
        let name = fileName(for: track)
        let offline = offlineDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: offline.path) { return offline }
        let cached = cacheDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cached.path) {
            touch(cached)
            return cached
        }
        return nil
    }

    public func isOffline(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: offlineDirectory.appendingPathComponent(fileName(for: track)).path)
    }

    /// 取得可播放的本地文件：本地来源直接返回；否则从缓存取或下载。并发请求同一首只下载一次。
    public func localURL(for track: Track, source: any MediaSource) async throws -> URL {
        if let direct = source.localURL(path: track.path) { return direct }
        if let cached = cachedURL(for: track) { return cached }
        let key = track.id
        if let task = inFlight[key] { return try await task.value }
        let destination = cacheDirectory.appendingPathComponent(fileName(for: track))
        let task = Task<URL, Error> {
            try await source.download(path: track.path, to: destination)
            return destination
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        evictIfNeeded(protecting: url)
        return url
    }

    /// 离线下载：下载（或从缓存移动）到不会被淘汰的目录
    public func makeOffline(_ track: Track, source: any MediaSource) async throws {
        guard source.localURL(path: track.path) == nil, !isOffline(track) else { return }
        let name = fileName(for: track)
        let target = offlineDirectory.appendingPathComponent(name)
        let cached = cacheDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.moveItem(at: cached, to: target)
            return
        }
        try await source.download(path: track.path, to: target)
    }

    public func removeOffline(_ track: Track) {
        try? FileManager.default.removeItem(at: offlineDirectory.appendingPathComponent(fileName(for: track)))
    }

    public func clearCache() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    public func usage() -> (cache: Int64, offline: Int64) {
        (Self.size(of: cacheDirectory), Self.size(of: offlineDirectory))
    }

    // MARK: 淘汰

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func evictIfNeeded(protecting protected: URL? = nil) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            if url.standardizedFileURL == protected?.standardizedFileURL { continue }
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    private static func size(of dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
