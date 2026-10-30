import Foundation
import AmplayerAudio
import AmplayerCore
import AmplayerSources
import Observation

/// 曲库：从各来源扫描进来的曲目，支持搜索、按艺术家/专辑分组；以及保存的播放列表（M3U）
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var tracks: [Track] = []
    /// 正在扫描的来源 ID 与已找到数量
    public private(set) var scanning: [String: Int] = [:]
    public var lastError: String?

    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private let saver = Debouncer(delay: .seconds(1))
    @ObservationIgnored private var scanTasks: [String: Task<Void, Never>] = [:]
    private static let fileName = "library.json"

    public init() {
        tracks = Storage.load([Track].self, from: Self.fileName) ?? []
        rebuildIndex()
    }

    // MARK: 曲目

    public func add(_ newTracks: [Track]) {
        for t in newTracks {
            if let i = index[t.id] {
                // 保留已读到的更完整信息
                var merged = t
                let old = tracks[i]
                if merged.artist == nil { merged.artist = old.artist }
                if merged.album == nil { merged.album = old.album }
                if merged.duration == nil { merged.duration = old.duration }
                if merged.trackNumber == nil { merged.trackNumber = old.trackNumber }
                tracks[i] = merged
            } else {
                index[t.id] = tracks.count
                tracks.append(t)
            }
        }
        persist()
    }

    /// 只更新已在曲库里的曲目
    public func update(_ track: Track) {
        guard let i = index[track.id] else { return }
        tracks[i] = track
        persist()
    }

    public func remove(sourceID: String) {
        tracks.removeAll { $0.sourceID == sourceID }
        rebuildIndex()
        persist()
    }

    public func remove(_ ids: Set<String>) {
        tracks.removeAll { ids.contains($0.id) }
        rebuildIndex()
        persist()
    }

    public func contains(_ id: String) -> Bool { index[id] != nil }

    public func search(_ query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.artist?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.album?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    public struct Group: Identifiable, Hashable {
        public var id: String { name }
        public var name: String
        public var tracks: [Track]
    }

    public func artists(in list: [Track]? = nil) -> [Group] {
        group(list ?? tracks) { $0.artist?.nilIfEmpty ?? String(localized: "未知艺术家") }
    }

    public func albums(in list: [Track]? = nil) -> [Group] {
        group(list ?? tracks) { $0.album?.nilIfEmpty ?? String(localized: "未知专辑") }
            .map { Group(name: $0.name, tracks: $0.tracks.sorted { ($0.trackNumber ?? 999, $0.title) < ($1.trackNumber ?? 999, $1.title) }) }
    }

    private func group(_ list: [Track], key: (Track) -> String) -> [Group] {
        Dictionary(grouping: list, by: key)
            .map { Group(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: 扫描

    /// 递归扫描来源目录加入曲库
    public func scan(_ source: any MediaSource, path: String) {
        let id = source.config.id
        scanTasks[id]?.cancel()
        scanning[id] = 0
        scanTasks[id] = Task { [weak self] in
            do {
                var found = try await source.collectTracks(path: path, maxDepth: 12, limit: 50_000)
                self?.scanning[id] = found.count
                // 本机文件读标签很快：扫描时就补上艺术家、专辑、音轨号和时长（网络曲目等播放或缓存后再补）
                for i in found.indices {
                    try Task.checkCancellation()
                    guard let url = source.localURL(path: found[i].path) else { continue }
                    let tags = await MetadataReader.read(url: url)
                    found[i] = MetadataReader.merge(tags, into: found[i], preferFileTags: true)
                }
                self?.add(found)
                self?.scanning[id] = nil
            } catch is CancellationError {
                self?.scanning[id] = nil
            } catch {
                self?.lastError = String(localized: "扫描 \(source.config.name) 失败：\(error.localizedDescription)")
                self?.scanning[id] = nil
            }
        }
    }

    public func cancelScan(_ sourceID: String) {
        scanTasks[sourceID]?.cancel()
        scanning[sourceID] = nil
    }

    // MARK: 播放列表文件

    public func savedPlaylists() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.playlistsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["m3u", "m3u8", "pls"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    @discardableResult
    public func savePlaylist(_ tracks: [Track], name: String) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = Storage.playlistsDirectory.appendingPathComponent((safe.isEmpty ? String(localized: "播放列表") : safe) + ".m3u8")
        try PlaylistFile.makeM3U(PlaylistFile.entries(for: tracks)).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 读取播放列表文件。amplayer:// 条目优先用曲库里的信息；相对路径按本机文件处理。
    public func loadPlaylist(_ url: URL) throws -> [Track] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return PlaylistFile.parse(text, fileExtension: url.pathExtension).compactMap { entry in
            if let (sourceID, path) = Track.parseURI(entry.location) {
                let id = Track.makeID(sourceID: sourceID, path: path)
                if let i = index[id] { return tracks[i] }
                return Track(sourceID: sourceID, path: path, title: entry.title ?? Track.title(fromFileName: (path as NSString).lastPathComponent), duration: entry.duration)
            }
            guard !entry.location.contains("://") else { return nil }
            let name = (entry.location as NSString).lastPathComponent
            return Track(sourceID: SourceConfig.localID, path: entry.location.hasPrefix("/") ? entry.location : "/" + entry.location,
                         title: entry.title ?? Track.title(fromFileName: name), duration: entry.duration)
        }
    }

    public func deletePlaylist(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func rebuildIndex() {
        index = Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func persist() {
        saver.schedule { [weak self] in
            guard let self else { return }
            Storage.save(self.tracks, to: Self.fileName)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
