import Foundation
import MP9Core

/// WebDAV（含 Alist / OpenList、群晖 WebDAV Server、Nextcloud、坚果云等）
public struct WebDAVSource: MediaSource {
    public let config: SourceConfig
    private let password: String?
    private let http: HTTPClient

    public init(config: SourceConfig, password: String?) {
        self.config = config
        self.password = password
        self.http = .forConfig(config)
    }

    /// 根目录为 URL 里的路径部分，例如 http://alist:5244/dav → /dav
    public var rootPath: String {
        let p = (try? config.baseURL().path) ?? ""
        return p.isEmpty ? "/" : p
    }

    public func list(path: String) async throws -> [SourceItem] {
        var request = try request(for: path.hasSuffix("/") ? path : path + "/", method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getcontenttype/></d:prop></d:propfind>
        """.utf8)
        let (data, _) = try await http.data(for: request)
        let entries = WebDAVResponseParser.parse(data)
        let selfPath = Self.normalize(path)
        return entries.compactMap { entry in
            let entryPath = Self.normalize(Self.path(fromHref: entry.href))
            guard entryPath != selfPath, !entryPath.isEmpty else { return nil }
            let name = entry.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (entryPath as NSString).lastPathComponent
            if entry.isCollection {
                return SourceItem(path: entryPath, name: name, kind: .directory)
            }
            return SourceItem(path: entryPath, name: name, kind: .audio, size: entry.contentLength)
        }
    }

    public func download(path: String, to destination: URL) async throws {
        try await http.download(request(for: path, method: "GET"), to: destination)
    }

    public func testConnection() async throws {
        _ = try await list(path: rootPath)
    }

    func request(for path: String, method: String) throws -> URLRequest {
        let base = try config.baseURL()
        var comps = URLComponents()
        comps.scheme = base.scheme
        comps.host = base.host
        comps.port = base.port
        comps.path = path.hasPrefix("/") ? path : "/" + path
        guard let url = comps.url else { throw SourceError.invalidURL(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !config.username.isEmpty {
            let token = Data("\(config.username):\(password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// href 可能是完整 URL 或绝对路径，且经过百分号编码
    static func path(fromHref href: String) -> String {
        var raw = href
        if let url = URL(string: href), url.scheme != nil {
            raw = url.path(percentEncoded: true)
        }
        return raw.removingPercentEncoding ?? raw
    }

    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// 解析 PROPFIND 的 multistatus 响应
enum WebDAVResponseParser {
    struct Entry: Equatable {
        var href = ""
        var displayName: String?
        var isCollection = false
        var contentLength: Int64?
    }

    static func parse(_ data: Data) -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = Self.local(elementName)
            text = ""
            if name == "response" { current = Entry() }
            if name == "collection" { current?.isCollection = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch Self.local(elementName) {
            case "href": current?.href = value
            case "displayname": current?.displayName = value
            case "getcontentlength": current?.contentLength = Int64(value)
            case "response":
                if let current { entries.append(current) }
                current = nil
            default: break
            }
            text = ""
        }

        private static func local(_ name: String) -> String {
            (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
        }
    }
}
