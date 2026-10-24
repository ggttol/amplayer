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
    /// 已经无缝排在当前曲目后面的那首
    @ObservationIgnored private var armedTrackID: String?
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
        audio.onAdvancedToNext = { [weak self] url in self?.advancedGaplessly(to: url) }
        audio.onStateChangedExternally = { [weak self] in self?.updateNowPlaying() }
        setupRemoteCommands()
    }

    public var current: Track? { queue.current }
    public var isPlaying: Bool { audio.state == .playing }
    public var isLoading: Bool { loadingTrackID != nil }
    /// 正在下载的当前曲目进度文字（“35%”），没在下载时为 nil
    public var loadingProgress: String? {
        loadingTrackID.flatMap { DownloadProgressCenter.shared.label(for: $0) }
    }

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
        armedTrackID = nil
        updateNowPlaying()
        armGapless()
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
        armedTrackID = nil
        resetPerTrackState(for: track)
        loadingTrackID = track.id
        updateNowPlaying()
        PlaybackLog.add("加载：\(track.displayName)")
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
                PlaybackLog.add("加载失败：\(self.lastError!)")
                self.updateNowPlaying()
            }
        }
    }

    /// 换曲目时清掉上一首的封面、错误、歌词
    private func resetPerTrackState(for track: Track) {
        lastError = nil
        artwork = nil
        lyricsTask?.cancel()
        lyrics = Self.forDisplay(lyricsStore.cached(track))
        lyricsLoading = lyrics == nil
    }

    // MARK: 无缝衔接

    /// 下一首已经在本地（本机或缓存）时，排到当前这首后面
    private func armGapless() {
        guard armedTrackID == nil, !audio.hasQueuedNext, audio.info != nil, loadingTrackID == nil,
              let i = queue.nextIndex(auto: true) else { return }
        let next = queue.tracks[i]
        guard let source = sources.source(next.sourceID) else { return }
        let cache = cache
        let currentID = current?.id
        Task { [weak self] in
            let url: URL? = if let local = source.localURL(path: next.path) { local } else { await cache.cachedURL(for: next) }
            guard let self, let url, self.current?.id == currentID, self.armedTrackID == nil,
                  self.queue.nextIndex(auto: true).map({ self.queue.tracks[$0].id }) == next.id else { return }
            if self.audio.enqueueNext(url: url) { self.armedTrackID = next.id }
        }
    }

    /// 排好的下一首已经开始播了
    private func advancedGaplessly(to url: URL) {
        let expected = armedTrackID
        armedTrackID = nil
        guard let next = queue.advance(auto: true) else { return }
        PlaybackLog.add("无缝衔接到：\(next.displayName)\(next.id == expected ? "" : "（列表已变，改为普通切歌）")")
        guard next.id == expected, let source = sources.source(next.sourceID) else {
            // 播放列表在这期间变了：按普通方式切到正确的那首
            load(next, autoplay: true)
            persist()
            return
        }
        prefetchTask?.cancel()
        resetPerTrackState(for: next)
        updateNowPlaying()
        persist()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.enrich(next, fileURL: url, source: source)
            self.prefetchNext()
        }
    }

    /// 播放列表、随机、循环改了以后，排好的下一首可能不对了：撤掉重排
    private func revalidateGapless() {
        guard let armed = armedTrackID else { return }
        let expected = queue.nextIndex(auto: true).map { queue.tracks[$0].id }
        guard expected != armed else { return }
        armedTrackID = nil
        // AVAudioPlayerNode 不能单独撤掉一段，只能在当前位置重新调度
        if audio.hasQueuedNext { audio.seek(to: audio.currentTime) }
        armGapless()
    }

    private func trackFinished() {
        guard let next = queue.advance(auto: true) else {
            PlaybackLog.add("播完：已是列表最后一首（共 \(queue.tracks.count) 首，循环：\(queue.repeatMode)，随机：\(queue.shuffle)），停止")
            updateNowPlaying()
            return
        }
        PlaybackLog.add("播完，自动下一首：\(next.displayName)")
        load(next, autoplay: true)
        persist()
    }

    /// 预先缓存下一首，减少切歌等待
    private func prefetchNext() {
        guard let i = queue.nextIndex(auto: true) else { return }
        let track = queue.tracks[i]
        guard let source = sources.source(track.sourceID), i != queue.currentIndex,
              source.localURL(path: track.path) == nil else {
            armGapless()
            return
        }
        let cache = cache
        prefetchTask = Task { [weak self] in
            _ = try? await Task.detached(priority: .utility) { try await cache.localURL(for: track, source: source) }.value
            guard !Task.isCancelled else { return }
            self?.armGapless()
        }
    }

    /// 从文件标签补全信息，并取封面
    private func enrich(_ track: Track, fileURL: URL, source: any MediaSource) async {
        let tags = await MetadataReader.read(url: fileURL)
        let preferFileTags = [.local, .webdav, .smb].contains(source.config.kind)
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

    /// 歌词繁体转简体（设置里可关，默认开）
    public static var simplifyLyrics: Bool {
        get { UserDefaults.standard.object(forKey: "amplayer.simplifyLyrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "amplayer.simplifyLyrics") }
    }

    private static func forDisplay(_ lyrics: Lyrics?) -> Lyrics? {
        simplifyLyrics ? lyrics?.simplified() : lyrics
    }

    /// 是否联网查歌词（设置里可关，默认开）
    public static var onlineLyricsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "amplayer.onlineLyrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "amplayer.onlineLyrics") }
    }

    /// 优先顺序：已缓存 → 来源提供的（同名 .lrc、群晖/Navidrome 歌词接口）→ 文件内嵌 → 在线（LRCLIB）。
    /// 带时间轴的优先：本地只有纯文本时也会去在线找一份同步歌词。
    private func findLyrics(for track: Track, source: any MediaSource, embedded: String?) {
        guard lyrics == nil else { lyricsLoading = false; return }
        let store = lyricsStore
        let online = Self.onlineLyricsEnabled
        lyricsTask = Task { [weak self] in
            guard !(await store.isKnownMissing(track)) else {
                self?.lyricsLoading = false
                return
            }
            var found: [(String, Lyrics)] = []
            if let text = await source.lyrics(for: track), let parsed = Lyrics.parse(text) { found.append((text, parsed)) }
            if let text = embedded, let parsed = Lyrics.parse(text) { found.append((text, parsed)) }
            if online, !found.contains(where: { $0.1.isSynced }), !Task.isCancelled,
               let text = await OnlineLyrics.shared.lyrics(for: track), let parsed = Lyrics.parse(text) {
                found.append((text, parsed))
            }
            guard !Task.isCancelled else { return }
            let pick = found.first { $0.1.isSynced } ?? found.first
            if let pick { await store.save(pick.0, for: track) } else { await store.markMissing(track) }
            guard let self, !Task.isCancelled, self.current?.id == track.id else { return }
            self.lyrics = Self.forDisplay(pick?.1)
            self.lyricsLoading = false
        }
    }

    /// 手动指定歌词文本（例如从“文件”导入 .lrc）
    public func setLyrics(_ text: String) -> Bool {
        guard let track = current, let parsed = Lyrics.parse(text) else { return false }
        lyrics = Self.forDisplay(parsed)
        lyricsLoading = false
        let store = lyricsStore
        Task { await store.save(text, for: track) }
        return true
    }

    /// 设置变化后按新设置重新显示当前歌词（从缓存读原文）
    public func refreshLyricsDisplay() {
        guard let track = current, let cached = lyricsStore.cached(track) else { return }
        lyrics = Self.forDisplay(cached)
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
        revalidateGapless()
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
