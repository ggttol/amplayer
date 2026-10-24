import Foundation
import AmplayerKit
import Observation
import SwiftUI

/// 全局状态
@MainActor
@Observable
final class AppModel {
    let sources = SourceStore()
    let library = LibraryStore()
    let skins = SkinManager()
    let discovery = LANDiscovery()
    let player: PlayerController

    enum Sheet: String, Identifiable {
        case sources, library, skins, settings
        var id: String { rawValue }
    }

    enum VisualizerMode: Int { case spectrum, oscilloscope, off }

    var sheet: Sheet?
    var showEqualizer: Bool {
        didSet {
            UserDefaults.standard.set(showEqualizer, forKey: "amplayer.showEQ")
            if showEqualizer { miniRestore = nil }
        }
    }
    var showPlaylist: Bool {
        didSet {
            UserDefaults.standard.set(showPlaylist, forKey: "amplayer.showPL")
            if showPlaylist { miniRestore = nil }
        }
    }
    var visualizerMode: VisualizerMode { didSet { UserDefaults.standard.set(visualizerMode.rawValue, forKey: "amplayer.vis") } }
    var showRemainingTime = false
    /// 播放列表窗口改为显示歌词
    var showLyrics: Bool { didSet { UserDefaults.standard.set(showLyrics, forKey: "amplayer.showLyrics") } }
    /// 播放列表里选中的行（tracks 下标）
    var selection: Set<Int> = []
    /// 播放列表多选模式：开着时点行是勾选，否则点行直接播放
    var isSelecting = false
    var showSideMenu = false

    /// 迷你模式：只留主窗口；记住进入前哪些窗口开着
    private var miniRestore: (eq: Bool, pl: Bool)?
    var isMiniMode: Bool { miniRestore != nil }

    func toggleMiniMode() {
        if let restore = miniRestore {
            miniRestore = nil
            showEqualizer = restore.eq
            showPlaylist = restore.pl
        } else if showEqualizer || showPlaylist {
            miniRestore = (showEqualizer, showPlaylist)
            showEqualizer = false
            showPlaylist = false
            show("迷你模式，再点一次恢复")
        } else {
            showEqualizer = true
            showPlaylist = true
        }
    }

    /// 标题栏“□”：换下一套皮肤
    func nextSkin() {
        let entries = skins.entries
        guard !entries.isEmpty else { return }
        let i = entries.firstIndex { $0.id == skins.current.id } ?? -1
        let next = entries[(i + 1) % entries.count]
        skins.select(next.id)
        show("皮肤：\(next.name)")
    }

    /// 退出多选并清空选择
    func endSelection() {
        selection = []
        isSelecting = false
    }
    var isImportingFiles = false
    var toast: String?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["amplayer.showEQ": true, "amplayer.showPL": true])
        showEqualizer = defaults.bool(forKey: "amplayer.showEQ")
        showPlaylist = defaults.bool(forKey: "amplayer.showPL")
        showLyrics = defaults.bool(forKey: "amplayer.showLyrics")
        visualizerMode = VisualizerMode(rawValue: defaults.integer(forKey: "amplayer.vis")) ?? .spectrum
        player = PlayerController(sources: sources)
        player.onTrackUpdated = { [weak library] track in library?.update(track) }
        let limit = defaults.object(forKey: "amplayer.cacheLimit") as? Int64 ?? 2 * 1024 * 1024 * 1024
        Task { await AudioCache.shared.setLimit(limit) }
    }

    var skin: Skin { skins.current }

    /// 首次启动：把内置示例曲（原创合成）放进“本机文件 › 示例 Demo”，播放列表为空时加进去（不自动播放）
    func installDemoContentIfNeeded() {
        let key = "amplayer.demoInstalled"
        guard !UserDefaults.standard.bool(forKey: key),
              let files = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Demo"), !files.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        let folder = LocalSource.defaultRoot.appendingPathComponent("示例 Demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let target = folder.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: file, to: target) }
        }
        guard player.queue.isEmpty else { return }
        Task {
            let tracks = (try? await LocalSource().collectTracks(path: "/示例 Demo")) ?? []
            if player.queue.isEmpty, !tracks.isEmpty { player.setQueue(tracks, startAt: 0, autoplay: false) }
        }
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }

    /// 从“文件”App 导入音频：复制到 Documents/Imported 后加入播放列表
    func importAudioFiles(_ urls: [URL], play: Bool) {
        let fm = FileManager.default
        let folder = LocalSource.importsFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var tracks: [Track] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var target = folder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                if !fm.contentsEqual(atPath: target.path, andPath: url.path) {
                    target = folder.appendingPathComponent("\(UUID().uuidString.prefix(4))-\(url.lastPathComponent)")
                }
            }
            if !fm.fileExists(atPath: target.path) {
                do { try fm.copyItem(at: url, to: target) } catch { show("导入失败：\(error.localizedDescription)"); continue }
            }
            tracks.append(Track(sourceID: SourceConfig.localID, path: "/Imported/\(target.lastPathComponent)", title: Track.title(fromFileName: target.lastPathComponent)))
        }
        guard !tracks.isEmpty else { return }
        library.add(tracks)
        player.enqueue(tracks, playIfIdle: play)
        show("已添加 \(tracks.count) 首")
    }

    /// 处理“用 Amplayer 打开”的文件：皮肤或播放列表
    func open(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "wsz" || ext == "zip" {
            do {
                let entry = try skins.importSkin(from: url)
                show("已切换到皮肤 \(entry.name)")
            } catch {
                show("不是有效的皮肤文件")
            }
        } else if ["m3u", "m3u8", "pls"].contains(ext) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let tracks = try? library.loadPlaylist(url), !tracks.isEmpty {
                player.setQueue(tracks, startAt: 0, autoplay: false)
                show("已载入 \(tracks.count) 首")
            }
        } else if AudioFormats.isPlayable(url.lastPathComponent) {
            importAudioFiles([url], play: true)
        }
    }
}
