#if DEBUG
import Foundation
import MP9Kit

/// 仅调试版：通过启动参数驱动界面，方便命令行截图和自测
/// -MP9Reset YES         删除所有来源（本机除外）并清空播放列表，用于 UI 测试
/// -MP9DemoPlay YES      把 Documents 里的音频加入播放列表并播放
/// -MP9Sheet <name>      打开 sources / library / skins / settings / menu
/// -MP9Skin <name>       切换到指定名称的皮肤
/// -MP9AddSource <base64>  添加一个来源（base64 编码的 SourceConfig JSON，可带 "password"；参数域会把 { 开头的值当 plist 解析，所以用 base64）
/// -MP9PlaySource <name> 递归收集该来源的曲目并播放
@MainActor
enum DebugHooks {
    static func run(_ app: AppModel) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "MP9Reset") {
            for config in app.sources.configs where config.id != SourceConfig.localID { app.sources.remove(config.id) }
            app.player.clear()
            app.skins.select(Skin.defaultSkin.id)
        }
        if let encoded = defaults.string(forKey: "MP9AddSource"), let data = Data(base64Encoded: encoded),
           var config = try? JSONDecoder().decode(SourceConfig.self, from: data) {
            let password = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["password"] as? String
            if app.sources.configs.contains(where: { $0.name == config.name }) {
                config.id = app.sources.configs.first { $0.name == config.name }!.id
            }
            app.sources.save(config, password: password)
        }
        if let name = defaults.string(forKey: "MP9Skin"), let entry = app.skins.entries.first(where: { $0.name == name }) {
            app.skins.select(entry.id)
        }
        if defaults.bool(forKey: "MP9DemoPlay") {
            Task {
                let tracks = (try? await LocalSource().collectTracks(path: "/")) ?? []
                if !tracks.isEmpty { app.player.setQueue(tracks, startAt: 0, autoplay: true) }
            }
        }
        if let name = defaults.string(forKey: "MP9PlaySource"),
           let config = app.sources.configs.first(where: { $0.name == name }),
           let source = app.sources.source(config.id) {
            Task {
                do {
                    let tracks = try await source.collectTracks(path: source.rootPath)
                    app.player.setQueue(tracks, startAt: 0, autoplay: true)
                } catch {
                    app.show("调试：\(error.localizedDescription)")
                }
            }
        }
        if let sheet = defaults.string(forKey: "MP9Sheet").flatMap(AppModel.Sheet.init(rawValue:)) {
            app.sheet = sheet
        }
    }
}
#endif
