import Foundation

/// 播放列表文件中的一条记录（M3U / PLS 通用）
public struct PlaylistEntry: Equatable, Sendable {
    public var location: String
    public var title: String?
    public var duration: TimeInterval?

    public init(location: String, title: String? = nil, duration: TimeInterval? = nil) {
        self.location = location
        self.title = title
        self.duration = duration
    }
}

public enum PlaylistFile {
    // MARK: M3U

    public static func parseM3U(_ text: String) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pendingTitle: String?
        var pendingDuration: TimeInterval?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                if let comma = body.firstIndex(of: ",") {
                    let seconds = Double(body[..<comma].trimmingCharacters(in: .whitespaces)) ?? -1
                    pendingDuration = seconds >= 0 ? seconds : nil
                    let title = body[body.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    pendingTitle = title.isEmpty ? nil : title
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            entries.append(PlaylistEntry(location: line, title: pendingTitle, duration: pendingDuration))
            pendingTitle = nil
            pendingDuration = nil
        }
        return entries
    }

    public static func makeM3U(_ entries: [PlaylistEntry]) -> String {
        var out = "#EXTM3U\n"
        for e in entries {
            let seconds = e.duration.map { Int($0.rounded()) } ?? -1
            out += "#EXTINF:\(seconds),\(e.title ?? "")\n\(e.location)\n"
        }
        return out
    }

    // MARK: PLS

    public static func parsePLS(_ text: String) -> [PlaylistEntry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: TimeInterval] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].lowercased()
            let value = String(line[line.index(after: eq)...])
            func number(after prefix: String) -> Int? {
                key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil
            }
            if let n = number(after: "file") { files[n] = value }
            else if let n = number(after: "title") { titles[n] = value }
            else if let n = number(after: "length"), let s = Double(value), s >= 0 { lengths[n] = s }
        }
        return files.keys.sorted().map { n in
            PlaylistEntry(location: files[n]!, title: titles[n], duration: lengths[n])
        }
    }

    public static func makePLS(_ entries: [PlaylistEntry]) -> String {
        var out = "[playlist]\n"
        for (i, e) in entries.enumerated() {
            let n = i + 1
            out += "File\(n)=\(e.location)\n"
            if let t = e.title { out += "Title\(n)=\(t)\n" }
            out += "Length\(n)=\(e.duration.map { Int($0.rounded()) } ?? -1)\n"
        }
        out += "NumberOfEntries=\(entries.count)\nVersion=2\n"
        return out
    }

    public static func parse(_ text: String, fileExtension: String) -> [PlaylistEntry] {
        fileExtension.lowercased() == "pls" ? parsePLS(text) : parseM3U(text)
    }

    public static func entries(for tracks: [Track]) -> [PlaylistEntry] {
        tracks.map { PlaylistEntry(location: $0.uri, title: $0.displayName, duration: $0.duration) }
    }
}
