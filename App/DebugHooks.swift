#if DEBUG
import Foundation
import AmplayerKit

/// 仅调试版：通过启动参数驱动界面，方便命令行截图和自测
/// -AmplayerReset YES         删除所有来源（本机除外）并清空播放列表，用于 UI 测试
/// -AmplayerDemoPlay YES      把 Documents 里的音频加入播放列表并播放
/// -AmplayerSheet <name>      打开 sources / library / skins / settings / menu
/// -AmplayerSkin <name>       切换到指定名称的皮肤
/// -AmplayerAddSource <base64>  添加一个来源（base64 编码的 SourceConfig JSON，可带 "password"；参数域会把 { 开头的值当 plist 解析，所以用 base64）
/// -AmplayerPlaySource <name> 递归收集该来源的曲目并播放（-AmplayerPlayPath 指定起始目录）
@MainActor
enum DebugHooks {
    static func run(_ app: AppModel) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "AmplayerReset") {
            for config in app.sources.configs where config.id != SourceConfig.localID { app.sources.remove(config.id) }
            app.player.clear()
            app.skins.select(Skin.defaultSkin.id)
        }
        if let encoded = defaults.string(forKey: "AmplayerAddSource"), let data = Data(base64Encoded: encoded),
           var config = try? JSONDecoder().decode(SourceConfig.self, from: data) {
            let password = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["password"] as? String
            if app.sources.configs.contains(where: { $0.name == config.name }) {
                config.id = app.sources.configs.first { $0.name == config.name }!.id
            }
            app.sources.save(config, password: password)
        }
        if let name = defaults.string(forKey: "AmplayerSkin"), let entry = app.skins.entries.first(where: { $0.name == name }) {
            app.skins.select(entry.id)
        }
        if defaults.bool(forKey: "AmplayerDemoPlay") {
            Task {
                let tracks = (try? await LocalSource().collectTracks(path: "/")) ?? []
                if !tracks.isEmpty { app.player.setQueue(tracks, startAt: 0, autoplay: true) }
            }
        }
        if let name = defaults.string(forKey: "AmplayerPlaySource"),
           let config = app.sources.configs.first(where: { $0.name == name }),
           let source = app.sources.source(config.id) {
            Task {
                do {
                    let start = defaults.string(forKey: "AmplayerPlayPath") ?? source.rootPath
                    let tracks = try await source.collectTracks(path: start, maxDepth: 2, limit: 200)
                    app.player.setQueue(tracks, startAt: 0, autoplay: true)
                } catch {
                    app.show("调试：\(error.localizedDescription)")
                }
            }
        }
        if let sheet = defaults.string(forKey: "AmplayerSheet").flatMap(AppModel.Sheet.init(rawValue:)) {
            app.sheet = sheet
        }
    }
}
#endif
