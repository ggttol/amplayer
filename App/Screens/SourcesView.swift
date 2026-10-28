import AmplayerKit
import SwiftUI

/// 音乐来源列表 + 局域网发现；右上角“+”进入“添加音乐来源”
struct SourcesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SourceConfig?
    @State private var searchTimedOut = false
    @State private var path = NavigationPath()

    private enum Route: Hashable { case add }

    /// 已经添加过的不再出现在“局域网”里
    private var discovered: [LANDiscovery.Found] {
        let added = Set(app.sources.configs.map { normalized($0.url) })
        return app.discovery.found.filter { !added.contains(normalized($0.url)) }
    }

    private func normalized(_ url: String) -> String {
        url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("我的音乐来源") {
                    ForEach(app.sources.configs) { config in
                        NavigationLink(value: BrowseTarget(sourceID: config.id, path: nil, title: config.name)) {
                            SourceRow(kind: config.kind, title: config.name,
                                      detail: config.kind == .local ? "“文件”App › Amplayer" : (config.url.isEmpty ? config.kind.title : config.url))
                        }
                        .swipeActions {
                            if config.id != SourceConfig.localID {
                                Button("删除", role: .destructive) {
                                    app.sources.remove(config.id)
                                    app.library.remove(sourceID: config.id)
                                    app.player.removeTracks(fromSource: config.id)
                                }
                                Button("编辑") { editing = config }.tint(.blue)
                            }
                        }
                        .contextMenu {
                            if config.id != SourceConfig.localID {
                                Button("编辑", systemImage: "pencil") { editing = config }
                            }
                            Button("扫描到曲库", systemImage: "square.and.arrow.down.on.square") {
                                if let s = app.sources.source(config.id) {
                                    app.library.scan(s, path: s.rootPath)
                                    app.show("开始扫描 \(config.name)")
                                }
                            }
                        }
                    }
                }

                // 只有本机文件时，给一个醒目的添加入口
                if app.sources.configs.count <= 1 {
                    Section {
                        Button { path.append(Route.add) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("添加音乐来源").font(.headline).foregroundStyle(.primary)
                                    Text("NAS、Alist 网盘、Navidrome、Jellyfin 等").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    if discovered.isEmpty {
                        if searchTimedOut {
                            Text(app.discovery.found.isEmpty ? "没有发现局域网设备，可以点右上角 + 手动添加。" : "发现的设备都已经添加过了。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在搜索局域网中的 NAS 和媒体服务器…").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(discovered) { found in
                        Button {
                            editing = SourceConfig(kind: found.kind, name: found.name, url: found.url)
                        } label: {
                            HStack {
                                SourceRow(kind: found.kind, title: found.name, detail: "\(found.kind.title) · \(found.url)")
                                Spacer()
                                Text("添加").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("局域网")
                } footer: {
                    Text("同一 Wi‑Fi 下的 NAS、电脑共享和媒体服务器会自动出现在这里。")
                }
            }
            .navigationTitle("音乐来源")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BrowseTarget.self) { target in
                // Subsonic / Navidrome 用专门的曲库界面，其余按目录浏览
                if target.path == nil, app.sources.config(target.sourceID)?.kind == .subsonic {
                    SubsonicHomeView(sourceID: target.sourceID, title: target.title)
                } else {
                    BrowserView(target: target)
                }
            }
            .navigationDestination(for: Route.self) { _ in
                AddSourceView(discovered: discovered) { editing = $0 }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { path.append(Route.add) } label: { Label("添加", systemImage: "plus") }
                }
            }
            .sheet(item: $editing) { config in
                SourceEditorView(config: config, isNew: app.sources.config(config.id) == nil) { saved, password in
                    // 由父视图关闭编辑表单，再保存：在嵌套 sheet 里一边改数据一边 dismiss，
                    // 会把外层“音乐来源”sheet 也一起关掉
                    editing = nil
                    if !path.isEmpty { path.removeLast(path.count) }
                    Task { @MainActor in app.sources.save(saved, password: password) }
                }
            }
            .onAppear {
                app.discovery.start()
                #if DEBUG
                // 截图用：-DebugAddSource YES 直接打开“添加音乐来源”
                if UserDefaults.standard.bool(forKey: "DebugAddSource"), path.isEmpty { path.append(Route.add) }
                if let name = UserDefaults.standard.string(forKey: "DebugBrowseSource"), path.isEmpty,
                   let config = app.sources.configs.first(where: { $0.name == name }) {
                    path.append(BrowseTarget(sourceID: config.id, path: nil, title: config.name))
                }
                #endif
            }
            .task {
                try? await Task.sleep(for: .seconds(8))
                searchTimedOut = true
            }
            .onDisappear { app.discovery.stop() }
        }
    }
}

/// 添加音乐来源：按用途分组的卡片
struct AddSourceView: View {
    let discovered: [LANDiscovery.Found]
    let onPick: (SourceConfig) -> Void

    private let groups: [(title: String, detail: String, kinds: [SourceKind])] = [
        ("NAS 与网盘", "家里 NAS 上的音乐文件夹，或者通过 Alist / OpenList 接入的网盘", [.synology, .smb, .webdav]),
        ("音乐服务器", "按艺术家、专辑浏览，带封面和歌词", [.subsonic, .jellyfin, .emby]),
        ("局域网媒体", "电视盒子、路由器、NAS 自带的媒体服务，不用账号", [.dlna]),
    ]
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !discovered.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("在局域网中发现", "点一下，填上账号就能用")
                        ForEach(discovered) { found in
                            Button {
                                onPick(SourceConfig(kind: found.kind, name: found.name, url: found.url))
                            } label: {
                                HStack(spacing: 12) {
                                    SourceIcon(kind: found.kind, size: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(found.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text("\(found.kind.title) · \(found.url)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                                }
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        heading(group.title, group.detail)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(group.kinds) { card($0) }
                        }
                    }
                }
                Label("所有账号密码只保存在这台设备的钥匙串里，App 直接连接你的服务器。", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("添加音乐来源")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private func card(_ kind: SourceKind) -> some View {
        Button {
            onPick(SourceConfig(kind: kind, name: kind.title))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                SourceIcon(kind: kind, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.cardTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(kind.blurb).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(kind.tint.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

/// 来源行：彩色图标 + 名称 + 地址
struct SourceRow: View {
    let kind: SourceKind
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(kind: kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 设置 App 风格的圆角彩色图标
struct SourceIcon: View {
    let kind: SourceKind
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [kind.tint.opacity(0.8), kind.tint], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

extension SourceKind {
    var tint: Color {
        switch self {
        case .local: Color(red: 0.25, green: 0.55, blue: 0.98)
        case .synology: Color(red: 0.13, green: 0.40, blue: 0.80)
        case .smb: Color(red: 0.36, green: 0.36, blue: 0.86)
        case .webdav: Color(red: 0.10, green: 0.66, blue: 0.68)
        case .subsonic: Color(red: 0.96, green: 0.52, blue: 0.13)
        case .jellyfin: Color(red: 0.62, green: 0.33, blue: 0.85)
        case .emby: Color(red: 0.30, green: 0.69, blue: 0.31)
        case .dlna: Color(red: 0.92, green: 0.31, blue: 0.52)
        }
    }

    /// 卡片上的短名称
    var cardTitle: String {
        switch self {
        case .webdav: "WebDAV / Alist"
        case .smb: "SMB 共享"
        case .subsonic: "Navidrome"
        case .synology: "群晖 NAS"
        case .dlna: "DLNA / UPnP"
        default: title
        }
    }

    var blurb: String {
        switch self {
        case .local: "“文件”App 里的音乐"
        case .synology: "支持 QuickConnect，在外也能连"
        case .smb: "电脑共享文件夹、各品牌 NAS"
        case .webdav: "Alist / OpenList 网盘、NAS WebDAV"
        case .subsonic: "Subsonic、Airsonic、Gonic 等"
        case .jellyfin: "Jellyfin 里的音乐库"
        case .emby: "Emby 里的音乐库"
        case .dlna: "自动发现，免登录"
        }
    }
}

struct BrowseTarget: Hashable {
    var sourceID: String
    var path: String?
    var title: String
}

/// 添加 / 编辑来源
struct SourceEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var config: SourceConfig
    let isNew: Bool
    let onSave: (SourceConfig, String?) -> Void
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        SourceIcon(kind: config.kind, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(config.kind.title).font(.headline)
                            Text(config.kind.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                Section {
                    TextField("名称", text: $config.name)
                    if config.kind.needsURL {
                        TextField(config.kind.urlPlaceholder, text: $config.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text(hint)
                }
                if config.kind.needsCredentials {
                    Section("账号") {
                        TextField(config.kind == .smb ? "用户名（留空为访客）" : "用户名", text: $config.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(isNew ? "密码" : "密码（留空则不修改）", text: $password)
                    }
                }
                if config.kind.needsURL && config.kind != .smb {
                    Section {
                        Toggle("信任自签名证书", isOn: $config.allowInsecureTLS)
                    } footer: {
                        Text("NAS 的 HTTPS 常用自签名证书；仅在局域网或你信任的服务器上开启。")
                    }
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isNew ? "添加音乐来源" : "编辑音乐来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(config, password.isEmpty ? (isNew ? "" : nil) : password)
                    }
                    .disabled(config.name.isEmpty || (config.kind.needsURL && config.url.isEmpty))
                }
            }
        }
    }

    private var hint: String {
        switch config.kind {
        case .webdav: "Alist / OpenList 的地址形如 http://IP:5244/dav；群晖 WebDAV Server 默认端口 5005（HTTP）/ 5006（HTTPS）。"
        case .smb: "可写成 smb://IP 浏览全部共享，或 smb://IP/共享名 直接进入。"
        case .subsonic: "Navidrome、Airsonic、Gonic、Ampache 等，填服务器根地址。"
        case .jellyfin: "填 Jellyfin 服务器地址，例如 http://IP:8096。"
        case .emby: "填 Emby 服务器地址，部分安装需要带 /emby 后缀。"
        case .synology: "填 DSM 地址（例如 https://IP:5001、DDNS 域名），或直接填 QuickConnect ID，会自动选择局域网或外网线路。可浏览所有共享文件夹；装了 Audio Station 并建好索引时，还会显示专辑与播放列表。不支持开启了两步验证的账号。"
        case .dlna: "填媒体服务器的设备描述地址；一般在上方“局域网”里自动发现即可。"
        case .local: ""
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let pw = password.isEmpty ? CredentialStore.password(for: config.id) : password
        let source = SourceFactory.make(config, password: pw)
        do {
            try await source.testConnection()
            let items = try await source.list(path: source.rootPath)
            testOK = true
            testResult = "连接成功，根目录有 \(items.count) 项"
            if let syno = source as? SynologySource, syno.quickConnectID != nil, let address = try? await syno.connectedAddress() {
                testResult! += "\n经 QuickConnect 连接到 \(address.host ?? "")"
            }
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}
