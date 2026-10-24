import Accelerate
import AVFoundation

/// 在音频线程上计算频谱和波形，UI 线程按帧读取快照。线程安全。
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 75
    private static let log2n: vDSP_Length = 10
    private static let fftSize = 1 << 10

    private let lock = NSLock()
    /// 可视化关闭、App 在后台或锁屏时关掉，不再每块音频都做 FFT
    nonisolated(unsafe) public var isEnabled = true
    private var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var waveform = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private let fftSetup: FFTSetup
    private let window: [Float]

    public init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// 0...1 的频谱条高度与 -1...1 的波形采样
    public func snapshot() -> (spectrum: [Float], waveform: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        return (spectrum, waveform)
    }

    /// 停止播放后让频谱逐渐落下
    public func decay() {
        lock.lock()
        for i in spectrum.indices { spectrum[i] = max(0, spectrum[i] - 0.05) }
        for i in waveform.indices { waveform[i] *= 0.5 }
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let n = Self.fftSize
        let sampleRate = Float(buffer.format.sampleRate)

        // 多声道混成单声道
        var mono = [Float](repeating: 0, count: n)
        let count = min(n, frames)
        for c in 0..<channelCount {
            let src = channels[c]
            for i in 0..<count { mono[i] += src[i] }
        }
        if channelCount > 1 {
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(count))
        }

        // 波形：均匀取样
        var wave = [Float](repeating: 0, count: Self.bandCount)
        for i in 0..<Self.bandCount {
            wave[i] = mono[min(count - 1, i * count / Self.bandCount)]
        }

        // FFT
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(mono, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // 对数分布到 75 个频段
        let minFreq: Float = 40, maxFreq: Float = min(16000, sampleRate / 2)
        let binWidth = sampleRate / Float(n)
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = minFreq * pow(maxFreq / minFreq, Float(b) / Float(Self.bandCount))
            let hi = minFreq * pow(maxFreq / minFreq, Float(b + 1) / Float(Self.bandCount))
            let loBin = max(1, Int(lo / binWidth))
            let hiBin = min(n / 2 - 1, max(loBin, Int(hi / binWidth)))
            var peak: Float = 0
            for k in loBin...hiBin { peak = max(peak, magnitudes[k]) }
            let db = 10 * log10(peak + 1e-12)
            bands[b] = ((db - 8) / 46).clamped(to: 0...1)
        }

        lock.lock()
        for i in 0..<Self.bandCount {
            spectrum[i] = max(bands[i], spectrum[i] - 0.06)
        }
        waveform = wave
        lock.unlock()
    }
}
