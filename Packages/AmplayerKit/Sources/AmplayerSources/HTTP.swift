import Foundation

/// 可选择信任自签名证书的 URLSession 封装
public final class HTTPClient: Sendable {
    public let session: URLSession

    public static let shared = HTTPClient(allowInsecureTLS: false)
    public static let insecure = HTTPClient(allowInsecureTLS: true)

    public static func forConfig(_ config: SourceConfig) -> HTTPClient {
        config.allowInsecureTLS ? .insecure : .shared
    }

    /// 测试用：注入自定义 URLProtocol
    init(protocolClasses: [AnyClass]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses
        session = URLSession(configuration: configuration)
    }

    private init(allowInsecureTLS: Bool) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: allowInsecureTLS ? InsecureTrustDelegate() : nil,
            delegateQueue: nil
        )
    }

    /// 发送请求并检查状态码
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.protocolError("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.authenticationFailed("HTTP \(http.statusCode)") }
            throw SourceError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8))
        }
        return (data, http)
    }

    public func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.protocolError("响应不是 JSON 对象")
        }
        return object
    }

    /// 下载到目标路径：边收边写到 destination.part（边下边播从这里读），成功后改名
    public func download(_ request: URLRequest, to destination: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil) else { throw SourceError.protocolError("无法创建缓存文件") }
        let writer = try StreamingWriter(file: part, report: DownloadProgress.report)
        let task = session.dataTask(with: request)
        task.delegate = writer
        do {
            try await withTaskCancellationHandler {
                try await writer.run(task)
            } onCancel: {
                task.cancel()
            }
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
    }
}

final class InsecureTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

extension URL {
    /// 追加查询参数
    func appendingQuery(_ items: [(String, String)]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var existing = comps.queryItems ?? []
        existing += items.map { URLQueryItem(name: $0.0, value: $0.1) }
        comps.queryItems = existing
        // URLComponents 不转义 "+"，部分服务器会把它当空格
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url ?? self
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}

/// 下载进度上报：AudioCache 在下载时装上回调（TaskLocal），各来源的下载实现往里报（已收字节，总字节；未知为 -1）
public enum DownloadProgress {
    @TaskLocal public static var report: (@Sendable (Int64, Int64) -> Void)?
}

/// 数据任务的代理：收到一块就写进文件并上报（已收字节，总字节；未知为 -1）
final class StreamingWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let report: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var failure: (any Error)?

    init(file: URL, report: (@Sendable (Int64, Int64) -> Void)?) throws {
        handle = try FileHandle(forWritingTo: file)
        self.report = report
    }

    func run(_ task: URLSessionDataTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { self.continuation = continuation }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { failure = SourceError.protocolError("非 HTTP 响应") }
            return completionHandler(.cancel)
        }
        guard (200..<300).contains(http.statusCode) else {
            lock.withLock { failure = SourceError.http(http.statusCode, nil) }
            return completionHandler(.cancel)
        }
        lock.withLock { expected = http.expectedContentLength }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            lock.withLock { failure = error }
            dataTask.cancel()
            return
        }
        let (r, e) = lock.withLock { () -> (Int64, Int64) in
            received += Int64(data.count)
            return (received, expected)
        }
        report?(r, e)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle.close()
        let (continuation, stored) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, (any Error)?) in
            let c = self.continuation
            self.continuation = nil
            return (c, failure)
        }
        if let e = stored ?? error { continuation?.resume(throwing: e) } else { continuation?.resume() }
    }
}
