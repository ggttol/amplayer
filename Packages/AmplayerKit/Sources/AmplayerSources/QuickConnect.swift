import Foundation

/// 群晖 QuickConnect：把 QuickConnect ID 解析成可直连的 DSM 地址
///
/// 流程（与群晖官方客户端一致，协议未公开，以实测为准）：
/// 1. 向 global.quickconnect.to/Serv.php 发 get_server_info；中国大陆账号会返回 errno 4 和 sites（如 cnc.quickconnect.cn），改向该站点再查一次
/// 2. 由返回的局域网、DDNS、公网、SmartDNS 信息生成候选地址；只用官方域名（证书有效），不直接连裸 IP
/// 3. 并发探测各候选的 /webman/pingpong.cgi，按优先级（局域网 > DDNS > 公网 > 中继）选第一个可用的
public actor QuickConnectResolver {
    public static let shared = QuickConnectResolver()

    public struct Candidate: Sendable, Equatable {
        public var url: URL
        /// 越小越优先
        public var priority: Int
        public var kind: String
    }

    private var cache: [String: (url: URL, expires: Date)] = [:]
    /// 记住每个 ID 所在区域的站点（如 cnc.quickconnect.cn），下次直接查询，省掉一次跳转
    private var siteHint: [String: String] = [:]
    private let http: HTTPClient

    init(http: HTTPClient = .shared) {
        self.http = http
    }

    /// "myds"、"QuickConnect.to/myds"、"myds.quickconnect.cn" 都识别为 ID；普通地址返回 nil
    public nonisolated static func quickConnectID(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        for host in ["quickconnect.to/", "quickconnect.cn/"] where lower.hasPrefix(host) {
            let id = String(s.dropFirst(host.count))
            return isValidID(id) ? id : nil
        }
        for suffix in [".quickconnect.to", ".quickconnect.cn"] where lower.hasSuffix(suffix) && !lower.contains(".direct.") {
            let id = String(s.dropLast(suffix.count))
            return isValidID(id) ? id : nil
        }
        return isValidID(s) ? s : nil
    }

    private nonisolated static func isValidID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } && !s.allSatisfy(\.isNumber)
    }

    public func invalidate(_ id: String) {
        cache[id.lowercased()] = nil
    }

    /// 解析并返回当前可用的 DSM 基础地址（https://host:port）
    public func resolve(_ id: String) async throws -> URL {
        let key = id.lowercased()
        if let hit = cache[key], hit.expires > Date() { return hit.url }
        let info = try await serverInfo(id)
        let candidates = Self.candidates(from: info)
        var best = await probe(candidates)
        // 直连全部失败才申请中继
        if best == nil, let relay = try? await relayCandidate(id, controlHost: info.controlHost) {
            best = await probe([relay])
        }
        guard let best else {
            let kinds = Set(candidates.map(\.kind)).sorted().joined(separator: "、")
            throw SourceError.http(0, String(localized: "QuickConnect 找到了 NAS，但\(kinds.isEmpty ? "没有可用地址" : "所有地址（\(kinds)）都连不上")，中继也不可用"))
        }
        cache[key] = (best, Date().addingTimeInterval(600))
        return best
    }

    // MARK: 服务器信息

    struct ServerInfo {
        var raw: [String: Any]
        var controlHost: String
    }

    private func serverInfo(_ id: String) async throws -> ServerInfo {
        var host = siteHint[id.lowercased()] ?? "global.quickconnect.to"
        for _ in 0..<3 {
            let json = try await serv(host, command: "get_server_info", id: id)
            let errno = json.int("errno") ?? -1
            if errno == 0 {
                siteHint[id.lowercased()] = host
                return ServerInfo(raw: json, controlHost: json.dict("env")?.string("control_host") ?? host)
            }
            // 账号在其他区域：换到返回的站点
            if errno == 4, let site = (json["sites"] as? [String])?.first, site != host {
                host = site
                continue
            }
            if errno == 4 || errno == 30 {
                throw SourceError.notConfigured(String(localized: "QuickConnect ID “\(id)”不存在，或 NAS 未开启 QuickConnect"))
            }
            throw SourceError.protocolError(String(localized: "QuickConnect 返回错误 \(errno)"))
        }
        throw SourceError.protocolError(String(localized: "QuickConnect 区域跳转过多"))
    }

    private func serv(_ host: String, command: String, id: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://\(host)/Serv.php")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [[String: Any]] = [[
            "version": 1, "command": command, "stop_when_error": false, "stop_when_success": false,
            "id": "dsm_portal_https", "serverID": id, "is_gofile": false, "path": "",
        ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.data(for: request)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = array.first else {
            throw SourceError.protocolError(String(localized: "QuickConnect 响应格式不对"))
        }
        return first
    }

    /// 由 get_server_info 结果生成候选地址
    static func candidates(from info: ServerInfo) -> [Candidate] {
        let json = info.raw
        let server = json.dict("server") ?? [:]
        let service = json.dict("service") ?? [:]
        let smartdns = json.dict("smartdns") ?? [:]
        let port = service.int("port") ?? 5001
        let extPort = service.int("ext_port").flatMap { $0 > 0 ? $0 : nil } ?? port
        var list: [Candidate] = []
        func add(_ host: String?, _ p: Int, _ priority: Int, _ kind: String) {
            guard let host, !host.isEmpty, host.uppercased() != "NULL", !isIPAddress(host),
                  let url = URL(string: "https://\(host):\(p)") else { return }
            if !list.contains(where: { $0.url == url }) { list.append(Candidate(url: url, priority: priority, kind: kind)) }
        }
        // 局域网（SmartDNS 把内网 IP 编进官方域名，证书有效）
        for h in (smartdns["lan"] as? [String]) ?? [] { add(h, port, 0, String(localized: "局域网")) }
        for h in (smartdns["lanv6"] as? [String]) ?? [] { add(h, port, 1, String(localized: "局域网 IPv6")) }
        // 用户自己的 DDNS / 域名
        for key in ["ddns", "fqdn"] {
            add(server.string(key), extPort, 2, "DDNS")
            if extPort != port { add(server.string(key), port, 3, "DDNS") }
        }
        // 路由器端口转发探测到的外网地址（只取域名）
        for desc in (service["pingpong_desc"] as? [String]) ?? [] {
            let parts = desc.split(separator: ":")
            if parts.count == 2, let p = Int(parts[1]) { add(String(parts[0]), p, 4, String(localized: "外网")) }
        }
        // SmartDNS 外网域名
        add(smartdns.string("host"), extPort, 5, String(localized: "外网"))
        if extPort != port { add(smartdns.string("host"), port, 6, String(localized: "外网")) }
        return list
    }

    /// 中继：request_tunnel 成功时返回中继地址（直连全部失败时才会用到）
    private func relayCandidate(_ id: String, controlHost: String) async throws -> Candidate? {
        let json = try await serv(controlHost, command: "request_tunnel", id: id)
        guard json.int("errno") == 0, let service = json.dict("service") else { return nil }
        let port = service.int("relay_port") ?? 443
        guard let host = service.string("relay_dn") ?? service.string("https_ip").flatMap({ Self.isIPAddress($0) ? nil : $0 }),
              let url = URL(string: "https://\(host):\(port)") else { return nil }
        return Candidate(url: url, priority: 9, kind: String(localized: "中继"))
    }

    /// 并发探测，返回优先级最高的可用地址。
    /// 第一个地址成功后最多再等 0.8 秒：局域网地址能通时几十毫秒就会返回，不通时要等到超时，没必要干等。
    private func probe(_ candidates: [Candidate]) async -> URL? {
        guard !candidates.isEmpty else { return nil }
        let http = http
        let graceID = -1
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, c) in candidates.enumerated() {
                group.addTask {
                    var request = URLRequest(url: c.url.appendingPathComponent("webman/pingpong.cgi").appendingQuery([("action", "cors"), ("quickconnect", "true")]))
                    request.timeoutInterval = 4
                    guard let json = try? await http.json(for: request) else { return (i, false) }
                    return (i, json["success"] as? Bool == true)
                }
            }
            var finished: [Int: Bool] = [:]
            var graceStarted = false
            func best() -> Int? {
                candidates.indices.filter { finished[$0] == true }.min { candidates[$0].priority < candidates[$1].priority }
            }
            for await (i, ok) in group {
                if i == graceID {
                    group.cancelAll()
                    return best().map { candidates[$0].url }
                }
                finished[i] = ok
                guard let winner = best() else { continue }
                let better = candidates.indices.filter { candidates[$0].priority < candidates[winner].priority }
                if better.allSatisfy({ finished[$0] != nil }) {
                    group.cancelAll()
                    return candidates[winner].url
                }
                if !graceStarted {
                    graceStarted = true
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(800))
                        return (graceID, false)
                    }
                }
            }
            return best().map { candidates[$0].url }
        }
    }

    nonisolated static func isIPAddress(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if trimmed.contains(":") { return true }
        let parts = trimmed.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
