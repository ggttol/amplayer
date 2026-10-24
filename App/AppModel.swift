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
        case sources, library, skins, settings, menu
        var id: String { rawValue }
    }

    enum VisualizerMode: Int { case spectrum, oscilloscope, off }

    var sheet: Sheet?
    var showEqualizer: Bool { didSet { UserDefaults.standard.set(showEqualizer, forKey: "amplayer.showEQ") } }
    var showPlaylist: Bool { didSet { UserDefaults.standard.set(showPlaylist, forKey: "amplayer.showPL") } }
    var visualizerMode: VisualizerMode { didSet { UserDefaults.standard.set(visualizerMode.rawValue, forKey: "amplayer.vis") } }
    var showRemainingTime = false
    /// 播放列表里选中的行（tracks 下标）
    var selection: Set<Int> = []
    var isImportingFiles = false
    var toast: String?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["amplayer.showEQ": true, "amplayer.showPL": true])
        showEqualizer = defaults.bool(forKey: "amplayer.showEQ")
        showPlaylist = defaults.bool(forKey: "amplayer.showPL")
        visualizerMode = VisualizerMode(rawValue: defaults.integer(forKey: "amplayer.vis")) ?? .spectrum
        player = PlayerController(sources: sources)
        player.onTrackUpdated = { [weak library] track in library?.update(track) }
        let limit = defaults.object(forKey: "amplayer.cacheLimit") as? Int64 ?? 2 * 1024 * 1024 * 1024
        Task { await AudioCache.shared.setLimit(limit) }
    }

    var skin: Skin { skins.current }

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
