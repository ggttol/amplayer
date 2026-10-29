import AVFoundation
import AmplayerCore
import AmplayerObjC
import Observation

/// 基于 AVAudioEngine 的本地文件播放器：播放/暂停/跳转、10 段 EQ、音量、平衡、频谱。
/// 音频引擎拒绝连接：多半是输出设备正在切换（刚连上 CarPlay、蓝牙或 AirPlay）
public struct AudioEngineError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { "音频输出还没准备好，请稍后再试（\(reason)）" }
}

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
    /// 无缝衔接：预先排好的下一首开始播放时回调（参数是它的文件地址）
    @ObservationIgnored public var onAdvancedToNext: ((URL) -> Void)?
    /// 系统打断（来电等）或耳机拔出导致暂停/恢复时回调
    @ObservationIgnored public var onStateChangedExternally: (() -> Void)?

    public var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    /// -1（左）...1（右）
    public var balance: Float = 0 {
        didSet { updatePan() }
    }

    /// 音效（音色、混响、回声、环绕、响度、变速变调、黑胶底噪）
    public var effects = SoundEffects.off {
        didSet {
            effectsChain.apply(effects)
            updateSurround()
        }
    }

    /// 当前的变速倍率（锁屏进度按这个走）
    public var playbackRate: Float { effects.rate }

    public var equalizer = EqualizerSettings.flat {
        didSet { applyEqualizer() }
    }

    /// 音量均衡（ReplayGain）：当前曲目额外加减的分贝数，叠加在均衡器前级增益上（可以提升，不会被音量上限截住）
    public var gainAdjustment: Float = 0 {
        didSet { applyEqualizer() }
    }

    @ObservationIgnored public let analyzer = SpectrumAnalyzer()

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    /// 淡入淡出：上一首剩下的尾巴交给这个节点淡出，同时主节点淡入下一首
    @ObservationIgnored private let fadeNode = AVAudioPlayerNode()
    @ObservationIgnored private var fadeOutTimer: Timer?
    @ObservationIgnored private var fadeInTimer: Timer?
    /// 两个节点各自的淡入淡出进度（0...1），实际音量还要乘上音量均衡的补偿
    @ObservationIgnored private var playerLevel: Float = 1
    @ObservationIgnored private var fadeLevel: Float = 0
    /// 正在淡出的尾巴自己的音量均衡分贝数：两首歌的增益不同，不能共用一个总增益
    @ObservationIgnored private var fadeTailGain: Float?
    @ObservationIgnored private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
    @ObservationIgnored private let effectsChain = EffectsChain()
    @ObservationIgnored private var surroundTimer: Timer?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var surroundPhase: Double = 0
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
    /// 每次调度递增；完成回调带着自己的编号，只认当前段（currentToken）的
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var currentToken = -1
    /// 当前段调度的帧数、它在播放节点时间轴上的起点（无缝衔接后节点时间不归零）
    @ObservationIgnored private var scheduledFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var nodeOffset: AVAudioFramePosition = 0
    /// 已经排在当前段后面的下一首
    @ObservationIgnored private var pending: (file: AVAudioFile, url: URL, token: Int)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// 最近一次算出的播放位置：系统先停掉引擎再通知配置变化，那时已经读不到位置了
    @ObservationIgnored private var lastObservedTime: TimeInterval = 0
    @ObservationIgnored private var positionTimer: Timer?

    public init() {
        engine.attach(playerNode)
        engine.attach(fadeNode)
        engine.attach(eqNode)
        for (i, band) in eqNode.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EqualizerSettings.frequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        effectsChain.attach(to: engine)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        do {
            try effectsChain.connect(player: playerNode, equalizer: eqNode, fileFormat: format, in: engine)
        } catch {
            PlaybackLog.add("启动时连接音频链失败（加载歌曲时会再接）：\(error.localizedDescription)")
        }
        effectsChain.apply(effects)
        engine.mainMixerNode.outputVolume = volume
        eqNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.makeTap(analyzer))
        observeSystemEvents()
    }

    // MARK: 播放控制

    /// 打开本地文件，准备从头播放（不自动开始）
    public func load(url: URL) throws {
        stopNode()
        let source: Source
        // 按文件头判断：服务器上有把 FLAC 存成 .ape 的
        if Self.isMonkeysAudio(url) {
            let stream = try APEStream(url: url)
            source = .stream(stream, BufferScheduler(node: playerNode, stream: stream))
        } else {
            let file = try AVAudioFile(forReading: url)
            if file.length > 0 {
                source = .file(file)
            } else {
                // 有的 FLAC 文件头没写总采样数（转码工具生成的），AVAudioFile 当成 0 帧，排不进任何内容、也不报错。
                // 改用逐块解码读到文件真正结束，时长用估计值
                PlaybackLog.add("文件头没写总长度，改用逐块解码：\(url.lastPathComponent)")
                let stream = try Self.wholeFileStream(url)
                source = .stream(stream, BufferScheduler(node: playerNode, stream: stream))
            }
        }
        let format = source.format
        do {
            try connectChain(format: format)
        } catch {
            unload()
            throw error
        }
        self.source = source
        updatePan()

        info = Self.makeInfo(length: source.length, format: format, size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        pausedTime = 0
        schedule(from: 0)
        state = .paused
    }

    /// 边下边播：文件还在下载，开头已经够解析格式了（准备从头播放，不自动开始）
    public func load(growing file: GrowingFile, fallbackDuration: TimeInterval?) async throws {
        let stream = try await GrowingFileStream.open(file, fallbackDuration: fallbackDuration)
        // 解析文件头时用户可能已经换了歌：别把旧歌装回来
        try Task.checkCancellation()
        stopNode()
        do {
            try connectChain(format: stream.format)
        } catch {
            unload()
            throw error
        }
        source = .stream(stream, BufferScheduler(node: playerNode, stream: stream))
        updatePan()
        // 时长未知时 duration 为 0：界面不显示总长、不能拖动，等 updateDuration 补上
        info = Self.makeInfo(length: stream.durationKnown ? stream.length : 0, format: stream.format, size: stream.expectedSize)
        pausedTime = 0
        schedule(from: 0)
        state = .paused
    }

    /// 把完整的本地文件当成“已下载完”的 GrowingFile，用逐块解码打开
    private static func wholeFileStream(_ url: URL) throws -> GrowingFileStream {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let file = GrowingFile(partURL: url, finalURL: url, expectedSize: size)
        file.update(received: size, total: size)
        file.finish()
        return try GrowingFileStream(file: file, fallbackDuration: nil)
    }

    /// 接音效链；被拒绝时（输出设备正在切换）重置引擎再试一次
    private func connectChain(format: AVAudioFormat) throws {
        do {
            try effectsChain.connect(player: playerNode, equalizer: eqNode, fileFormat: format, in: engine)
        } catch {
            PlaybackLog.add("连接音频链失败，重置音频引擎再试：\(error.localizedDescription)")
            engine.stop()
            engine.reset()
            try effectsChain.connect(player: playerNode, equalizer: eqNode, fileFormat: format, in: engine)
        }
    }

    /// Monkey's Audio 文件以 "MAC " 开头（前面可能有 ID3v2 标签）
    nonisolated static func isMonkeysAudio(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return url.pathExtension.lowercased() == "ape" }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: 10), head.count >= 4 else { return false }
        if head.starts(with: Array("ID3".utf8)), head.count == 10 {
            // ID3v2 长度是 4 个 7 位字节，带页脚再加 10
            let body = head[6...9].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
            let size = body + 10 + (head[5] & 0x10 != 0 ? 10 : 0)
            guard (try? handle.seek(toOffset: UInt64(size))) != nil, let next = try? handle.read(upToCount: 4) else { return false }
            head = next
        }
        return head.starts(with: Array("MAC ".utf8))
    }

    /// 无缝衔接：把下一首排在当前这首后面（同采样率、同声道的普通文件才行；APE 和格式不同的退回普通切歌）。
    /// 成功返回 true；之后跳转、停止、重新加载都会取消它。
    @discardableResult
    public func enqueueNext(url: URL) -> Bool {
        guard pending == nil, currentToken >= 0, case .file(let current) = source,
              url.pathExtension.lowercased() != "ape",
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat == current.processingFormat, file.length > 0 else { return false }
        generation += 1
        let token = generation
        playerNode.scheduleSegment(
            file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletion(self, token: token)
        )
        pending = (file, url, token)
        return true
    }

    public var hasQueuedNext: Bool { pending != nil }

    public func play() {
        guard source != nil else { return }
        activateSession()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            PlaybackLog.add("音频引擎启动失败：\(error.localizedDescription)")
            return
        }
        idleTask?.cancel()
        playerNode.play()
        state = .playing
        startPositionTimer()
    }

    /// 播放时每秒记一次位置（后台也跑），输出设备变化后据此从原位置继续
    private func startPositionTimer() {
        guard positionTimer == nil else { return }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state == .playing { _ = self.currentTime } else { self.positionTimer?.invalidate(); self.positionTimer = nil }
            }
        }
    }

    public func pause() {
        guard state == .playing else { return }
        cancelFades()
        pausedTime = currentTime
        playerNode.pause()
        state = .paused
        scheduleIdleStop()
    }

    /// 不在播放时过一会儿暂停音频引擎（音频硬件跟着休眠，省电、不发热）；再按播放时 play() 会重新启动
    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.state != .playing, self.engine.isRunning else { return }
            self.engine.pause()
        }
    }

    public func stop() {
        stopNode()
        if source != nil { schedule(from: 0) }
        pausedTime = 0
        state = .stopped
        analyzer.decay()
        scheduleIdleStop()
    }

    /// 释放文件（播放列表清空时）
    /// 边下边播开始时不知道时长的，后来知道了就补上（之后可以拖动）
    public func updateDuration(_ seconds: TimeInterval) {
        guard seconds > 0, case .stream(let stream, _) = source,
              let growing = stream as? GrowingFileStream, !growing.durationKnown else { return }
        growing.setDuration(seconds)
        info = Self.makeInfo(length: growing.length, format: growing.format, size: growing.expectedSize)
    }

    public func unload() {
        cancelFades()
        stopNode()
        source = nil
        info = nil
        pausedTime = 0
        state = .stopped
    }

    public func seek(to time: TimeInterval) {
        guard let source, let info else { return }
        cancelFades()
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
        let seconds = Double(segmentStart + playerTime.sampleTime - nodeOffset) / source.format.sampleRate
        let duration = info?.duration ?? 0
        let time = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        lastObservedTime = time
        return time
    }

    // MARK: 内部

    private func stopNode() {
        generation += 1
        currentToken = -1
        pending = nil
        nodeOffset = 0
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
        currentToken = token
        scheduledFrames = remaining
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
        guard token == currentToken else { return }
        guard state == .playing else {
            PlaybackLog.add("曲目播完但当前不是播放状态（\(state)），不自动下一首")
            return
        }
        if let next = pending {
            // 下一首已经在节点上接着播了：只切换记账，不停节点
            pending = nil
            nodeOffset += scheduledFrames
            segmentStart = 0
            scheduledFrames = next.file.length
            currentToken = next.token
            source = .file(next.file)
            info = Self.makeInfo(length: next.file.length, format: next.file.processingFormat, size: Int64((try? next.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            pausedTime = 0
            onAdvancedToNext?(next.url)
            return
        }
        stopNode()
        if source != nil { schedule(from: 0) }
        pausedTime = 0
        state = .stopped
        onFinished?()
    }

    private static func makeInfo(length: AVAudioFramePosition, format: AVAudioFormat, size: Int64) -> FileInfo {
        let duration = Double(length) / format.sampleRate
        let kbps = duration > 0 ? Int(Double(size) * 8 / duration / 1000) : 0
        return FileInfo(duration: duration, sampleRate: format.sampleRate, channels: Int(format.channelCount), bitrate: kbps)
    }

    // MARK: 声像：平衡 + 环绕旋转

    private func updatePan() {
        let orbit = effects.surround > 0 ? Float(sin(surroundPhase)) * effects.surround : 0
        playerNode.pan = (balance + orbit).clamped(to: -1...1)
    }

    /// 环绕/8D：每秒 30 次转动声像
    private func updateSurround() {
        if effects.surround > 0 {
            guard surroundTimer == nil else { return }
            surroundTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.state == .playing {
                        self.surroundPhase += 2 * .pi * Double(self.effects.surroundSpeed) / 30
                        if self.surroundPhase > 2 * .pi { self.surroundPhase -= 2 * .pi }
                    }
                    self.updatePan()
                }
            }
        } else {
            surroundTimer?.invalidate()
            surroundTimer = nil
            surroundPhase = 0
            updatePan()
        }
    }

    private func applyEqualizer() {
        let on = equalizer.enabled
        for (i, band) in eqNode.bands.enumerated() {
            band.gain = on ? equalizer.bands[i] : 0
        }
        // 淡出期间两首歌同时经过均衡器：总增益取两者中较大的，各自少的部分在节点音量上减掉（节点音量只能衰减）
        let shared = max(gainAdjustment, fadeTailGain ?? gainAdjustment)
        eqNode.globalGain = ((on ? equalizer.preamp : 0) + shared).clamped(to: -96...24)
        playerScale = Self.linear(gainAdjustment - shared)
        fadeScale = Self.linear((fadeTailGain ?? shared) - shared)
        updateNodeVolumes()
    }

    @ObservationIgnored private var playerScale: Float = 1
    @ObservationIgnored private var fadeScale: Float = 1

    private static func linear(_ db: Float) -> Float { pow(10, db / 20) }

    /// 测试用：均衡器总增益、主节点和淡出节点的实际音量
    var mixLevels: (globalGain: Float, player: Float, fade: Float) { (eqNode.globalGain, playerNode.volume, fadeNode.volume) }

    private func updateNodeVolumes() {
        playerNode.volume = playerLevel * playerScale
        fadeNode.volume = fadeLevel * fadeScale
    }

    // MARK: 淡入淡出

    /// 把当前这首从现在起剩下的部分交给淡出节点，在 duration 秒内淡出。
    /// 成功后主节点空出来，调用方接着加载下一首并 fadeIn。
    /// 边下边播的歌传入已经下载完的文件（completedFile）也可以；APE 等只能逐块解码的格式不行。
    @discardableResult
    public func handOffForCrossfade(duration: TimeInterval, completedFile: URL? = nil) -> Bool {
        guard state == .playing, duration > 0 else { return false }
        let file: AVAudioFile
        switch source {
        case .file(let f)?:
            file = f
        case .stream?:
            guard let url = completedFile, !Self.isMonkeysAudio(url),
                  let f = try? AVAudioFile(forReading: url), f.length > 0 else { return false }
            file = f
        case nil:
            return false
        }
        let start = AVAudioFramePosition(currentTime * file.processingFormat.sampleRate)
        let remaining = file.length - start
        guard remaining > 0 else { return false }
        fadeOutTimer?.invalidate()
        fadeNode.stop()
        let engine = engine, fader = fadeNode, mixer = effectsChain.panMixer, format = file.processingFormat
        let failure = AMPCatchException {
            engine.disconnectNodeOutput(fader)
            engine.connect(fader, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: format)
        }
        if let failure {
            PlaybackLog.add("淡出节点连接失败：\(failure)")
            return false
        }
        // 尾巴带着这首自己的音量均衡淡出；下一首换了 gainAdjustment 也不影响它
        fadeTailGain = gainAdjustment
        fadeLevel = playerLevel
        applyEqualizer()
        fadeNode.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining), at: nil)
        fadeNode.play()
        fadeOutTimer = ramp(from: fadeLevel, to: 0, over: duration, set: { [weak self] in self?.fadeLevel = $0 }) { [weak self] in
            guard let self else { return }
            self.fadeNode.stop()
            self.engine.disconnectNodeOutput(self.fadeNode)
            self.fadeTailGain = nil
            self.fadeLevel = 0
            self.applyEqualizer()
        }
        return true
    }

    /// 刚开始播的这首从无声渐强
    public func fadeIn(duration: TimeInterval) {
        fadeInTimer?.invalidate()
        guard duration > 0 else { playerLevel = 1; updateNodeVolumes(); return }
        playerLevel = 0
        updateNodeVolumes()
        fadeInTimer = ramp(from: 0, to: 1, over: duration, set: { [weak self] in self?.playerLevel = $0 }, done: {})
    }

    /// 线性改音量（按听感用平方曲线）
    private func ramp(from: Float, to: Float, over duration: TimeInterval, set: @escaping @MainActor (Float) -> Void,
                      done: @escaping @MainActor () -> Void) -> Timer {
        let started = Date()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] timer in
            let finished = MainActor.assumeIsolated { () -> Bool in
                let t = Float(min(1, Date().timeIntervalSince(started) / duration))
                let eased = to > from ? t * t : 1 - (1 - t) * (1 - t)
                set(from + (to - from) * eased)
                self?.updateNodeVolumes()
                if t >= 1 { done() }
                return t >= 1
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// 停掉还在淡出的尾巴（暂停、停止、跳转时）
    private func cancelFades() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
        fadeNode.stop()
        fadeInTimer?.invalidate()
        fadeInTimer = nil
        playerLevel = 1
        fadeLevel = 0
        if fadeTailGain != nil {
            fadeTailGain = nil
            applyEqualizer()
        } else {
            updateNodeVolumes()
        }
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
                    PlaybackLog.add("耳机或蓝牙断开，暂停")
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
            PlaybackLog.add("被系统打断（来电、闹钟或其他 App）")
            resumeAfterInterruption = state == .playing
            pause()
        case .ended:
            PlaybackLog.add("打断结束，\(shouldResume && resumeAfterInterruption ? "继续播放" : "保持暂停")")
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
        let wasPlaying = state == .playing
        // 引擎此时多半已被系统停掉，读不到渲染时间：用最近记下的位置，而不是退回到 0 从头播
        let time = (engine.isRunning && playerNode.lastRenderTime != nil) ? currentTime : (wasPlaying ? lastObservedTime : pausedTime)
        PlaybackLog.add("输出设备变化，从 \(Int(time)) 秒继续（播放中：\(wasPlaying)）")
        guard let source else { return }
        stopNode()
        schedule(from: AVAudioFramePosition(time * source.format.sampleRate))
        pausedTime = time
        lastObservedTime = time
        if wasPlaying {
            do {
                try engine.start()
                playerNode.play()
            } catch {
                state = .paused
                PlaybackLog.add("输出设备变化后无法启动音频引擎：\(error.localizedDescription)")
                onStateChangedExternally?()
            }
        }
    }
}
