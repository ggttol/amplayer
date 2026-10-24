import Foundation
import Network
import Observation

/// 局域网自动发现：Bonjour（SMB、WebDAV）与 SSDP（DLNA 媒体服务器）
///
/// 注意：在 iOS 真机上发送 SSDP 组播需要 com.apple.developer.networking.multicast 权限（需向 Apple 申请）；
/// 没有权限时 SSDP 静默失败，Bonjour 不受影响。
@MainActor
@Observable
public final class LANDiscovery {
    public struct Found: Identifiable, Hashable, Sendable {
        public var id: String { "\(kind.rawValue)|\(url)" }
        public var name: String
        public var kind: SourceKind
        public var url: String
    }

    public private(set) var found: [Found] = []
    public private(set) var isRunning = false

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolving: [NWConnection] = []
    @ObservationIgnored private var group: NWConnectionGroup?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        found = []
        browse(type: "_smb._tcp", kind: .smb, scheme: "smb")
        browse(type: "_webdav._tcp", kind: .webdav, scheme: "http")
        browse(type: "_webdavs._tcp", kind: .webdav, scheme: "https")
        searchSSDP()
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        resolving.forEach { $0.cancel() }
        group?.cancel()
        browsers = []
        resolving = []
        group = nil
        isRunning = false
    }

    private func add(_ item: Found) {
        guard !found.contains(where: { $0.id == item.id }) else { return }
        found.append(item)
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Bonjour

    private func browse(type: String, kind: SourceKind, scheme: String) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    var path = ""
                    if case let .bonjour(txt) = result.metadata, let p = txt["path"] { path = p }
                    self?.resolve(result.endpoint, name: name, kind: kind, scheme: scheme, path: path)
                }
            }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    /// 连接一次以拿到 IP 和端口
    private func resolve(_ endpoint: NWEndpoint, name: String, kind: SourceKind, scheme: String, path: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let connection else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        var hostString: String
                        switch host {
                        case .ipv4(let addr): hostString = "\(addr)"
                        case .ipv6(let addr): hostString = "[\("\(addr)".split(separator: "%").first ?? "")]"
                        case .name(let n, _): hostString = n
                        @unknown default: hostString = "\(host)"
                        }
                        let defaultPort: UInt16 = scheme == "smb" ? 445 : (scheme == "https" ? 443 : 80)
                        if port.rawValue != defaultPort { hostString += ":\(port.rawValue)" }
                        self?.add(Found(name: name, kind: kind, url: "\(scheme)://\(hostString)\(path)"))
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    self?.resolving.removeAll { $0 === connection }
                default:
                    break
                }
            }
        }
        resolving.append(connection)
        connection.start(queue: .main)
    }

    // MARK: SSDP

    private func searchSSDP() {
        guard let multicast = try? NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)]) else { return }
        let group = NWConnectionGroup(with: multicast, using: .udp)
        group.setReceiveHandler(maximumMessageSize: 16384, rejectOversizedMessages: true) { [weak self] _, content, _ in
            guard let content, let text = String(data: content, encoding: .utf8) else { return }
            guard let location = Self.header("location", in: text), Self.header("st", in: text)?.contains("MediaServer") ?? text.contains("MediaServer") else { return }
            Task { @MainActor in await self?.describe(location: location) }
        }
        group.stateUpdateHandler = { [weak group] state in
            guard case .ready = state, let group else { return }
            let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
            for delay in [0.0, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    group.send(content: Data(search.utf8)) { _ in }
                }
            }
        }
        group.start(queue: .main)
        self.group = group
    }

    private func describe(location: String) async {
        guard let url = URL(string: location), !found.contains(where: { $0.url == location }) else { return }
        var name = url.host ?? location
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let friendly = SimpleXML.texts(in: data, names: ["friendlyName"])["friendlyName"], !friendly.isEmpty {
            name = friendly
        }
        add(Found(name: name, kind: .dlna, url: location))
    }

    nonisolated static func header(_ name: String, in response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
