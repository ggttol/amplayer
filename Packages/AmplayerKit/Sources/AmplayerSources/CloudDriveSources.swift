import CryptoKit
import Foundation
import AmplayerCore

/// 网盘 OAuth 令牌（存 Keychain）
public struct OAuthToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date().addingTimeInterval(expiresIn - 60)
    }

    public var isExpired: Bool { Date() >= expiresAt }

    static func load(_ sourceID: String) -> OAuthToken? {
        CredentialStore.token(for: sourceID).flatMap { try? JSONDecoder().decode(OAuthToken.self, from: $0) }
    }

    func save(_ sourceID: String) {
        CredentialStore.setToken(try? JSONEncoder().encode(self), for: sourceID)
    }
}

/// 网盘开放平台的应用凭据，来自 Info.plist（由 xcconfig 注入，不写死在代码里）
public struct CloudAppCredentials: Sendable {
    public var clientID: String
    public var clientSecret: String
    public var redirectURI: String

    public init(clientID: String, clientSecret: String = "", redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    public var isConfigured: Bool { !clientID.isEmpty }

    public static func fromBundle(prefix: String) -> CloudAppCredentials {
        let info = Bundle.main.infoDictionary ?? [:]
        return CloudAppCredentials(
            clientID: (info["\(prefix)ClientID"] as? String) ?? "",
            clientSecret: (info["\(prefix)ClientSecret"] as? String) ?? "",
            redirectURI: (info["\(prefix)RedirectURI"] as? String) ?? "amplayer://oauth/\(prefix.lowercased())"
        )
    }
}

/// OAuth 授权流程（PKCE）。界面层用 ASWebAuthenticationSession 打开 authorizeURL，拿回 code 后调用 exchange。
public protocol OAuthCloudSource: MediaSource {
    static var credentials: CloudAppCredentials { get }
    static func authorizeURL(state: String, codeVerifier: String) -> URL
    static func exchange(code: String, codeVerifier: String) async throws -> OAuthToken
}

public enum PKCE {
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 阿里云盘

/// 阿里云盘开放平台（openapi.alipan.com）。路径：目录为 file_id，根为 "root"。
public final class AliyunDriveSource: OAuthCloudSource, @unchecked Sendable {
    public let config: SourceConfig
    private let http = HTTPClient.shared
    private let lock = NSLock()
    private var driveID: String?
    private static let api = URL(string: "https://openapi.alipan.com")!

    public static var credentials: CloudAppCredentials { .fromBundle(prefix: "AmplayerAliyun") }

    public init(config: SourceConfig) { self.config = config }

    public var rootPath: String { "root" }

    public static func authorizeURL(state: String, codeVerifier: String) -> URL {
        api.appendingPathComponent("oauth/authorize").appendingQuery([
            ("client_id", credentials.clientID), ("redirect_uri", credentials.redirectURI),
            ("scope", "user:base,file:all:read"), ("response_type", "code"), ("state", state),
            ("code_challenge", PKCE.challenge(for: codeVerifier)), ("code_challenge_method", "S256"),
        ])
    }

    public static func exchange(code: String, codeVerifier: String) async throws -> OAuthToken {
        var body: [String: Any] = [
            "client_id": credentials.clientID, "grant_type": "authorization_code", "code": code, "code_verifier": codeVerifier,
        ]
        if !credentials.clientSecret.isEmpty { body["client_secret"] = credentials.clientSecret }
        return try await tokenRequest(body)
    }

