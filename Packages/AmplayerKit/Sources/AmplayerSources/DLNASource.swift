import Foundation
import AmplayerCore

/// UPnP / DLNA 媒体服务器（ContentDirectory 服务）。几乎所有 NAS 都自带：群晖 Media Server、威联通、MiniDLNA、Jellyfin 等。
///
/// 配置里的 URL 是设备描述文档地址（SSDP 发现结果里的 LOCATION）。路径就是 ObjectID，根为 "0"。
public final class DLNASource: MediaSource, @unchecked Sendable {
    public let config: SourceConfig
    private let http: HTTPClient
    private let lock = NSLock()
    private var controlURL: URL?

    private static let serviceType = "urn:schemas-upnp-org:service:ContentDirectory:1"

    public init(config: SourceConfig) {
        self.config = config
        self.http = .forConfig(config)
    }

    public var rootPath: String { "0" }

    public func list(path: String) async throws -> [SourceItem] {
        let objectID = path == "/" || path.isEmpty ? "0" : path
        var result: [SourceItem] = []
        var start = 0
        let pageSize = 200
        while true {
            let (didl, returned, total) = try await browse(objectID: objectID, flag: "BrowseDirectChildren", start: start, count: pageSize)
            result += DIDLParser.parse(didl).map(\.item)
            start += returned
            if returned == 0 || start >= total { break }
        }
        return result
    }

    public func download(path: String, to destination: URL) async throws {
        let (didl, _, _) = try await browse(objectID: path, flag: "BrowseMetadata", start: 0, count: 1)
        guard let entry = DIDLParser.parse(didl).first, let res = entry.resourceURL, let url = URL(string: res) else {
            throw SourceError.protocolError("服务器没有返回音频地址")
        }
        try await http.download(URLRequest(url: url), to: destination)
    }

    public func artworkRequest(ref: String) async throws -> URLRequest? {
        URL(string: ref).map { URLRequest(url: $0) }
    }

    public func testConnection() async throws {
        _ = try await resolveControlURL()
    }

    // MARK: SOAP

