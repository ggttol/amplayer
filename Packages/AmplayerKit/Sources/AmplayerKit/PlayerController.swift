import Foundation
import MediaPlayer
import AmplayerAudio
import AmplayerCache
import AmplayerCore
import AmplayerSources
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// 播放器总控：播放列表、取文件（缓存/下载）、播放、预取、锁屏信息与远程控制
@MainActor
@Observable
public final class PlayerController {
    public let audio = AudioPlayer()
    public private(set) var queue = PlayQueue()
    /// 正在取文件（下载中）的曲目
    public private(set) var loadingTrackID: String?
    public var lastError: String?
    /// 当前曲目的封面
    public private(set) var artwork: Data?
    /// 当前曲目的歌词；lyricsLoading 为真表示还在找
    public private(set) var lyrics: Lyrics?
    public private(set) var lyricsLoading = false

    @ObservationIgnored public let cache: AudioCache
    @ObservationIgnored private let sources: SourceStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private let saver = Debouncer()
    @ObservationIgnored private let lyricsStore = LyricsStore()
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    /// 读到新标签时通知（曲库据此更新）
    @ObservationIgnored public var onTrackUpdated: ((Track) -> Void)?

    private struct Saved: Codable {
        var queue: PlayQueue
        var volume: Float
        var balance: Float
        var equalizer: EqualizerSettings
    }

    public init(sources: SourceStore, cache: AudioCache = .shared) {
        self.sources = sources
        self.cache = cache
        if let saved = Storage.load(Saved.self, from: "player.json") {
            queue = saved.queue
            audio.volume = saved.volume
            audio.balance = saved.balance
            audio.equalizer = saved.equalizer
        }
        audio.onFinished = { [weak self] in self?.trackFinished() }
        audio.onStateChangedExternally = { [weak self] in self?.updateNowPlaying() }
        setupRemoteCommands()
    }

    public var current: Track? { queue.current }
    public var isPlaying: Bool { audio.state == .playing }
    public var isLoading: Bool { loadingTrackID != nil }

    // MARK: 播放控制

    public func play(index: Int) {
        guard queue.tracks.indices.contains(index) else { return }
        queue.select(index: index)
        load(queue.tracks[index], autoplay: true)
        persist()
    }

    /// 播放键：已加载则继续/从头，未加载则加载当前（或第一首）
    public func play() {
        if audio.info != nil, loadingTrackID == nil, audio.state != .playing {
            audio.play()
            updateNowPlaying()
        } else if audio.info == nil, loadingTrackID == nil {
            if let i = queue.currentIndex ?? (queue.isEmpty ? nil : 0) { play(index: i) }
        }
    }

    public func pause() {
        audio.pause()
        updateNowPlaying()
    }

    public func togglePause() {
        if audio.state == .playing { pause() } else { play() }
    }

    public func stop() {
        loadTask?.cancel()
        loadingTrackID = nil
        audio.stop()
        updateNowPlaying()
    }

    public func next() {
        guard let t = queue.advance(auto: false) else { return }
        load(t, autoplay: true)
        persist()
    }

    public func previous() {
        // 播放超过 3 秒时先回到开头
        if audio.currentTime > 3, audio.state == .playing {
            seek(to: 0)
            return
        }
        guard let t = queue.goBack() else { return }
        load(t, autoplay: true)
        persist()
    }

    public func seek(to time: TimeInterval) {
        audio.seek(to: time)
        updateNowPlaying()
    }

    public func seek(by delta: TimeInterval) {
        seek(to: audio.currentTime + delta)
    }

    // MARK: 播放列表编辑

    public func setQueue(_ tracks: [Track], startAt index: Int? = 0, autoplay: Bool = true) {
        queue.replace(with: tracks, startAt: index)
        readLocalTags(tracks)
        if autoplay, let i = queue.currentIndex { play(index: i) } else { persist() }
    }

