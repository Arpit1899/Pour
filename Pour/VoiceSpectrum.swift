import Accelerate
import AVFoundation

/// What the voice sounds like right now, not just how loud it is.
nonisolated struct VoiceSpectrum: Equatable, Sendable {
    /// Energy in 80-300 Hz, 300 Hz-1 kHz, 1-3 kHz and 3-8 kHz, each 0...1.
    var bands: SIMD4<Float> = .zero

    static let silent = VoiceSpectrum()
}

/// One 1024-point FFT per tap buffer. Made once per engine and only used from
/// the tap, so it can keep its scratch buffers between calls.
nonisolated final class VoiceSpectrumAnalyzer: @unchecked Sendable {
    private static let log2n: vDSP_Length = 10
    private static let n = 1 << 10
    private static let edges: [Double] = [80, 300, 1000, 3000, 8000]
    /// A band's power in dB below a full scale sine that reads as silent; 32 dB
    /// above that reads as full. Speech is quieter the higher you go.
    private static let floors: SIMD4<Float> = [-47, -49, -60, -61]
    private static let range: Float = 32

    private let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: n, isHalfWindow: false)
    private var frame = [Float](repeating: 0, count: n)
    private var real = [Float](repeating: 0, count: n / 2)
    private var imag = [Float](repeating: 0, count: n / 2)
    private var power = [Float](repeating: 0, count: n / 2)

    func analyze(_ buffer: AVAudioPCMBuffer) -> VoiceSpectrum {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return .silent }
        let n = Self.n
        let count = Int(buffer.frameLength)
        // The newest 1024 samples, zero padded if the buffer is shorter.
        let used = min(n, count)
        frame.withUnsafeMutableBufferPointer { f in
            f.update(repeating: 0)
            f.baseAddress!.update(from: samples + (count - used), count: used)
        }
        vDSP.multiply(frame, window, result: &frame)

        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                // Bin 0 holds DC and Nyquist; neither is voice.
                re[0] = 0; im[0] = 0
                vDSP.squareMagnitudes(split, result: &power)
            }
        }

        let hz = buffer.format.sampleRate / Double(n)
        let top = n / 2 - 1
        // A full scale sine through this window and FFT has power n² / 4.
        let reference = Float(n * n) / 4
        var bands = SIMD4<Float>.zero
        for b in 0..<4 {
            let lo = max(1, Int(Self.edges[b] / hz))
            let hi = min(top, Int(Self.edges[b + 1] / hz) - 1)
            guard lo <= hi else { continue }
            var sum: Float = 0
            for k in lo...hi { sum += power[k] }
            let db = 10 * log10f(sum / reference + 1e-12)
            bands[b] = min(1, max(0, (db - Self.floors[b]) / Self.range))
        }
        return VoiceSpectrum(bands: bands)
    }
}
