import AVFoundation
import AmplayerCore
import AmplayerObjC

/// 音效处理链（在经典 10 段均衡器前后）：
/// 播放节点 → 声像混音（平衡、环绕旋转）→ 变速变调 → [10 段 EQ] → 音色 → 响度均衡 → 回声 → 混响 → 主混音
/// 另有一个黑胶底噪发生器直接接主混音。不用的环节一律旁路。
@MainActor
final class EffectsChain {
    /// 第一级混音节点：平衡和环绕旋转的声像在这里做，单声道音源也在这里转成立体声（8D 旋转才有左右）
    let panMixer = AVAudioMixerNode()
    let timePitch = AVAudioUnitTimePitch()
    let tone = AVAudioUnitEQ(numberOfBands: 3)
    let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    private let noise = NoiseState()
    private lazy var noiseNode: AVAudioSourceNode = Self.makeNoiseNode(noise)

    func attach(to engine: AVAudioEngine) {
        for node in [panMixer, timePitch, tone, dynamics, delay, reverb] as [AVAudioNode] { engine.attach(node) }
        engine.attach(noiseNode)
        let bands = tone.bands
        bands[0].filterType = .lowShelf; bands[0].frequency = 90
        bands[1].filterType = .parametric; bands[1].frequency = 3000; bands[1].bandwidth = 1.2
        bands[2].filterType = .highShelf; bands[2].frequency = 9000
        for b in bands { b.gain = 0; b.bypass = false }
        delay.feedback = 22
        delay.lowPassCutoff = 7000
        engine.connect(noiseNode, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
    }

    /// 播放节点 → … → 均衡器 → … → 主混音。fileFormat 是音源格式；声像混音之后统一成立体声
    /// 输出设备正在切换（刚连上 CarPlay、蓝牙）时系统可能拒绝连接，这里把异常转成 Swift 错误
    func connect(player: AVAudioPlayerNode, equalizer: AVAudioUnitEQ, fileFormat: AVAudioFormat, in engine: AVAudioEngine) throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: fileFormat.sampleRate, channels: 2)!
        let nodes: [AVAudioNode] = [player, panMixer, timePitch, equalizer, tone, dynamics, delay, reverb]
        let chain: [AVAudioNode] = [panMixer, timePitch, equalizer, tone, dynamics, delay, reverb, engine.mainMixerNode]
        let failure = AMPCatchException {
            for node in nodes { engine.disconnectNodeOutput(node) }
            engine.connect(player, to: chain[0], format: fileFormat)
            for (a, b) in zip(chain, chain.dropFirst()) {
                engine.connect(a, to: b, format: stereo)
            }
        }
        if let failure { throw AudioEngineError(reason: failure) }
    }

    func apply(_ e: SoundEffects) {
        // 变速变调
        timePitch.rate = e.rate.clamped(to: 0.5...2)
        timePitch.pitch = (e.pitch * 100).clamped(to: -1200...1200)
        timePitch.bypass = abs(e.rate - 1) < 0.001 && abs(e.pitch) < 0.01
        // 音色
        tone.bands[0].gain = e.bass.clamped(to: -12...12)
        tone.bands[1].gain = e.vocal.clamped(to: -12...12)
        tone.bands[2].gain = e.treble.clamped(to: -12...12)
        tone.bypass = e.bass == 0 && e.vocal == 0 && e.treble == 0
        // 响度均衡：压缩后整体提升；低音提得多时也靠它防止削波
        if e.loudness || e.bass > 6 {
            setDynamics(kDynamicsProcessorParam_Threshold, e.loudness ? -26 : -14)
            setDynamics(kDynamicsProcessorParam_HeadRoom, 6)
            setDynamics(kDynamicsProcessorParam_AttackTime, 0.004)
            setDynamics(kDynamicsProcessorParam_ReleaseTime, 0.25)
            setDynamics(kDynamicsProcessorParam_OverallGain, e.loudness ? 8 : 2)
            dynamics.bypass = false
        } else {
            dynamics.bypass = true
        }
        // 回声
        delay.delayTime = TimeInterval(e.echoTime.clamped(to: 0.01...1.5))
        delay.wetDryMix = e.echoMix.clamped(to: 0...100)
        delay.bypass = e.echoMix <= 0
        // 混响
        reverb.loadFactoryPreset(Self.factoryPreset(e.reverbType))
        reverb.wetDryMix = e.reverbMix.clamped(to: 0...100)
        reverb.bypass = e.reverbMix <= 0
        // 黑胶底噪
        noise.level = e.vinylNoise.clamped(to: 0...1)
    }

    private func setDynamics(_ param: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(dynamics.audioUnit, param, kAudioUnitScope_Global, 0, value, 0)
    }

    private static func factoryPreset(_ r: SoundEffects.Reverb) -> AVAudioUnitReverbPreset {
        switch r {
        case .room: .mediumRoom
        case .studio: .smallRoom
        case .hall: .mediumHall
        case .largeHall: .largeHall2
        case .cathedral: .cathedral
        case .plate: .plate
        }
    }

    // MARK: 黑胶底噪

    /// 渲染线程读、主线程写的一个浮点数；偶尔读到旧值无所谓
    final class NoiseState: @unchecked Sendable {
        var level: Float = 0
        var seed: UInt32 = 0x9E37_79B9
        var lowpass: Float = 0
        var crackle: Float = 0
    }

    /// 渲染回调在音频线程上执行，必须在 nonisolated 上下文里创建（否则继承 MainActor 隔离会崩溃）
    private nonisolated static func makeNoiseNode(_ state: NoiseState) -> AVAudioSourceNode {
        AVAudioSourceNode { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let level = state.level
            // 没开底噪：整块清零并标记静音，下游可以跳过
            guard level > 0 else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                isSilence.pointee = true
                return noErr
            }
            for frame in 0..<Int(frameCount) {
                var sample: Float = 0
                do {
                    state.seed ^= state.seed << 13; state.seed ^= state.seed >> 17; state.seed ^= state.seed << 5
                    let white = Float(state.seed) / Float(UInt32.max) * 2 - 1
                    // 低通后的沙沙声
                    state.lowpass += 0.08 * (white - state.lowpass)
                    sample = state.lowpass * 0.012 * level
                    // 偶尔一声爆豆
                    if state.seed % 9000 == 0 { state.crackle = (white > 0 ? 1 : -1) * 0.25 * level }
                    sample += state.crackle
                    state.crackle *= 0.62
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
    }
}
