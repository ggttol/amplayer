import Foundation
import Testing
@testable import AmplayerCache
@testable import AmplayerCore
@testable import AmplayerSources

/// 计数下载次数的假来源
private final class FakeSource: MediaSource, @unchecked Sendable {
    let config = SourceConfig(id: "fake", kind: .webdav, name: "Fake")
    let lock = NSLock()
    var downloads = 0
    var rootPath: String { "/" }

    func list(path: String) async throws -> [SourceItem] {
        path == "/"
            ? [SourceItem(path: "/d", name: "d", kind: .directory), SourceItem(path: "/b.mp3", name: "b.mp3", kind: .audio), SourceItem(path: "/x.txt", name: "x.txt", kind: .audio)]
            : [SourceItem(path: "/d/02.mp3", name: "02.mp3", kind: .audio), SourceItem(path: "/d/01.mp3", name: "01.mp3", kind: .audio)]
    }

    func download(path: String, to destination: URL) async throws {
        lock.withLock { downloads += 1 }
        try await Task.sleep(for: .milliseconds(50))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: destination)
    }
}

private func makeCache(limit: Int64 = 10_000) -> AudioCache {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("amplayer-cache-test-\(UUID().uuidString)")
    return AudioCache(cacheDirectory: root.appendingPathComponent("c"), offlineDirectory: root.appendingPathComponent("o"), limit: limit)
}

@Test func cacheDeduplicatesDownloads() async throws {
    let cache = makeCache()
    let source = FakeSource()
    let track = Track(sourceID: "fake", path: "/a.flac", title: "a")
    async let a = cache.localURL(for: track, source: source)
    async let b = cache.localURL(for: track, source: source)
    let (u1, u2) = try await (a, b)
    #expect(u1 == u2)
    #expect(u1.pathExtension == "flac")
    _ = try await cache.localURL(for: track, source: source)
    #expect(source.downloads == 1)
}

@Test func cacheEvictsLeastRecentlyUsed() async throws {
    let cache = makeCache(limit: 2500)
    let source = FakeSource()
    let tracks = (0..<4).map { Track(sourceID: "fake", path: "/\($0).mp3", title: "\($0)") }
    for t in tracks {
        _ = try await cache.localURL(for: t, source: source)
        try await Task.sleep(for: .milliseconds(20))
    }
    let usage = await cache.usage()
    #expect(usage.cache <= 2500)
    #expect(await cache.cachedURL(for: tracks[3]) != nil)
    #expect(await cache.cachedURL(for: tracks[0]) == nil)
}

@Test func offlineSurvivesClear() async throws {
    let cache = makeCache()
    let source = FakeSource()
    let track = Track(sourceID: "fake", path: "/keep.mp3", title: "k")
    try await cache.makeOffline(track, source: source)
    await cache.clearCache()
    #expect(await cache.isOffline(track))
    #expect(await cache.cachedURL(for: track) != nil)
}

@Test func collectTracksRecursesAndFilters() async throws {
    let tracks = try await FakeSource().collectTracks(path: "/")
    #expect(tracks.map(\.path) == ["/b.mp3", "/d/01.mp3", "/d/02.mp3"])
}
