import AVFoundation
import AudioToolbox
import AmplayerCore

/// 边下边播：用 AudioFile 的回调接口解码正在下载的文件。
/// 读到还没下载到的位置就在解码线程上等（BufferScheduler 的后台队列），不会卡住界面。
/// 支持 AudioFile 能解析的格式：MP3、AAC/M4A、FLAC、ALAC、WAV、AIFF、CAF。
final class GrowingFileStream: PCMStream, @unchecked Sendable {
    // 打开文件前就要把 self 交给 AudioFile 回调，所以先给占位值
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private(set) var length: AVAudioFramePosition = 0
    /// 时长未知（服务器边转码边发、又没给时长）：先照常播放，length 是占位值，知道后用 setDuration 补上
    private(set) var durationKnown = true
    var mayBlock: Bool { true }

    private let file: GrowingFile
    private let handle: FileHandle
    /// 下载开始时就知道的总大小；服务器边转码边发（CUE 分轨等）时不知道，为 -1
    private let knownSize: Int64
    private var audioFile: AudioFileID?
    private var extFile: ExtAudioFileRef?
    private let lock = NSLock()
    /// 解析文件头阶段：MP3、WAV 解析时会去读文件末尾（ID3v1 标签、尾部附加块），
    /// 这时还没下载到的远处直接当作没有数据，不等，否则要等整个文件下完才能开始放
    private var opening = true

    enum StreamError: LocalizedError {
        case open(OSStatus), unsupported, read(OSStatus)

        var errorDescription: String? {
            switch self {
            case .open(let s): String(localized: "无法边下边播（格式解析失败 \(s)）")
            case .unsupported: String(localized: "这个格式不能边下边播")
            case .read(let s): String(localized: "解码失败（\(s)）")
            }
        }
    }

