import CryptoKit
import Foundation
import Observation
import AmplayerCore
import AmplayerSources

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
    /// 正在下载的文件（边下边播从这里读）
    private var growing: [String: GrowingFile] = [:]

    /// 可以开始播放的文件
    public enum Playable: Sendable {
        /// 已经完整在本地
        case complete(URL)
        /// 还在下载，开头已经够了
        case growing(GrowingFile)
    }

    /// 开头下载多少就开始边下边播
    static let streamHead: Int64 = 384 * 1024

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
        // 上次没下完就被杀掉的临时文件（此时还没有任何下载在进行）
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers where url.pathExtension == "part" || url.lastPathComponent.hasPrefix("dl-") {
            try? FileManager.default.removeItem(at: url)
        }
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
        return try await startDownload(track, source: source).task.value
    }

    /// 边下边播：已在本地就给完整文件；否则开始（或接上正在进行的）下载，开头够解析了就返回正在下载的文件。
    /// APE、不知道总大小的，等下载完再给。
    public func playable(for track: Track, source: any MediaSource) async throws -> Playable {
        if let direct = source.localURL(path: track.path) { return .complete(direct) }
        if let cached = cachedURL(for: track) { return .complete(cached) }
        let (task, file) = startDownload(track, source: source)
        if track.fileExtension.lowercased() != "ape" {
            try await file.waitAsync(forFirst: Self.streamHead)
            if !file.isFinished, file.error == nil, file.expectedSize > 0 { return .growing(file) }
        }
        return .complete(try await task.value)
    }

    /// 开始下载（同一首正在下载就接上）
    private func startDownload(_ track: Track, source: any MediaSource) -> (task: Task<URL, Error>, file: GrowingFile) {
        let key = track.id
        if let task = inFlight[key], let file = growing[key] { return (task, file) }
        let destination = cacheDirectory.appendingPathComponent(fileName(for: track))
        // 每次下载用自己的临时文件名：同一首被取消后马上又点，旧下载清理时不会删掉新下载正在写的文件
        let staging = cacheDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))-\(fileName(for: track))")
        let expected = track.fileSize ?? -1
        let file = GrowingFile(partURL: staging.appendingPathExtension("part"), finalURL: destination, expectedSize: expected)
        let throttle = ProgressThrottle()
        let task = Task<URL, Error> {
            let report: @Sendable (Int64, Int64) -> Void = { received, total in
                let size = total > 0 ? total : expected
                file.update(received: received, total: size)
                if throttle.shouldReport(received, size) {
                    Task { @MainActor in DownloadProgressCenter.shared.update(key, received: received, total: size) }
                }
            }
            defer { Task { @MainActor in DownloadProgressCenter.shared.finish(key) } }
            do {
                try await DownloadProgress.$report.withValue(report) {
                    try await source.download(path: track.path, to: staging)
                }
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                file.fail(error)
                downloadEnded(key, file: file, url: nil)
                throw error
            }
            file.finish()
            downloadEnded(key, file: file, url: destination)
            return destination
        }
        inFlight[key] = task
        growing[key] = file
        return (task, file)
    }

    /// 只清自己这次的记录：被取消后同一首可能已经重新开始下载了
    private func downloadEnded(_ key: String, file: GrowingFile, url: URL?) {
        if growing[key] === file {
            inFlight[key] = nil
            growing[key] = nil
        }
        if let url { evictIfNeeded(protecting: url) }
    }

    /// 换歌时取消别的下载：跳过的歌没必要下完，同时下载的连接数有限，占着会让新点的歌排队
    public func cancelDownloads(except keep: Set<String>) {
        for (key, task) in inFlight where !keep.contains(key) {
            task.cancel()
            growing[key]?.fail(CancellationError())
            inFlight[key] = nil
            growing[key] = nil
        }
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
            // 正在下载的不动
            guard url.pathExtension != "part", !url.lastPathComponent.hasPrefix("dl-"), let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
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

/// 界面进度按 1% 或 64 KB 节流（边下边播需要每块都知道，界面不用）
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = -1

    func shouldReport(_ received: Int64, _ total: Int64) -> Bool {
        lock.withLock {
            let step = total > 0 ? max(total / 100, 64 * 1024) : 512 * 1024
            guard last < 0 || received - last >= step || (total > 0 && received >= total) else { return false }
            last = received
            return true
        }
    }
}

/// 正在下载的曲目进度（界面读取）
@MainActor
@Observable
public final class DownloadProgressCenter {
    public static let shared = DownloadProgressCenter()

    public struct Item: Sendable, Equatable {
        public var received: Int64
        /// 总大小；未知为 -1
        public var total: Int64
        public var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }
    }

    public private(set) var items: [String: Item] = [:]

    func update(_ key: String, received: Int64, total: Int64) {
        items[key] = Item(received: received, total: total)
    }

    func finish(_ key: String) {
        items[key] = nil
    }

    /// 给界面用的短文字：“35%”或“3.2 MB”
    public func label(for key: String) -> String? {
        guard let item = items[key] else { return nil }
        if let f = item.fraction { return "\(Int(f * 100))%" }
        return ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
    }
}
