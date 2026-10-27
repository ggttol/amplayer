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
    var mayBlock: Bool { true }

    private let file: GrowingFile
    private let handle: FileHandle
    private let size: Int64
    private var audioFile: AudioFileID?
    private var extFile: ExtAudioFileRef?
    private let lock = NSLock()

    enum StreamError: LocalizedError {
        case open(OSStatus), unsupported, read(OSStatus)

        var errorDescription: String? {
            switch self {
            case .open(let s): "无法边下边播（格式解析失败 \(s)）"
            case .unsupported: "这个格式不能边下边播"
            case .read(let s): "解码失败（\(s)）"
            }
        }
    }

    /// 会等文件头下载好，可能阻塞：放在后台调用（见 open(_:fallbackDuration:)）
    init(file: GrowingFile, fallbackDuration: TimeInterval?) throws {
        self.file = file
        file.resume()
        size = file.expectedSize
        guard size > 0 else { throw StreamError.unsupported }
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
        var duration: Float64 = 0
        var durSize = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(id, kAudioFilePropertyEstimatedDuration, &durSize, &duration)
        if duration <= 0 { duration = fallbackDuration ?? 0 }
        guard duration > 0 else { throw StreamError.unsupported }
        length = AVAudioFramePosition(duration * fileFormat.mSampleRate)
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

    var expectedSize: Int64 { size }

    func interrupt() { file.interrupt() }
    func resumeReading() { file.resume() }

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
        if status != noErr {
            if file.error != nil { PlaybackLog.add("边下边播：下载中断，停在这里") }
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
        switch file.wait(until: end) {
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

    private static let readProc: AudioFile_ReadProc = { client, position, count, buffer, actual in
        Unmanaged<GrowingFileStream>.fromOpaque(client).takeUnretainedValue().readBytes(at: position, count: count, into: buffer, actual: actual)
    }

    private static let sizeProc: AudioFile_GetSizeProc = { client in
        Unmanaged<GrowingFileStream>.fromOpaque(client).takeUnretainedValue().size
    }

    // MARK: 格式识别

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
