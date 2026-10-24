import Foundation
import AmplayerCore

extension MediaSource {
    /// 找同目录同名的 .lrc（区分大小写的服务器再试 .LRC），下载并解码为文本
    public func siblingLyrics(of path: String) async -> String? {
        guard let base = Self.removingExtension(path) else { return nil }
        for ext in ["lrc", "LRC"] {
            let candidate = base + "." + ext
            if let local = localURL(path: candidate) {
                guard let data = try? Data(contentsOf: local) else { continue }
                if let text = Self.lyricsText(data) { return text }
                continue
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-\(UUID().uuidString).lrc")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try await download(path: candidate, to: tmp)
            } catch {
                continue
            }
            if let data = try? Data(contentsOf: tmp), let text = Self.lyricsText(data) { return text }
        }
        return nil
    }

    static func lyricsText(_ data: Data) -> String? {
        // 歌词文件不会很大；过大的多半不是歌词
        guard !data.isEmpty, data.count < 512 * 1024, let text = Lyrics.decode(data),
              Lyrics.parse(text) != nil else { return nil }
        return text
    }

    /// "fs:/music/a/song.flac" → "fs:/music/a/song"；没有扩展名返回 nil
    static func removingExtension(_ path: String) -> String? {
        let name = path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...]
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return String(path[..<dot])
    }
}
