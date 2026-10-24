import Foundation
import MP9Sources
import Observation

/// 用户配置的来源列表（本机文件始终在第一位）
@MainActor
@Observable
public final class SourceStore {
    public private(set) var configs: [SourceConfig]
    @ObservationIgnored private var instances: [String: any MediaSource] = [:]
    private static let fileName = "sources.json"

    public init() {
        var saved = Storage.load([SourceConfig].self, from: Self.fileName) ?? []
        saved.removeAll { $0.id == SourceConfig.localID }
        configs = [.local] + saved
    }

    public func config(_ id: String) -> SourceConfig? { configs.first { $0.id == id } }

    public func source(_ id: String) -> (any MediaSource)? {
        if let s = instances[id] { return s }
        guard let config = config(id) else { return nil }
        let s = SourceFactory.make(config)
        instances[id] = s
        return s
    }

    /// 新增或更新；password 为 nil 表示不修改已保存的密码
    public func save(_ config: SourceConfig, password: String?) {
        if let password { CredentialStore.setPassword(password, for: config.id) }
        if let i = configs.firstIndex(where: { $0.id == config.id }) {
            configs[i] = config
        } else {
            configs.append(config)
        }
        instances[config.id] = nil
        persist()
    }

    public func remove(_ id: String) {
        guard id != SourceConfig.localID else { return }
        configs.removeAll { $0.id == id }
        instances[id] = nil
        CredentialStore.removeAll(for: id)
        persist()
    }

    public func move(from: IndexSet, to: Int) {
        var rest = Array(configs.dropFirst())
        let moving = from.compactMap { $0 > 0 ? configs[$0] : nil }
        rest.removeAll { c in moving.contains { $0.id == c.id } }
        let target = max(0, min(rest.count, to - 1))
        rest.insert(contentsOf: moving, at: target)
        configs = [configs[0]] + rest
        persist()
    }

    /// 令牌登录后重建实例
    public func invalidate(_ id: String) { instances[id] = nil }

    private func persist() {
        Storage.save(Array(configs.dropFirst()), to: Self.fileName)
    }
}