    private func browse(objectID: String, flag: String, start: Int, count: Int) async throws -> (String, Int, Int) {
        let control = try await resolveControlURL()
        var request = URLRequest(url: control)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(Self.serviceType)#Browse\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:Browse xmlns:u="\(Self.serviceType)">
        <ObjectID>\(Self.escape(objectID))</ObjectID><BrowseFlag>\(flag)</BrowseFlag><Filter>*</Filter>
        <StartingIndex>\(start)</StartingIndex><RequestedCount>\(count)</RequestedCount><SortCriteria></SortCriteria>
        </u:Browse></s:Body></s:Envelope>
        """.utf8)
        let (data, _) = try await http.data(for: request)
        let fields = SimpleXML.texts(in: data, names: ["Result", "NumberReturned", "TotalMatches"])
        let didl = fields["Result"] ?? ""
        return (didl, Int(fields["NumberReturned"] ?? "") ?? 0, Int(fields["TotalMatches"] ?? "") ?? 0)
    }

    private func resolveControlURL() async throws -> URL {
        if let url = lock.withLock({ controlURL }) { return url }
        let descriptionURL = try config.baseURL()
        let (data, _) = try await http.data(for: URLRequest(url: descriptionURL))
        let services = DeviceDescriptionParser.parse(data)
        guard let service = services.first(where: { $0.serviceType.hasPrefix("urn:schemas-upnp-org:service:ContentDirectory") }) else {
            throw SourceError.unsupported("该设备没有 ContentDirectory 服务（不是媒体服务器）")
        }
        let base = services.first?.urlBase.flatMap(URL.init(string:)) ?? descriptionURL
        guard let url = URL(string: service.controlURL, relativeTo: base)?.absoluteURL else {
            throw SourceError.protocolError("controlURL 无效")
        }
        lock.withLock { controlURL = url }
        return url
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 设备描述文档里的服务列表
enum DeviceDescriptionParser {
    struct Service { var serviceType: String; var controlURL: String; var urlBase: String? }

    static func parse(_ data: Data) -> [Service] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.services.map { Service(serviceType: $0.serviceType, controlURL: $0.controlURL, urlBase: delegate.urlBase) }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var services: [Service] = []
        var urlBase: String?
        private var current: Service?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            if elementName == "service" { current = Service(serviceType: "", controlURL: "") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "serviceType": current?.serviceType = value
            case "controlURL": current?.controlURL = value
            case "URLBase": urlBase = value
            case "service":
                if let current { services.append(current) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}

/// 解析 DIDL-Lite（Browse 结果）
enum DIDLParser {
    struct Entry {
        var item: SourceItem
        var resourceURL: String?
    }

    static func parse(_ didl: String) -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    /// "0:03:25.500" → 205.5 秒
    static func seconds(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var isContainer = false
        private var inObject = false
        private var objectID = ""
        private var fields: [String: String] = [:]
        private var resAttributes: [String: String] = [:]
        private var resValues: [(url: String, attrs: [String: String])] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "container", "item":
                inObject = true
                isContainer = elementName == "container"
                objectID = attributeDict["id"] ?? ""
                fields = [:]
                resValues = []
            case "res":
                resAttributes = attributeDict
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard inObject else { return }
            switch elementName {
            case "res":
                resValues.append((value, resAttributes))
            case "container", "item":
                inObject = false
                finish()
            default:
                if fields[elementName] == nil { fields[elementName] = value }
            }
        }

        private func finish() {
            let title = fields["title"] ?? objectID
            if isContainer {
                entries.append(Entry(item: SourceItem(path: objectID, name: title, kind: .directory), resourceURL: nil))
                return
            }
            // 选第一个音频资源
            guard let res = resValues.first(where: { ($0.attrs["protocolInfo"] ?? "").contains("audio") }) ?? resValues.first else { return }
            let protocolInfo = res.attrs["protocolInfo"] ?? ""
            let urlExt = URL(string: res.url).map { $0.pathExtension.lowercased() } ?? ""
            let ext = AudioFormats.playable.contains(urlExt) ? urlExt : Self.extensionFor(protocolInfo: protocolInfo)
            guard (fields["class"] ?? "").contains("audio") || protocolInfo.contains("audio") else { return }
            let item = SourceItem(
                path: objectID, name: "\(title).\(ext)", kind: .audio,
                size: res.attrs["size"].flatMap { Int64($0) }, title: title,
                artist: fields["artist"] ?? fields["creator"], album: fields["album"],
                trackNumber: fields["originalTrackNumber"].flatMap { Int($0) },
                duration: res.attrs["duration"].flatMap(DIDLParser.seconds), fileExtension: ext,
                artworkRef: fields["albumArtURI"]
            )
            entries.append(Entry(item: item, resourceURL: res.url))
        }

        private static func extensionFor(protocolInfo: String) -> String {
            let mime = protocolInfo.split(separator: ":").dropFirst(2).first.map(String.init)?.lowercased() ?? ""
            switch mime {
            case "audio/flac", "audio/x-flac": return "flac"
            case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
            case "audio/wav", "audio/x-wav", "audio/l16": return "wav"
            case "audio/x-aiff", "audio/aiff": return "aiff"
            default: return "mp3"
            }
        }
    }
}

/// 取出若干元素的文本内容（SOAP 响应用）
enum SimpleXML {
    static func texts(in data: Data, names: Set<String>) -> [String: String] {
        let delegate = Delegate(names: names)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let names: Set<String>
        var values: [String: String] = [:]
        private var current: String?
        private var text = ""

        init(names: Set<String>) { self.names = names }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if names.contains(elementName) { current = elementName; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if current != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == current {
                values[elementName] = text
                current = nil
            }
        }
    }
}
