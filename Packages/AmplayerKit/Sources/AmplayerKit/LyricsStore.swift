import CryptoKit
import Foundation
import AmplayerCore

/// 找到的歌词存到磁盘（Application Support/Amplayer/Lyrics），下次直接读；
/// 没找到的只在本次运行内记住，之后补了 .lrc 还能找到。
actor LyricsStore {
    private var missing = Set<String>()

    private nonisolated var directory: URL {
        let url = Storage.supportDirectory.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated func file(for track: Track) -> URL {
        let hash = SHA256.hash(data: Data(track.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).lrc")
    }

    nonisolated func cached(_ track: Track) -> Lyrics? {
        guard let data = try? Data(contentsOf: file(for: track)), let text = String(data: data, encoding: .utf8) else { return nil }
        return Lyrics.parse(text)
    }

    func isKnownMissing(_ track: Track) -> Bool { missing.contains(track.id) }

    func save(_ text: String, for track: Track) {
        missing.remove(track.id)
        try? Data(text.utf8).write(to: file(for: track), options: .atomic)
    }

    func markMissing(_ track: Track) { missing.insert(track.id) }

    func remove(_ track: Track) {
        missing.remove(track.id)
        try? FileManager.default.removeItem(at: file(for: track))
    }

    func clear() {
        missing.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