    /// 会等文件头下载好，可能阻塞：放在后台调用（见 open(_:fallbackDuration:)）
    init(file: GrowingFile, fallbackDuration: TimeInterval?) throws {
        self.file = file
        knownSize = file.expectedSize
        // 不知道总大小时，AudioFile 按文件大小估出来的时长不可信：用服务器给的时长，没有就先当未知
        let sizeUnknown = knownSize <= 0 && !file.isFinished
        // 下载很快的话可能已经下完并移走了
        if let h = try? FileHandle(forReadingFrom: file.partURL) {
            handle = h
        } else {
            handle = try FileHandle(forReadingFrom: file.finalURL)
        }
        let hint = Self.typeHint(file: file, handle: handle)
        guard hint != 0 else { throw StreamError.unsupported }
        var id: AudioFileID?
        let me = Unmanaged.passUnretained(self).toOpaque()
        var status = AudioFileOpenWithCallbacks(me, Self.readProc, nil, Self.sizeProc, nil, hint, &id)
        guard status == noErr, let id else { throw StreamError.open(status) }
        audioFile = id
        var ext: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(id, false, &ext)
        guard status == noErr, let ext else { AudioFileClose(id); audioFile = nil; throw StreamError.open(status) }
        extFile = ext

        var fileFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFormat)
        guard status == noErr, fileFormat.mSampleRate > 0, fileFormat.mChannelsPerFrame > 0,
              let client = AVAudioFormat(standardFormatWithSampleRate: fileFormat.mSampleRate, channels: fileFormat.mChannelsPerFrame)
        else { throw StreamError.unsupported }
        var clientDesc = client.streamDescription.pointee
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientDesc)
        guard status == noErr else { throw StreamError.open(status) }
        format = client

        // 时长用估计值：精确帧数对 VBR MP3 要扫完整个文件，会一直等到下载完
        // 还在下载、又是头里没写总长度的 FLAC 时，估计时长要把整个文件扫一遍（等于等下载完）：有服务器给的时长就直接用
        var duration: Float64 = 0
        let flacLengthUnknown = !file.isFinished && hint == kAudioFileFLACType && Self.flacTotalSamplesUnknown(handle)
        if sizeUnknown || flacLengthUnknown {
            duration = fallbackDuration ?? 0
        } else {
            var durSize = UInt32(MemoryLayout<Float64>.size)
            AudioFileGetProperty(id, kAudioFilePropertyEstimatedDuration, &durSize, &duration)
        }
        if duration <= 0 { duration = fallbackDuration ?? 0 }
        if duration > 0 {
            length = AVAudioFramePosition(duration * fileFormat.mSampleRate)
        } else {
            // 时长未知也先放：读到文件末尾自然结束；占位长度只用来排缓冲区
            durationKnown = false
            length = AVAudioFramePosition(Self.unknownDurationCeiling * fileFormat.mSampleRate)
        }
        opening = false
    }

    deinit {
        if let extFile { ExtAudioFileDispose(extFile) }
        if let audioFile { AudioFileClose(audioFile) }
        try? handle.close()
    }

    /// 在后台线程打开（解析文件头时可能要等下载）
    static func open(_ file: GrowingFile, fallbackDuration: TimeInterval?) async throws -> GrowingFileStream {
        try await Task.detached(priority: .userInitiated) {
            try GrowingFileStream(file: file, fallbackDuration: fallbackDuration)
        }.value
    }

    /// 时长未知时的占位长度（秒）
    static let unknownDurationCeiling: Double = 6 * 3600

    /// 补上后来知道的时长（服务器测出来了，或者下载完读到了）
    func setDuration(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        length = AVAudioFramePosition(seconds * format.sampleRate)
        durationKnown = true
    }

    /// 码率显示用；不知道大小时为 0
    var expectedSize: Int64 { max(knownSize, 0) }

    /// 给 AudioFile 的文件大小：知道就用真实大小；还在下载又不知道大小时先报一个很大的数，
    /// 读到还没下载的位置照常等，下载结束后改报实际收到的字节数，读到末尾自然结束
    private var size: Int64 {
        if knownSize > 0 { return knownSize }
        return file.isFinished ? file.receivedBytes : Self.unknownSizeCeiling
    }

    private static let unknownSizeCeiling: Int64 = 1 << 40

    // 读取批次：每次 interrupt() 都换一批，旧批次还在等的读取立刻放弃。
    // 用编号而不是开关：连续跳转时，上一次调度的“恢复”不会把这一次的“打断”抵消掉
    private let epochLock = NSLock()
    private var epoch = 0
    private var activeEpoch = 0

    var readEpoch: Int { epochLock.withLock { epoch } }

    func interrupt() {
        epochLock.withLock { epoch += 1 }
        file.wakeWaiters()
    }

    func resumeReading(epoch: Int) {
        epochLock.withLock { activeEpoch = epoch }
    }

    private var readsCancelled: Bool { epochLock.withLock { activeEpoch != epoch } }

    func seek(to frame: AVAudioFramePosition) throws {
        guard let extFile else { return }
        let status = lock.withLock { ExtAudioFileSeek(extFile, frame) }
        if status != noErr { throw StreamError.read(status) }
    }

    func read(into buffer: AVAudioPCMBuffer) throws -> Int {
        guard let extFile else { return 0 }
        var frames = buffer.frameCapacity
        // 每次取 mutableAudioBufferList 都会按 frameLength 重算字节数：先撑到满容量，再只取一次
        buffer.frameLength = buffer.frameCapacity
        let list = buffer.mutableAudioBufferList
        let status = lock.withLock { ExtAudioFileRead(extFile, &frames, list) }
        // 不知道总大小的流：下载结束后读到末尾时解码器可能报错而不是返回 0 帧，当作放完了
        if status != noErr, knownSize <= 0, file.isFinished, file.error == nil {
            buffer.frameLength = 0
            return 0
        }
        if status != noErr {
            if file.error != nil { PlaybackLog.add(String(localized: "边下边播：下载中断，停在这里")) }
            throw StreamError.read(status)
        }
        buffer.frameLength = frames
        return Int(frames)
    }

    // MARK: AudioFile 回调

    private func readBytes(at position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer, actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        actual.pointee = 0
        guard position < size else { return kAudioFileEndOfFileError }
        let end = min(size, position + Int64(count))
        if opening, position > max(file.receivedBytes, Self.openHorizon) {
            return kAudioFileEndOfFileError
        }
        switch file.wait(until: end, cancelled: { readsCancelled }) {
        case .interrupted, .failed:
            return kAudioFileUnspecifiedError
        case .ready(let available):
            let readable = min(end, available) - position
            guard readable > 0 else { return kAudioFileEndOfFileError }
            let n = pread(handle.fileDescriptor, buffer, Int(readable), off_t(position))
            guard n >= 0 else { return kAudioFileUnspecifiedError }
            actual.pointee = UInt32(n)
            return n == 0 ? kAudioFileEndOfFileError : noErr
        }
    }

    /// 解析文件头时最多等到这么远（封面图大的 FLAC 头可能有几 MB）
    static let openHorizon: Int64 = 4 * 1024 * 1024

    private static let readProc: AudioFile_ReadProc = { client, position, count, buffer, actual in
        Unmanaged<GrowingFileStream>.fromOpaque(client).takeUnretainedValue().readBytes(at: position, count: count, into: buffer, actual: actual)
    }

    private static let sizeProc: AudioFile_GetSizeProc = { client in
        Unmanaged<GrowingFileStream>.fromOpaque(client).takeUnretainedValue().size
    }

    // MARK: 格式识别

    /// FLAC 的 STREAMINFO 里总采样数（36 位）为 0 表示未知
    static func flacTotalSamplesUnknown(_ handle: FileHandle) -> Bool {
        var head = [UInt8](repeating: 0, count: 26)
        guard pread(handle.fileDescriptor, &head, 26, 0) == 26, head[0..<4] == [0x66, 0x4C, 0x61, 0x43] else { return false }
        return head[21] & 0x0F == 0 && head[22...25].allSatisfy { $0 == 0 }
    }

    /// 先看文件头，认不出再看扩展名；APE 等 AudioFile 不支持的返回 0
    static func typeHint(file: GrowingFile, handle: FileHandle) -> AudioFileTypeID {
        if case .ready = file.wait(until: 12) {
            var head = [UInt8](repeating: 0, count: 12)
            let n = pread(handle.fileDescriptor, &head, 12, 0)
            if n >= 12 {
                let s = String(decoding: head[0..<4], as: UTF8.self)
                if s == "fLaC" { return kAudioFileFLACType }
                if s == "MAC " { return 0 }
                if s == "RIFF" { return kAudioFileWAVEType }
                if s == "FORM" { return kAudioFileAIFFType }
                if s == "caff" { return kAudioFileCAFType }
                if String(decoding: head[4..<8], as: UTF8.self) == "ftyp" { return kAudioFileM4AType }
                if s.hasPrefix("ID3") || (head[0] == 0xFF && head[1] & 0xE0 == 0xE0) { return kAudioFileMP3Type }
            }
        }
        switch file.finalURL.pathExtension.lowercased() {
        case "mp3": return kAudioFileMP3Type
        case "flac": return kAudioFileFLACType
        case "m4a", "mp4", "m4b", "alac": return kAudioFileM4AType
        case "aac": return kAudioFileAAC_ADTSType
        case "wav": return kAudioFileWAVEType
        case "aif", "aiff": return kAudioFileAIFFType
        case "caf": return kAudioFileCAFType
        default: return 0
        }
    }
}
