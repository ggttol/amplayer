import AuthenticationServices
import AmplayerKit
import SwiftUI

/// 来源列表 + 局域网发现
struct SourcesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SourceConfig?
    @State private var newPassword: String?

    var body: some View {
        NavigationStack {
            List {
                Section("我的来源") {
                    ForEach(app.sources.configs) { config in
                        NavigationLink(value: BrowseTarget(sourceID: config.id, path: nil, title: config.name)) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(config.name)
                                    Text(config.kind == .local ? "“文件”App › Amplayer" : (config.url.isEmpty ? config.kind.title : config.url))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: config.kind.symbol)
                            }
                        }
                        .swipeActions {
                            if config.id != SourceConfig.localID {
                                Button("删除", role: .destructive) {
                                    app.sources.remove(config.id)
                                    app.library.remove(sourceID: config.id)
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

                Section {
                    if app.discovery.found.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在搜索局域网中的 SMB、WebDAV、DLNA 设备…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(app.discovery.found) { found in
                        Button {
                            editing = SourceConfig(kind: found.kind, name: found.name, url: found.url)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(found.name)
                                    Text("\(found.kind.title) · \(found.url)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: found.kind.symbol)
                            }
                        }
                    }
                } header: {
                    Text("局域网")
                } footer: {
                    Text("群晖、威联通、飞牛等 NAS 可以用 SMB、WebDAV、DLNA 添加；群晖还可以用 Audio Station 直接浏览曲库。")
                }
            }
            .navigationTitle("来源")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BrowseTarget.self) { target in
                BrowserView(target: target)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(SourceKind.allCases.filter { $0 != .local }) { kind in
                            Button(kind.title, systemImage: kind.symbol) {
                                editing = SourceConfig(kind: kind, name: kind.title)
                            }
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { config in
                SourceEditorView(config: config, isNew: app.sources.config(config.id) == nil) { saved, password in
                    // 由父视图关闭编辑表单，再保存：在嵌套 sheet 里一边改数据一边 dismiss，
                    // 会把外层“来源”sheet 也一起关掉
                    editing = nil
                    Task { @MainActor in app.sources.save(saved, password: password) }
                }
            }
            .onAppear { app.discovery.start() }
            .onDisappear { app.discovery.stop() }
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
    @Environment(\.webAuthenticationSession) private var webAuth
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
                    TextField("名称", text: $config.name)
                    if config.kind.needsURL {
                        TextField(config.kind.urlPlaceholder, text: $config.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(config.kind.title)
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
                if config.kind.usesOAuth {
                    Section {
                        Button("登录\(config.kind.title)") { Task { await oauthLogin() } }
                            .disabled(!oauthConfigured)
                    } footer: {
                        Text(oauthConfigured
                             ? "将在系统浏览器中打开\(config.kind.title)官方授权页面。"
                             : "该版本未配置\(config.kind.title)开放平台的 AppKey（见 Config/Secrets.xcconfig.example）。也可以用 Alist / OpenList 把网盘转成 WebDAV 再添加。")
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
            .navigationTitle(isNew ? "添加来源" : "编辑来源")
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
        case .aliyun, .baidu: "通过官方开放平台授权，只读取文件。"
        case .local: ""
        }
    }

    private var oauthConfigured: Bool {
        switch config.kind {
        case .aliyun: AliyunDriveSource.credentials.isConfigured
        case .baidu: BaiduPanSource.credentials.isConfigured
        default: false
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

    private func oauthLogin() async {
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        let url: URL
        let redirect: String
        switch config.kind {
        case .aliyun:
            url = AliyunDriveSource.authorizeURL(state: state, codeVerifier: verifier)
            redirect = AliyunDriveSource.credentials.redirectURI
        case .baidu:
            url = BaiduPanSource.authorizeURL(state: state, codeVerifier: verifier)
            redirect = BaiduPanSource.credentials.redirectURI
        default:
            return
        }
        let scheme = URL(string: redirect)?.scheme ?? "amplayer"
        do {
            let callback = try await webAuth.authenticate(using: url, callbackURLScheme: scheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value ?? state == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                testOK = false
                testResult = "授权被取消或失败"
                return
            }
            let token = try await (config.kind == .aliyun
                ? AliyunDriveSource.exchange(code: code, codeVerifier: verifier)
                : BaiduPanSource.exchange(code: code, codeVerifier: verifier))
            CredentialStore.setToken(try JSONEncoder().encode(token), for: config.id)
            app.sources.invalidate(config.id)
            testOK = true
            testResult = "登录成功，保存后即可浏览"
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}