    public func enqueue(_ tracks: [Track], playIfIdle: Bool = false) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        readLocalTags(tracks)
        if playIfIdle, wasEmpty || audio.info == nil, let first = queue.tracks.firstIndex(where: { $0.id == tracks.first?.id }) {
            play(index: first)
        }
        persist()
    }

    public func playNext(_ tracks: [Track]) {
        queue.insertNext(tracks)
        persist()
    }

    public func remove(at offsets: IndexSet) {
        let removingCurrent = queue.currentIndex.map { offsets.contains($0) } ?? false
        queue.remove(at: offsets)
        if removingCurrent { stop(); audio.unload() }
        persist()
    }

    public func move(from: IndexSet, to: Int) {
        queue.move(from: from, to: to)
        persist()
    }

    public func clear() {
        stop()
        audio.unload()
        queue.removeAll()
        artwork = nil
        persist()
    }

    public enum SortKey { case title, artist, album, path }

    public func sort(by key: SortKey) {
        switch key {
        case .title: queue.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: queue.sort { ($0.artist ?? "", $0.album ?? "", $0.trackNumber ?? 0) < ($1.artist ?? "", $1.album ?? "", $1.trackNumber ?? 0) }
        case .album: queue.sort { ($0.album ?? "", $0.trackNumber ?? 0, $0.title) < ($1.album ?? "", $1.trackNumber ?? 0, $1.title) }
        case .path: queue.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        persist()
    }

    public func reverse() { queue.reverse(); persist() }
    public func randomize() { queue.randomize(); persist() }

    public var shuffle: Bool {
        get { queue.shuffle }
        set { queue.setShuffle(newValue); persist() }
    }

    public var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set { queue.repeatMode = newValue; persist() }
    }

    public var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue.clamped(to: 0...1); persist() }
    }

    public var balance: Float {
        get { audio.balance }
        set { audio.balance = newValue.clamped(to: -1...1); persist() }
    }

    public var equalizer: EqualizerSettings {
        get { audio.equalizer }
        set { audio.equalizer = newValue; persist() }
    }

    public func applyPreset(_ preset: EqualizerPreset) {
        var eq = equalizer
        eq.bands = preset.bands
        eq.preamp = preset.preamp
        equalizer = eq
    }

    /// 更新曲目信息（曲库编辑或读到标签后）
    public func updateTrack(_ track: Track) {
        queue.update(track)
        if track.id == current?.id { updateNowPlaying() }
        persist()
    }

    // MARK: 加载

    private func load(_ track: Track, autoplay: Bool) {
        loadTask?.cancel()
        prefetchTask?.cancel()
        audio.stop()
        lastError = nil
        artwork = nil
        lyricsTask?.cancel()
        lyrics = lyricsStore.cached(track)
        lyricsLoading = lyrics == nil
        loadingTrackID = track.id
        updateNowPlaying()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let source = self.sources.source(track.sourceID) else {
                    throw SourceError.notConfigured("来源已删除：\(track.sourceID)")
                }
                let url = try await self.cache.localURL(for: track, source: source)
                try Task.checkCancellation()
                try self.audio.load(url: url)
                self.loadingTrackID = nil
                if autoplay { self.audio.play() }
                self.updateNowPlaying()
                await self.enrich(track, fileURL: url, source: source)
                self.prefetchNext()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.loadingTrackID = nil
                self.lyricsLoading = false
                self.lastError = "\(track.displayName)：\(error.localizedDescription)"
                self.updateNowPlaying()
            }
        }
    }

    private func trackFinished() {
        guard let next = queue.advance(auto: true) else {
            updateNowPlaying()
            return
        }
        load(next, autoplay: true)
        persist()
    }

    /// 预先缓存下一首，减少切歌等待
    private func prefetchNext() {
        guard let i = queue.nextIndex(auto: true), i != queue.currentIndex else { return }
        let track = queue.tracks[i]
        guard let source = sources.source(track.sourceID), source.localURL(path: track.path) == nil else { return }
        let cache = cache
        prefetchTask = Task.detached(priority: .utility) {
            _ = try? await cache.localURL(for: track, source: source)
        }
    }

    /// 从文件标签补全信息，并取封面
    private func enrich(_ track: Track, fileURL: URL, source: any MediaSource) async {
        let tags = await MetadataReader.read(url: fileURL)
        let preferFileTags = [.local, .webdav, .smb, .aliyun, .baidu].contains(source.config.kind)
        let updated = MetadataReader.merge(tags, into: track, preferFileTags: preferFileTags)
        if updated != track {
            queue.update(updated)
            onTrackUpdated?(updated)
            persist()
        }
        findLyrics(for: updated, source: source, embedded: tags.lyrics)
        if let data = tags.artwork {
            artwork = data
        } else if let ref = track.artworkRef, let request = try? await source.artworkRequest(ref: ref),
                  let (data, response) = try? await HTTPClient.forConfig(source.config).session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
            if current?.id == track.id { artwork = data }
        }
        updateNowPlaying()
    }

    // MARK: 歌词

    /// 优先顺序：已缓存 → 来源提供的（同名 .lrc、群晖/Navidrome 歌词接口）→ 文件内嵌；有时间轴的优先
    private func findLyrics(for track: Track, source: any MediaSource, embedded: String?) {
        guard lyrics == nil else { lyricsLoading = false; return }
        let store = lyricsStore
        lyricsTask = Task { [weak self] in
            let remote: String? = await store.isKnownMissing(track) ? nil : await source.lyrics(for: track)
            guard !Task.isCancelled else { return }
            let remoteLyrics = remote.flatMap(Lyrics.parse)
            let embeddedLyrics = embedded.flatMap(Lyrics.parse)
            let pick: (String, Lyrics)?
            if let remote, let r = remoteLyrics, r.isSynced || embeddedLyrics?.isSynced != true {
                pick = (remote, r)
            } else if let embedded, let e = embeddedLyrics {
                pick = (embedded, e)
            } else {
                pick = nil
            }
            if let pick { await store.save(pick.0, for: track) } else { await store.markMissing(track) }
            guard let self, !Task.isCancelled, self.current?.id == track.id else { return }
            self.lyrics = pick?.1
            self.lyricsLoading = false
        }
    }

    /// 手动指定歌词文本（例如从“文件”导入 .lrc）
    public func setLyrics(_ text: String) -> Bool {
        guard let track = current, let parsed = Lyrics.parse(text) else { return false }
        lyrics = parsed
        lyricsLoading = false
        let store = lyricsStore
        Task { await store.save(text, for: track) }
        return true
    }

    /// 清掉当前曲目的歌词缓存并重新查找
    public func reloadLyrics() {
        guard let track = current, let source = sources.source(track.sourceID) else { return }
        lyricsTask?.cancel()
        lyrics = nil
        lyricsLoading = true
        let store = lyricsStore
        let cache = cache
        lyricsTask = Task { [weak self] in
            await store.remove(track)
            let fileURL = if let local = source.localURL(path: track.path) { local } else { await cache.cachedURL(for: track) }
            let embedded = if let fileURL { await MetadataReader.read(url: fileURL).lyrics } else { String?.none }
            guard let self, !Task.isCancelled else { return }
            self.findLyrics(for: track, source: source, embedded: embedded)
        }
    }

    /// 本机文件读标签很快，加入列表时就补全时长和标题
    private func readLocalTags(_ tracks: [Track]) {
        let local = tracks.filter { $0.duration == nil }.compactMap { t -> (Track, URL)? in
            guard let url = sources.source(t.sourceID)?.localURL(path: t.path) else { return nil }
            return (t, url)
        }
        guard !local.isEmpty else { return }
        Task { [weak self] in
            for (track, url) in local.prefix(500) {
                let tags = await MetadataReader.read(url: url)
                let updated = MetadataReader.merge(tags, into: track, preferFileTags: true)
                guard let self, updated != track else { continue }
                self.queue.update(updated)
                self.onTrackUpdated?(updated)
            }
            self?.persist()
        }
    }

    private func persist() {
        saver.schedule { [weak self] in
            guard let self else { return }
            Storage.save(Saved(queue: self.queue, volume: self.audio.volume, balance: self.audio.balance, equalizer: self.audio.equalizer), to: "player.json")
        }
    }

    // MARK: 锁屏与控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePause() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            MainActor.assumeIsolated { self?.seek(to: time) }
            return .success
        }
    }

    /// 系统会在后台队列向封面要图，闭包不能在 MainActor 里创建（否则 Swift 6 隔离检查直接崩溃）
#if canImport(UIKit)
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
    #endif

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audio.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: audio.state == .playing ? 1.0 : 0.0,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = audio.info?.duration ?? track.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        #if canImport(UIKit)
        if let data = artwork, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
        }
        #endif
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = audio.state == .playing ? .playing : (audio.state == .paused ? .paused : .stopped)
        #endif
    }
}