    private static func tokenRequest(_ body: [String: Any]) async throws -> OAuthToken {
        var request = URLRequest(url: api.appendingPathComponent("oauth/access_token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await HTTPClient.shared.json(for: request)
        guard let access = json.string("access_token") else {
            throw SourceError.authenticationFailed(json.string("message"))
        }
        return OAuthToken(accessToken: access, refreshToken: json.string("refresh_token"), expiresIn: json.double("expires_in") ?? 7200)
    }

    public func list(path: String) async throws -> [SourceItem] {
        let drive = try await defaultDrive()
        var items: [SourceItem] = []
        var marker: String?
        repeat {
            var body: [String: Any] = ["drive_id": drive, "parent_file_id": path == "/" ? "root" : path, "limit": 100, "order_by": "name"]
            if let marker { body["marker"] = marker }
            let json = try await post("adrive/v1.0/openFile/list", body)
            for f in json.array("items") {
                guard let id = f.string("file_id"), let name = f.string("name") else { continue }
                if f.string("type") == "folder" {
                    items.append(SourceItem(path: id, name: name, kind: .directory))
                } else {
                    items.append(SourceItem(path: id, name: name, kind: .audio, size: f.int("size").map(Int64.init), fileExtension: f.string("file_extension")))
                }
            }
            marker = json.string("next_marker").flatMap { $0.isEmpty ? nil : $0 }
        } while marker != nil
        return items
    }

    public func download(path: String, to destination: URL) async throws {
        let drive = try await defaultDrive()
        let json = try await post("adrive/v1.0/openFile/getDownloadUrl", ["drive_id": drive, "file_id": path])
        guard let link = json.string("url"), let url = URL(string: link) else { throw SourceError.protocolError("未拿到下载地址") }
        try await http.download(URLRequest(url: url), to: destination)
    }

    private func defaultDrive() async throws -> String {
        if let id = lock.withLock({ driveID }) { return id }
        let json = try await post("adrive/v1.0/user/getDriveInfo", [:])
        guard let id = json.string("resource_drive_id") ?? json.string("default_drive_id") else {
            throw SourceError.protocolError("未拿到 drive_id")
        }
        lock.withLock { driveID = id }
        return id
    }

    private func accessToken() async throws -> String {
        guard var token = OAuthToken.load(config.id) else { throw SourceError.notConfigured("请先登录阿里云盘") }
        if token.isExpired, let refresh = token.refreshToken {
            var body: [String: Any] = ["client_id": Self.credentials.clientID, "grant_type": "refresh_token", "refresh_token": refresh]
            if !Self.credentials.clientSecret.isEmpty { body["client_secret"] = Self.credentials.clientSecret }
            token = try await Self.tokenRequest(body)
            token.save(config.id)
        }
        return token.accessToken
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.api.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await http.json(for: request)
    }
}

// MARK: - 百度网盘

/// 百度网盘开放平台（xpan）。目录路径为网盘内真实路径；曲目路径为 "fsid:<fs_id>:<文件名>"。
public final class BaiduPanSource: OAuthCloudSource, @unchecked Sendable {
    public let config: SourceConfig
    private let http = HTTPClient.shared
    private static let oauth = URL(string: "https://openapi.baidu.com/oauth/2.0")!
    private static let pan = URL(string: "https://pan.baidu.com/rest/2.0/xpan")!

    public static var credentials: CloudAppCredentials { .fromBundle(prefix: "AmplayerBaidu") }

    public init(config: SourceConfig) { self.config = config }

    public static func authorizeURL(state: String, codeVerifier: String) -> URL {
        oauth.appendingPathComponent("authorize").appendingQuery([
            ("response_type", "code"), ("client_id", credentials.clientID), ("redirect_uri", credentials.redirectURI),
            ("scope", "basic,netdisk"), ("state", state), ("display", "mobile"),
        ])
    }

    public static func exchange(code: String, codeVerifier: String) async throws -> OAuthToken {
        try await tokenRequest([
            ("grant_type", "authorization_code"), ("code", code), ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret), ("redirect_uri", credentials.redirectURI),
        ])
    }

    private static func tokenRequest(_ query: [(String, String)]) async throws -> OAuthToken {
        let json = try await HTTPClient.shared.json(for: URLRequest(url: oauth.appendingPathComponent("token").appendingQuery(query)))
        guard let access = json.string("access_token") else {
            throw SourceError.authenticationFailed(json.string("error_description"))
        }
        return OAuthToken(accessToken: access, refreshToken: json.string("refresh_token"), expiresIn: json.double("expires_in") ?? 2_592_000)
    }

    public func list(path: String) async throws -> [SourceItem] {
        let token = try await accessToken()
        var items: [SourceItem] = []
        var start = 0
        while true {
            let url = Self.pan.appendingPathComponent("file").appendingQuery([
                ("method", "list"), ("dir", path.isEmpty ? "/" : path), ("order", "name"), ("start", "\(start)"),
                ("limit", "1000"), ("web", "0"), ("access_token", token),
            ])
            let json = try await baiduJSON(URLRequest(url: url))
            let list = json.array("list")
            for f in list {
                guard let name = f.string("server_filename"), let filePath = f.string("path") else { continue }
                if f.int("isdir") == 1 {
                    items.append(SourceItem(path: filePath, name: name, kind: .directory))
                } else if let fsid = f.string("fs_id") {
                    items.append(SourceItem(path: "fsid:\(fsid):\(name)", name: name, kind: .audio, size: f.int("size").map(Int64.init)))
                }
            }
            if list.count < 1000 { break }
            start += list.count
        }
        return items
    }

    public func download(path: String, to destination: URL) async throws {
        let parts = path.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] == "fsid" else { throw SourceError.protocolError("不是曲目：\(path)") }
        let token = try await accessToken()
        let metaURL = Self.pan.appendingPathComponent("multimedia").appendingQuery([
            ("method", "filemetas"), ("fsids", "[\(parts[1])]"), ("dlink", "1"), ("access_token", token),
        ])
        let json = try await baiduJSON(URLRequest(url: metaURL))
        guard let dlink = json.array("list").first?.string("dlink"), let base = URL(string: dlink) else {
            throw SourceError.protocolError("未拿到下载地址")
        }
        var request = URLRequest(url: base.appendingQuery([("access_token", token)]))
        // 百度要求下载请求带这个 UA
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        try await http.download(request, to: destination)
    }

    private func baiduJSON(_ request: URLRequest) async throws -> [String: Any] {
        let json = try await http.json(for: request)
        if let errno = json.int("errno"), errno != 0 {
            if errno == -6 || errno == 111 { throw SourceError.authenticationFailed("百度网盘授权已失效，请重新登录") }
            throw SourceError.protocolError("百度网盘 errno \(errno)")
        }
        return json
    }

    private func accessToken() async throws -> String {
        guard var token = OAuthToken.load(config.id) else { throw SourceError.notConfigured("请先登录百度网盘") }
        if token.isExpired, let refresh = token.refreshToken {
            token = try await Self.tokenRequest([
                ("grant_type", "refresh_token"), ("refresh_token", refresh),
                ("client_id", Self.credentials.clientID), ("client_secret", Self.credentials.clientSecret),
            ])
            token.save(config.id)
        }
        return token.accessToken
    }
}
