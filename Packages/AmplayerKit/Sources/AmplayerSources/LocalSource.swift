import Foundation
import AmplayerCore

/// App 的 Documents 目录（可通过“文件”App 和 Finder 文件共享放入音乐）
public struct LocalSource: MediaSource {
    public let config: SourceConfig
    public let root: URL

    public init(config: SourceConfig = .local, root: URL = LocalSource.defaultRoot) {
        self.config = config
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 从“文件”App 导入的文件放这里
    public static var importsFolder: URL {
        defaultRoot.appendingPathComponent("Imported", isDirectory: true)
    }

    public func list(path: String) async throws -> [SourceItem] {
        let dir = url(for: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return contents.compactMap { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let name = item.lastPathComponent
            let childPath = (path as NSString).appendingPathComponent(name)
            if values?.isDirectory == true {
                if name == "Playlists" && path == "/" { return nil }
                return SourceItem(path: childPath, name: name, kind: .directory)
            }
            guard AudioFormats.isPlayable(name) else { return nil }
            return SourceItem(path: childPath, name: name, kind: .audio, size: values?.fileSize.map(Int64.init))
        }
    }

    public func download(path: String, to destination: URL) async throws {
        try FileManager.default.copyItem(at: url(for: path), to: destination)
    }

    public func localURL(path: String) -> URL? { url(for: path) }

    public func testConnection() async throws {}

    private func url(for path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return trimmed.isEmpty ? root : root.appendingPathComponent(trimmed)
    }
}
