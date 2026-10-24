import Foundation
import AmplayerSkin
import Observation

/// 皮肤管理：内置默认皮肤 + 用户导入的 .wsz
@MainActor
@Observable
public final class SkinManager {
    public struct Entry: Identifiable, Hashable {
        public var id: String
        public var name: String
        /// nil 表示内置
        public var file: URL?
    }

    public private(set) var entries: [Entry] = []
    public private(set) var current: Skin = Skin.defaultSkin
    public var lastError: String?

    @ObservationIgnored private var loaded: [String: Skin] = [:]
    private static let selectedKey = "amplayer.skin.selected"

    public static var skinsDirectory: URL {
        let url = Storage.supportDirectory.appendingPathComponent("Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public init() {
        loaded[Skin.defaultSkin.id] = Skin.defaultSkin
        reload()
        if let id = UserDefaults.standard.string(forKey: Self.selectedKey), id != current.id {
            select(id)
        }
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.skinsDirectory, includingPropertiesForKeys: nil)) ?? []
        let imported = files.filter { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }
            .map { Entry(id: "file:" + $0.lastPathComponent, name: $0.deletingPathExtension().lastPathComponent, file: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entries = [Entry(id: Skin.defaultSkin.id, name: Skin.defaultSkin.name, file: nil)] + imported
    }

    public func skin(for entry: Entry) -> Skin? {
        if let s = loaded[entry.id] { return s }
        guard let file = entry.file, let data = try? Data(contentsOf: file),
              let skin = try? Skin.load(wszData: data, id: entry.id, name: entry.name) else { return nil }
        loaded[entry.id] = skin
        return skin
    }

    public func select(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard let skin = skin(for: entry) else {
            lastError = "无法加载皮肤 \(entry.name)"
            return
        }
        current = skin
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
    }

    /// 导入 .wsz（复制到 App 目录并校验）
    @discardableResult
    public func importSkin(from url: URL) throws -> Entry {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        _ = try Skin.load(wszData: data, id: "check", name: "check")
        var name = url.deletingPathExtension().lastPathComponent
        var target = Self.skinsDirectory.appendingPathComponent(name + ".wsz")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            name = "\(url.deletingPathExtension().lastPathComponent) \(n)"
            target = Self.skinsDirectory.appendingPathComponent(name + ".wsz")
            n += 1
        }
        try data.write(to: target)
        reload()
        let entry = entries.first { $0.file == target } ?? Entry(id: "file:" + target.lastPathComponent, name: name, file: target)
        select(entry.id)
        return entry
    }

    public func delete(_ entry: Entry) {
        guard let file = entry.file else { return }
        try? FileManager.default.removeItem(at: file)
        loaded[entry.id] = nil
        if current.id == entry.id { select(Skin.defaultSkin.id) }
        reload()
    }
}
