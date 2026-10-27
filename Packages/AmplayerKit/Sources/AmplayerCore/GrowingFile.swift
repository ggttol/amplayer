import Foundation

/// 正在下载的文件：下载一边往 partURL 写，播放一边读，读到还没下载到的位置就等。
/// 下载成功后文件被移到 finalURL（已打开的文件句柄不受影响）。
public final class GrowingFile: @unchecked Sendable {
    public enum Wait: Equatable, Sendable {
        /// 要的字节都到了（或下载已结束，能读到哪算哪）
        case ready(available: Int64)
        /// 下载失败
        case failed
        /// 读取方放弃（换歌、跳转）
        case interrupted
    }

    public let partURL: URL
    public let finalURL: URL
    private let condition = NSCondition()
    private var received: Int64 = 0
    private var total: Int64
    private var finished = false
    private var failure: (any Error)?

    public init(partURL: URL, finalURL: URL, expectedSize: Int64 = -1) {
        self.partURL = partURL
        self.finalURL = finalURL
        total = expectedSize
    }

    /// 总大小；未知为 -1
    public var expectedSize: Int64 { condition.withLock { total } }
    public var receivedBytes: Int64 { condition.withLock { received } }
    public var isFinished: Bool { condition.withLock { finished } }
    public var error: (any Error)? { condition.withLock { failure } }

    // MARK: 下载方

    public func update(received: Int64, total: Int64) {
        condition.withLock {
            self.received = received
            if total > 0 { self.total = total }
            condition.broadcast()
        }
    }

    public func finish() {
        condition.withLock {
            finished = true
            if total <= 0 { total = received }
            condition.broadcast()
        }
    }

    public func fail(_ error: any Error) {
        condition.withLock {
            failure = error
            condition.broadcast()
        }
    }

    // MARK: 播放方

    /// 阻塞等到前 end 个字节都下载好（在解码线程上调用，不要在主线程用）；cancelled 返回真就放弃
    public func wait(until end: Int64, cancelled: () -> Bool = { false }) -> Wait {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled() { return .interrupted }
            if failure != nil { return .failed }
            if received >= end || finished { return .ready(available: received) }
            condition.wait(until: Date().addingTimeInterval(0.5))
        }
    }

    /// 叫醒正在等的读取，让它们重新检查是否该放弃
    public func wakeWaiters() {
        condition.withLock { condition.broadcast() }
    }

    /// 异步等开头若干字节（或下载结束）；不占线程
    public func waitAsync(forFirst bytes: Int64) async throws {
        while true {
            try Task.checkCancellation()
            let (enough, done) = condition.withLock { (received >= bytes || (total > 0 && received >= total), finished || failure != nil) }
            if enough || done { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
