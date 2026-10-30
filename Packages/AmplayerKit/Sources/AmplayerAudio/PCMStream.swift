import AVFoundation
import MonkeysAudio

/// 逐块解码的 PCM 来源，用于 AVAudioFile 不支持的格式（APE）
protocol PCMStream: AnyObject, Sendable {
    /// 标准格式：Float32、非交错
    var format: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    func seek(to frame: AVAudioFramePosition) throws
    /// 读满（或读到结尾）一个缓冲区，返回帧数；0 表示结束
    func read(into buffer: AVAudioPCMBuffer) throws -> Int
    /// 读取可能要等数据（边下边播）：调度改在后台做，不在主线程上等
    var mayBlock: Bool { get }
    /// 读取批次编号：interrupt() 换新批次，让旧批次正在等数据的读取马上返回（换歌、跳转前）
    var readEpoch: Int { get }
    func interrupt()
    /// 之后的读取属于 epoch 这一批（调度开始时取的编号；之后又被打断就不会恢复）
    func resumeReading(epoch: Int)
}

extension PCMStream {
    var mayBlock: Bool { false }
    var readEpoch: Int { 0 }
    func interrupt() {}
    func resumeReading(epoch: Int) {}
}

enum PCMStreamError: LocalizedError {
    case open(Int32), decode(Int32), unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .open(let code): String(localized: "无法打开 APE 文件（错误 \(code)）")
        case .decode(let code): String(localized: "APE 解码失败（错误 \(code)）")
        case .unsupportedFormat: String(localized: "不支持的 APE 声道或位深")
        }
    }
}

/// Monkey's Audio（.ape）
final class APEStream: PCMStream, @unchecked Sendable {
    let format: AVAudioFormat
    let length: AVAudioFramePosition
    let bitsPerSample: Int
    private let handle: OpaquePointer
    /// 解码器不是线程安全的；BufferScheduler 只在自己的串行队列上调用，这里再加一把锁保险
    private let lock = NSLock()

    init(url: URL) throws {
        var info = amp_ape_info()
        var error: Int32 = 0
        guard let h = url.withUnsafeFileSystemRepresentation({ path in path.flatMap { amp_ape_open($0, &info, &error) } }) else {
            throw PCMStreamError.open(error)
        }
        guard info.channels > 0, info.channels <= 8, info.sample_rate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(info.sample_rate), channels: AVAudioChannelCount(info.channels))
        else {
            amp_ape_close(h)
            throw PCMStreamError.unsupportedFormat
        }
        handle = h
        self.format = format
        length = info.total_frames
        bitsPerSample = Int(info.bits_per_sample)
    }

    deinit {
        amp_ape_close(handle)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        let result = lock.withLock { amp_ape_seek(handle, frame) }
        if result != 0 { throw PCMStreamError.decode(result) }
    }

    func read(into buffer: AVAudioPCMBuffer) throws -> Int {
        guard let channels = buffer.floatChannelData else { return 0 }
        // C 接口的 float *const * 在 Swift 里是可选指针数组，内存布局相同
        let pointers = UnsafeRawPointer(channels).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
        let n = lock.withLock { amp_ape_read_float(handle, pointers, Int32(buffer.frameCapacity)) }
        if n < 0 { throw PCMStreamError.decode(n) }
        buffer.frameLength = AVAudioFrameCount(n)
        return Int(n)
    }

    /// 读 APEv2 标签
    func tag(_ field: String, capacity: Int = 1024) -> String? {
        var out = [CChar](repeating: 0, count: capacity)
        let ok = lock.withLock { amp_ape_tag(handle, field, &out, Int32(out.count)) }
        guard ok == 0 else { return nil }
        let bytes = out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// 在后台串行队列上解码，并保持若干个缓冲区排在播放节点上
final class BufferScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.gaotao.amplayer.decode", qos: .userInitiated)
    private let node: AVAudioPlayerNode
    private let stream: PCMStream
    private let framesPerBuffer: AVAudioFrameCount = 16384
    /// 至少提前排好几秒。完成回调要等声音真正放出来才回，隔空播放、无线 CarPlay 的输出延迟有一两秒，
    /// 以前固定排 4 块（44.1k 约 1.5 秒，高解析度更短）会断粮，声音一卡一卡
    private static let minimumAhead: Double = 4

    // 以下状态只在 queue 上访问
    private var token = 0
    private var outstanding = 0
    private var outstandingFrames: AVAudioFramePosition = 0
    private var targetFrames: AVAudioFramePosition = 0
    private var reachedEnd = false
    private var onFinished: (@Sendable (Int) -> Void)?

    init(node: AVAudioPlayerNode, stream: PCMStream) {
        self.node = node
        self.stream = stream
    }

    /// 从 frame 开始排缓冲区；token 用来识别过期回调；结束时回调 onFinished(token)
    func start(from frame: AVAudioFramePosition, token: Int, onFinished: @escaping @Sendable (Int) -> Void) {
        let epoch = stream.readEpoch
        let work: @Sendable () -> Void = { [self] in
            stream.resumeReading(epoch: epoch)
            self.token = token
            self.outstanding = 0
            self.outstandingFrames = 0
            self.reachedEnd = false
            self.onFinished = onFinished
            self.targetFrames = Self.aheadFrames(sampleRate: stream.format.sampleRate)
            try? stream.seek(to: frame)
            fill()
        }
        // 边下边播时读取可能要等下载，放到后台；播放节点先空转，缓冲区到了就接着放
        if stream.mayBlock { queue.async(execute: work) } else { queue.sync(execute: work) }
    }

    /// 让队列里的旧回调全部失效（stop / 跳转前调用）；先打断可能正在等下载的读取
    func invalidate() {
        stream.interrupt()
        queue.sync { token &+= 1_000_000 }
    }

    /// 输出延迟加 2 秒，至少 minimumAhead 秒（换输出设备时会重新调度，跟着重算）
    private static func aheadFrames(sampleRate: Double) -> AVAudioFramePosition {
        var seconds = minimumAhead
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        seconds = max(seconds, session.outputLatency + session.ioBufferDuration + 2)
        if session.outputLatency > 0.3 {
            let route = session.currentRoute.outputs.first.map { "\($0.portType.rawValue) \($0.portName)" } ?? ""
            let latency = String(format: "%.1f", session.outputLatency), ahead = String(format: "%.1f", seconds)
            PlaybackLog.add(String(localized: "输出延迟 \(latency) 秒（\(route)），提前缓冲 \(ahead) 秒"))
        }
        #endif
        return AVAudioFramePosition(seconds * sampleRate)
    }

    /// 排缓冲区，直到提前量够了或读到结尾
    private func fill() {
        while !reachedEnd && outstandingFrames < targetFrames {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: stream.format, frameCapacity: framesPerBuffer) else { break }
            let frames = (try? stream.read(into: buffer)) ?? 0
            guard frames > 0 else {
                reachedEnd = true
                break
            }
            outstanding += 1
            outstandingFrames += AVAudioFramePosition(frames)
            let myToken = token
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard myToken == self.token else { return }
                    self.outstanding -= 1
                    self.outstandingFrames -= AVAudioFramePosition(frames)
                    self.fill()
                }
            }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        if reachedEnd && outstanding == 0, let onFinished {
            self.onFinished = nil
            onFinished(token)
        }
    }
}
