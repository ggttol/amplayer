import AVFoundation
import MP9Core
import Observation

/// 基于 AVAudioEngine 的本地文件播放器：播放/暂停/跳转、10 段 EQ、音量、平衡、频谱。
@MainActor
@Observable
public final class AudioPlayer {
    public enum State: Sendable { case stopped, playing, paused }

    public struct FileInfo: Sendable, Equatable {
        public var duration: TimeInterval
        public var sampleRate: Double
        public var channels: Int
        /// 平均码率（kbps）
        public var bitrate: Int
    }

    public private(set) var state: State = .stopped
    public private(set) var info: FileInfo?
    /// 当前文件自然播完时回调（不包括 stop 和跳转）
    @ObservationIgnored public var onFinished: (() -> Void)?
    /// 系统打断（来电等）或耳机拔出导致暂停/恢复时回调
    @ObservationIgnored public var onStateChangedExternally: (() -> Void)?

    public var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    /// -1（左）...1（右）
    public var balance: Float = 0 {
        didSet { playerNode.pan = balance }
    }

    public var equalizer = EqualizerSettings.flat {
        didSet { applyEqualizer() }
    }

    @ObservationIgnored public let analyzer = SpectrumAnalyzer()

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    @ObservationIgnored private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
    /// 当前音源：Core Audio 能直接读的文件，或逐块解码的流（APE）
    private enum Source {
        case file(AVAudioFile)
        case stream(PCMStream, BufferScheduler)

        var format: AVAudioFormat {
            switch self {
            case .file(let f): f.processingFormat
            case .stream(let s, _): s.format
            }
        }

        var length: AVAudioFramePosition {
            switch self {
            case .file(let f): f.length
            case .stream(let s, _): s.length
            }
        }
    }

    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var segmentStart: AVAudioFramePosition = 0
    @ObservationIgnored private var pausedTime: TimeInterval = 0
    /// 每次重新调度递增，用来忽略旧调度的完成回调
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        engine.attach(playerNode)
        engine.attach(eqNode)
        for (i, band) in eqNode.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EqualizerSettings.frequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        eqNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.makeTap(analyzer))
        observeSystemEvents()
    }

    // MARK: 播放控制

    /// 打开本地文件，准备从头播放（不自动开始）
    public func load(url: URL) throws {
        stopNode()
        let source: Source
        if url.pathExtension.lowercased() == "ape" {
            let stream = try APEStream(url: url)
            source = .stream(stream, BufferScheduler(node: playerNode, stream: stream))
        } else {
            source = .file(try AVAudioFile(forReading: url))
        }
        self.source = source
        let format = source.format
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(eqNode)
        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)

        let duration = Double(source.length) / format.sampleRate
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let kbps = duration > 0 ? Int(Double(size) * 8 / duration / 1000) : 0
        info = FileInfo(duration: duration, sampleRate: format.sampleRate, channels: Int(format.channelCount), bitrate: kbps)
        pausedTime = 0
        schedule(from: 0)
        state = .paused
    }

    public func play() {
        guard source != nil else { return }
        activateSession()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        playerNode.play()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        pausedTime = currentTime
        playerNode.pause()
        state = .paused
    }

    public func stop() {
        stopNode()
        if source != nil { schedule(from: 0) }
        pausedTime = 0
        state = .stopped
        analyzer.decay()
    }

    /// 释放文件（播放列表清空时）
    public func unload() {
        stopNode()
        source = nil
        info = nil
        pausedTime = 0
        state = .stopped
    }

    public func seek(to time: TimeInterval) {
        guard let source, let info else { return }
        let clamped = time.clamped(to: 0...max(0, info.duration - 0.05))
        let frame = AVAudioFramePosition(clamped * source.format.sampleRate)
        let wasPlaying = state == .playing
        stopNode()
        schedule(from: frame)
        pausedTime = clamped
        if wasPlaying { playerNode.play() }
    }

    /// 当前播放位置（秒）。UI 定时读取，不参与 Observation。
    public var currentTime: TimeInterval {
        guard let source, state == .playing,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return pausedTime }
        let seconds = Double(segmentStart + playerTime.sampleTime) / source.format.sampleRate
        return min(max(0, seconds), info?.duration ?? seconds)
    }

    // MARK: 内部

    private func stopNode() {
        generation += 1
        if case .stream(_, let scheduler) = source { scheduler.invalidate() }
        playerNode.stop()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let source else { return }
        let remaining = source.length - frame
        guard remaining > 0 else { return }
        segmentStart = frame
        generation += 1
        let token = generation
        switch source {
        case .file(let file):
            playerNode.scheduleSegment(
                file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                completionCallbackType: .dataPlayedBack,
                completionHandler: Self.makeCompletion(self, token: token)
            )
        case .stream(_, let scheduler):
            scheduler.start(from: frame, token: token, onFinished: Self.makeStreamCompletion(self))
        }
    }

    private nonisolated static func makeStreamCompletion(_ player: AudioPlayer) -> @Sendable (Int) -> Void {
        { [weak player] token in
            Task { @MainActor in player?.segmentFinished(token) }
        }
    }

    // 这两个回调在音频线程上执行，必须在 nonisolated 上下文里创建，
    // 否则闭包会继承 MainActor 隔离，运行时检查会直接崩溃。
    private nonisolated static func makeTap(_ analyzer: SpectrumAnalyzer) -> AVAudioNodeTapBlock {
        { buffer, _ in analyzer.process(buffer) }
    }

    private nonisolated static func makeCompletion(_ player: AudioPlayer, token: Int) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { @Sendable [weak player] _ in
            Task { @MainActor in player?.segmentFinished(token) }
        }
    }

    private func segmentFinished(_ token: Int) {
        guard token == generation, state == .playing else { return }
        stopNode()
        if source != nil { schedule(from: 0) }
        pausedTime = 0
        state = .stopped
        onFinished?()
    }

    private func applyEqualizer() {
        let on = equalizer.enabled
        for (i, band) in eqNode.bands.enumerated() {
            band.gain = on ? equalizer.bands[i] : 0
        }
        eqNode.globalGain = on ? equalizer.preamp : 0
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { self?.handleInterruption(type: type, shouldResume: options?.contains(.shouldResume) ?? false) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable {
                    self?.pause()
                    self?.onStateChangedExternally?()
                }
            }
        })
        #endif
    }

    @ObservationIgnored private var resumeAfterInterruption = false

    #if os(iOS)
    private func handleInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            resumeAfterInterruption = state == .playing
            pause()
        case .ended:
            if shouldResume && resumeAfterInterruption { play() }
            resumeAfterInterruption = false
        default:
            break
        }
        onStateChangedExternally?()
    }
    #endif

    /// 输出设备变化（如 AirPlay 切换）后引擎会停止，需要重新启动并从原位置继续
    private func handleConfigurationChange() {
        let time = currentTime
        let wasPlaying = state == .playing
        guard let source else { return }
        stopNode()
        schedule(from: AVAudioFramePosition(time * source.format.sampleRate))
        pausedTime = time
        if wasPlaying {
            try? engine.start()
            playerNode.play()
        }
    }
}
