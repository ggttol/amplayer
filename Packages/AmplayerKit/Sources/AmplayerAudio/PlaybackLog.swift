import Foundation

/// 播放日志：切歌、播完、出错、打断、输出设备变化等，留最近 300 条（内存 + Caches 文件），
/// 方便用户遇到问题时复制给开发者。
public enum PlaybackLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = loadSaved()
    private static let limit = 300

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("playback-log.txt")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    public static func add(_ message: String) {
        lock.lock()
        lines.append("\(formatter.string(from: Date())) \(message)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        let text = lines.joined(separator: "\n")
        lock.unlock()
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    public static var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    public static func clear() {
        lock.lock()
        lines = []
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func loadSaved() -> [String] {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
