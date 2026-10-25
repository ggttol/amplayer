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

/// CarPlay 车机界面：播放列表、曲库、来源三个标签页，加系统的“正在播放”页面。
/// 用 Info.plist 的 CPTemplateApplicationSceneSessionRoleApplication 场景启动。
@MainActor
public final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interface: CPInterfaceController?
    private let queueTemplate = CPListTemplate(title: "播放列表", sections: [])
    private var observing = false

    private var hub: CarPlayHub { .shared }

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        queueTemplate.tabTitle = "播放列表"
        queueTemplate.tabImage = UIImage(systemName: "list.bullet")
        queueTemplate.emptyViewTitleVariants = ["播放列表是空的"]
        queueTemplate.emptyViewSubtitleVariants = ["在“曲库”或“来源”里选歌"]
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
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: 正在播放

    private func configureNowPlaying() {
        let now = CPNowPlayingTemplate.shared
        now.isUpNextButtonEnabled = true
        now.upNextTitle = "播放列表"
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
        now.updateNowPlayingButtons([shuffle, repeatButton])
    }

    public nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            guard let interface = self.interface else { return }
            let list = CPListTemplate(title: "播放列表", sections: self.queueTemplate.sections)
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
        guard let player = hub.player else { return }
        let tracks = Array(player.queue.tracks.prefix(Self.limit))
        let current = player.queue.currentIndex
        let items = tracks.enumerated().map { i, track -> CPListItem in
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
        queueTemplate.updateSections([CPListSection(items: items)])
    }

    private static var limit: Int { max(12, min(CPListTemplate.maximumItemCount, 500)) }

    // MARK: 曲库

    private func libraryTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "曲库", sections: [])
        template.tabTitle = "曲库"
        template.tabImage = UIImage(systemName: "music.note.list")
        let rows: [(String, String, () -> CPListTemplate?)] = [
            ("歌曲", "music.note", { [weak self] in self?.songsTemplate() }),
            ("艺术家", "music.mic", { [weak self] in self?.groupsTemplate(title: "艺术家", groups: self?.hub.library?.artists() ?? []) }),
            ("专辑", "square.stack", { [weak self] in self?.groupsTemplate(title: "专辑", groups: self?.hub.library?.albums() ?? []) }),
            ("播放列表", "list.bullet.rectangle", { [weak self] in self?.playlistsTemplate() }),
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
        let shuffleAll = CPListItem(text: "随机播放全部", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffleAll.handler = { [weak self] _, done in
            if let self, let tracks = self.hub.library?.tracks, !tracks.isEmpty {
                self.hub.player?.shuffle = true
                self.play(tracks, at: Int.random(in: 0..<tracks.count))
            }
            done()
        }
        items.insert(shuffleAll, at: 0)
        template.updateSections([CPListSection(items: items)])
        template.emptyViewTitleVariants = ["曲库是空的"]
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
        let t = CPListTemplate(title: "歌曲", sections: [CPListSection(items: trackItems(tracks))])
        t.emptyViewTitleVariants = ["曲库是空的"]
        t.emptyViewSubtitleVariants = ["在手机上把来源扫描进曲库"]
        return t
    }

    private func groupsTemplate(title: String, groups: [LibraryStore.Group]) -> CPListTemplate {
        let items = groups.prefix(Self.limit).map { group -> CPListItem in
            let item = CPListItem(text: group.name, detailText: "\(group.tracks.count) 首")
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
        t.emptyViewTitleVariants = ["曲库是空的"]
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
        let t = CPListTemplate(title: "播放列表", sections: [CPListSection(items: Array(items))])
        t.emptyViewTitleVariants = ["没有保存的播放列表"]
        return t
    }

    // MARK: 来源（逐级浏览文件夹）

    private func sourcesTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "来源", sections: [])
        template.tabTitle = "来源"
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
        template.emptyViewTitleVariants = ["还没有来源"]
        template.emptyViewSubtitleVariants = ["在手机上添加 NAS 或媒体服务器"]
        return template
    }

    /// 列出文件夹（网络来源要等一会儿，CarPlay 会在这一行上显示转圈）
    private func openFolder(_ source: any MediaSource, path: String, title: String, done: @escaping () -> Void) {
        Task { @MainActor in
            do {
                let entries = try await source.list(path: path).sortedForBrowsing()
                let folders = entries.filter { $0.kind == .directory }
                let files = entries.filter { $0.kind == .audio }
                let tracks = files.map { $0.makeTrack(sourceID: source.id) }
                var items: [CPListItem] = []
                if !files.isEmpty || !folders.isEmpty {
                    let playAll = CPListItem(text: "播放全部", detailText: nil, image: UIImage(systemName: "play.fill"))
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
                list.emptyViewTitleVariants = ["这里没有音乐"]
                interface?.pushTemplate(list, animated: true, completion: nil)
            } catch {
                let alert = CPAlertTemplate(titleVariants: ["打开失败：\(error.localizedDescription)"], actions: [
                    CPAlertAction(title: "好", style: .cancel) { [weak self] _ in self?.interface?.dismissTemplate(animated: true, completion: nil) },
                ])
                interface?.presentTemplate(alert, animated: true, completion: nil)
            }
            done()
        }
    }
}
#endif
