#if os(iOS)
import CarPlay
import Foundation
import UIKit

/// App 启动时把播放器、曲库、来源交给 CarPlay 用（CarPlay 场景和手机界面共用同一个播放器）
@MainActor
public final class CarPlayHub {
    public static let shared = CarPlayHub()
    public var player: PlayerController?
    public var library: LibraryStore?
    public var sources: SourceStore?

    private init() {}
}

/// CarPlay 车机界面：播放列表、曲库、来源三个标签页，加系统的“正在播放”页面和歌词页。
/// 用 Info.plist 的 CPTemplateApplicationSceneSessionRoleApplication 场景启动。
@MainActor
public final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interface: CPInterfaceController?
    private let queueTemplate = CPListTemplate(title: String(localized: "播放列表"), sections: [])
    private let lyricsTemplate = CPListTemplate(title: String(localized: "歌词"), sections: [])
    private var lyricsTimer: Timer?
    private var lyricsKey = ""
    private var observing = false

    private var hub: CarPlayHub { .shared }

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        queueTemplate.tabTitle = String(localized: "播放列表")
        queueTemplate.tabImage = UIImage(systemName: "list.bullet")
        queueTemplate.emptyViewTitleVariants = [String(localized: "播放列表是空的")]
        queueTemplate.emptyViewSubtitleVariants = [String(localized: "在“曲库”或“来源”里选歌")]
        let tabs = CPTabBarTemplate(templates: [queueTemplate, libraryTemplate(), sourcesTemplate()])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        configureNowPlaying()
        refreshQueue()
        observing = true
        observeQueue()
    }

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        interface = nil
        observing = false
        lyricsTimer?.invalidate()
        lyricsTimer = nil
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: 正在播放

    private func configureNowPlaying() {
        let now = CPNowPlayingTemplate.shared
        now.isUpNextButtonEnabled = true
        now.upNextTitle = String(localized: "播放列表")
        now.add(self)
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            guard let player = self?.hub.player else { return }
            player.shuffle.toggle()
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            guard let player = self?.hub.player else { return }
            player.repeatMode = switch player.repeatMode {
            case .off: .all
            case .all: .one
            default: .off
            }
        }
        let lyricsButton = CPNowPlayingImageButton(image: UIImage(systemName: "quote.bubble") ?? UIImage()) { [weak self] _ in
            self?.showLyrics()
        }
        now.updateNowPlayingButtons([shuffle, repeatButton, lyricsButton])
    }

    public nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            guard let interface = self.interface else { return }
            // 列表项不能同时挂在两个模板上：另建一份
            let list = CPListTemplate(title: String(localized: "播放列表"), sections: [self.queueSection()])
            interface.pushTemplate(list, animated: true, completion: nil)
        }
    }

    public nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    private func showNowPlaying() {
        guard let interface else { return }
        if interface.topTemplate === CPNowPlayingTemplate.shared { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    /// 播放一组曲目并切到“正在播放”
    private func play(_ tracks: [Track], at index: Int) {
        guard let player = hub.player, !tracks.isEmpty else { return }
        player.setQueue(tracks, startAt: min(max(index, 0), tracks.count - 1), autoplay: true)
        showNowPlaying()
    }

    // MARK: 歌词

    /// “正在播放”页面的歌词按钮：打开歌词页，播放时每半秒看一次唱到哪句
    private func showLyrics() {
        guard let interface else { return }
        lyricsTemplate.emptyViewTitleVariants = [String(localized: "没有歌词")]
        lyricsTemplate.emptyViewSubtitleVariants = [String(localized: "在手机上长按歌词区域可以在线搜索")]
        lyricsKey = ""
        refreshLyrics()
        if !interface.templates.contains(where: { $0 === lyricsTemplate }) {
            interface.pushTemplate(lyricsTemplate, animated: true, completion: nil)
        }
        lyricsTimer?.invalidate()
        lyricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 歌词页退出后停掉
                guard self.interface?.templates.contains(where: { $0 === self.lyricsTemplate }) == true else {
                    self.lyricsTimer?.invalidate()
                    self.lyricsTimer = nil
                    return
                }
                self.refreshLyrics()
            }
        }
    }

    /// 同步歌词：当前这句放在最上面（标成正在播放），下面接着几句，点一句跳过去；纯文本整首列出来
    private func refreshLyrics() {
        guard let player = hub.player else { return }
        let trackID = player.current?.id ?? ""
        guard let lyrics = player.lyrics, !lyrics.lines.isEmpty else {
            if lyricsKey != trackID + ":none" {
                lyricsKey = trackID + ":none"
                lyricsTemplate.updateSections([])
            }
            return
        }
        let lines = Array(lyrics.lines.enumerated())
        func item(_ text: String) -> CPListItem {
            CPListItem(text: text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : text, detailText: nil)
        }
        if lyrics.isSynced {
            let current = lyrics.index(at: player.lyricsTime)
            let start = current ?? 0
            let key = "\(trackID):\(start):\(current != nil)"
            guard key != lyricsKey else { return }
            lyricsKey = key
            let items = lines[start..<min(lines.count, start + 8)].map { i, line -> CPListItem in
                let row = item(line.text)
                row.isPlaying = i == current
                row.playingIndicatorLocation = .leading
                row.handler = { _, done in
                    if let t = line.time { player.seek(to: t - player.lyricsOffset) }
                    done()
                }
                return row
            }
            lyricsTemplate.updateSections([CPListSection(items: items)])
        } else {
            guard lyricsKey != trackID + ":plain" else { return }
            lyricsKey = trackID + ":plain"
            lyricsTemplate.updateSections([CPListSection(items: lines.prefix(Self.limit).map { item($0.element.text) })])
        }
    }

    // MARK: 播放列表（当前队列）

    /// 队列或当前曲目变化时刷新列表
    private func observeQueue() {
        guard observing, let player = hub.player else { return }
        withObservationTracking {
            _ = player.queue.tracks
            _ = player.queue.currentIndex
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshQueue()
                self?.observeQueue()
            }
        }
    }

    private func refreshQueue() {
        queueTemplate.updateSections([queueSection()])
    }

    /// 当前队列；太长时只列当前曲目附近的一段（车机列表有条数上限）
    private func queueSection() -> CPListSection {
        guard let player = hub.player else { return CPListSection(items: []) }
        let all = player.queue.tracks
        let current = player.queue.currentIndex
        let start = max(0, min((current ?? 0) - Self.limit / 4, all.count - Self.limit))
        let window = all.indices.dropFirst(start).prefix(Self.limit)
        let items = window.map { i -> CPListItem in
            let track = all[i]
            let item = CPListItem(text: track.displayName, detailText: track.album)
            item.isPlaying = i == current
            item.playingIndicatorLocation = .trailing
            item.handler = { [weak self] _, done in
                player.play(index: i)
                self?.showNowPlaying()
                done()
            }
            return item
        }
        return CPListSection(items: items)
    }

    private static var limit: Int { max(12, min(CPListTemplate.maximumItemCount, 500)) }

    // MARK: 曲库

    private func libraryTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "曲库"), sections: [])
        template.tabTitle = String(localized: "曲库")
        template.tabImage = UIImage(systemName: "music.note.list")
        let rows: [(String, String, () -> CPListTemplate?)] = [
            (String(localized: "歌曲"), "music.note", { [weak self] in self?.songsTemplate() }),
            (String(localized: "艺术家"), "music.mic", { [weak self] in self?.groupsTemplate(title: String(localized: "艺术家"), groups: self?.hub.library?.artists() ?? []) }),
            (String(localized: "专辑"), "square.stack", { [weak self] in self?.groupsTemplate(title: String(localized: "专辑"), groups: self?.hub.library?.albums() ?? []) }),
            (String(localized: "播放列表"), "list.bullet.rectangle", { [weak self] in self?.playlistsTemplate() }),
        ]
        var items: [CPListItem] = rows.map { title, symbol, make in
            let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                if let next = make() { self?.interface?.pushTemplate(next, animated: true, completion: nil) }
                done()
            }
            return item
        }
        let shuffleAll = CPListItem(text: String(localized: "随机播放全部"), detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffleAll.handler = { [weak self] _, done in
            if let self, let tracks = self.hub.library?.tracks, !tracks.isEmpty {
                self.hub.player?.shuffle = true
                self.play(tracks, at: Int.random(in: 0..<tracks.count))
            }
            done()
        }
        items.insert(shuffleAll, at: 0)
        template.updateSections([CPListSection(items: items)])
        template.emptyViewTitleVariants = [String(localized: "曲库是空的")]
        return template
    }

    private func trackItems(_ tracks: [Track]) -> [CPListItem] {
        let shown = Array(tracks.prefix(Self.limit))
        return shown.enumerated().map { i, track in
            let item = CPListItem(text: track.displayName, detailText: track.album)
            item.handler = { [weak self] _, done in
                self?.play(tracks, at: i)
                done()
            }
            return item
        }
    }

    private func songsTemplate() -> CPListTemplate {
        let tracks = (hub.library?.tracks ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let t = CPListTemplate(title: String(localized: "歌曲"), sections: [CPListSection(items: trackItems(tracks))])
        t.emptyViewTitleVariants = [String(localized: "曲库是空的")]
        t.emptyViewSubtitleVariants = [String(localized: "在手机上把来源扫描进曲库")]
        return t
    }

    private func groupsTemplate(title: String, groups: [LibraryStore.Group]) -> CPListTemplate {
        let items = groups.prefix(Self.limit).map { group -> CPListItem in
            let item = CPListItem(text: group.name, detailText: String(localized: "\(group.tracks.count) 首"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                guard let self else { done(); return }
                let list = CPListTemplate(title: group.name, sections: [CPListSection(items: self.trackItems(group.tracks))])
                self.interface?.pushTemplate(list, animated: true, completion: nil)
                done()
            }
            return item
        }
        let t = CPListTemplate(title: title, sections: [CPListSection(items: Array(items))])
        t.emptyViewTitleVariants = [String(localized: "曲库是空的")]
        return t
    }

    private func playlistsTemplate() -> CPListTemplate {
        let urls = hub.library?.savedPlaylists() ?? []
        let items = urls.prefix(Self.limit).map { url -> CPListItem in
            let item = CPListItem(text: url.deletingPathExtension().lastPathComponent, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                guard let self, let tracks = try? self.hub.library?.loadPlaylist(url) else { done(); return }
                let list = CPListTemplate(title: url.deletingPathExtension().lastPathComponent, sections: [CPListSection(items: self.trackItems(tracks))])
                self.interface?.pushTemplate(list, animated: true, completion: nil)
                done()
            }
            return item
        }
        let t = CPListTemplate(title: String(localized: "播放列表"), sections: [CPListSection(items: Array(items))])
        t.emptyViewTitleVariants = [String(localized: "没有保存的播放列表")]
        return t
    }

    // MARK: 来源（逐级浏览文件夹）

    private func sourcesTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "来源"), sections: [])
        template.tabTitle = String(localized: "来源")
        template.tabImage = UIImage(systemName: "externaldrive.connected.to.line.below")
        let configs = hub.sources?.configs ?? []
        let items = configs.map { config -> CPListItem in
            let item = CPListItem(text: config.name, detailText: nil, image: UIImage(systemName: "externaldrive"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                guard let self, let source = self.hub.sources?.source(config.id) else { done(); return }
                self.openFolder(source, path: source.rootPath, title: config.name, done: done)
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
        template.emptyViewTitleVariants = [String(localized: "还没有来源")]
        template.emptyViewSubtitleVariants = [String(localized: "在手机上添加 NAS 或媒体服务器")]
        return template
    }

    /// 列出文件夹（网络来源要等一会儿，CarPlay 会在这一行上显示转圈）
    private func openFolder(_ source: any MediaSource, path: String, title: String, done: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            do {
                let entries = try await source.list(path: path).sortedForBrowsing()
                let folders = entries.filter { $0.kind == .directory }
                let files = entries.filter { $0.kind == .audio }
                let tracks = files.map { $0.makeTrack(sourceID: source.id) }
                var items: [CPListItem] = []
                if !files.isEmpty || !folders.isEmpty {
                    let playAll = CPListItem(text: String(localized: "播放全部"), detailText: nil, image: UIImage(systemName: "play.fill"))
                    playAll.handler = { [weak self] _, finish in
                        Task { @MainActor in
                            let all = (try? await source.collectTracks(path: path, maxDepth: 3, limit: 500)) ?? tracks
                            self?.play(all, at: 0)
                            finish()
                        }
                    }
                    items.append(playAll)
                }
                for folder in folders.prefix(Self.limit) {
                    let item = CPListItem(text: folder.name, detailText: nil, image: UIImage(systemName: "folder"))
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, finish in
                        self?.openFolder(source, path: folder.path, title: folder.name, done: finish)
                    }
                    items.append(item)
                }
                for (i, track) in tracks.prefix(Self.limit).enumerated() {
                    let item = CPListItem(text: track.displayName, detailText: track.album)
                    item.handler = { [weak self] _, finish in
                        self?.play(tracks, at: i)
                        finish()
                    }
                    items.append(item)
                }
                let list = CPListTemplate(title: title, sections: [CPListSection(items: items)])
                list.emptyViewTitleVariants = [String(localized: "这里没有音乐")]
                self?.interface?.pushTemplate(list, animated: true, completion: nil)
            } catch {
                let alert = CPAlertTemplate(titleVariants: [String(localized: "打开失败：\(error.localizedDescription)")], actions: [
                    CPAlertAction(title: String(localized: "好"), style: .cancel) { [weak self] _ in self?.interface?.dismissTemplate(animated: true, completion: nil) },
                ])
                self?.interface?.presentTemplate(alert, animated: true, completion: nil)
            }
            done()
        }
    }
}
#endif
