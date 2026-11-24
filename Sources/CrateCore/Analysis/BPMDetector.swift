import Accelerate
import Foundation

/// Tempo estimation for music with a steady beat.
///
/// Method: spectral-flux onset envelope, autocorrelation, then a search over
/// candidate tempos scoring the autocorrelation at 1, 2, 4, 8 and 16 beats.
/// Long lags give the precision; a prior centred on 120 BPM settles whether a
/// track is, say, 62, 124 or 248. That last choice is a guess by nature, which
/// is why the app offers half/double buttons.
public enum BPMDetector {
    public struct Estimate: Equatable, Sendable {
        public var bpm: Double
        /// How far the winning tempo stands out from the rest, roughly 0...1.
        public var confidence: Double
    }

    public static let range: ClosedRange<Double> = 70...180

    static let frameSize = 1024
    static let hop = 64

    /// - Parameters:
    ///   - samples: mono audio.
    ///   - sampleRate: of `samples`. Around 11–12 kHz is plenty.
    public static func estimate(samples: [Float], sampleRate: Double) -> Estimate? {
        let envelope = onsetEnvelope(samples: samples)
        let fps = sampleRate / Double(hop)
        // Needs enough audio to see 16 beats at the slowest tempo several times over.
        guard Double(envelope.count) / fps >= 20 else { return nil }

        let maxLag = min(envelope.count / 2, Int((16 * 60 / range.lowerBound * fps).rounded(.up)) + 2)
        let acf = autocorrelation(envelope, maxLag: maxLag)
        guard acf[0] > 0 else { return nil }

        func value(atLag lag: Double) -> Double {
            let lower = Int(lag)
            guard lower + 1 < acf.count else { return 0 }
            let fraction = lag - Double(lower)
            return Double(acf[lower]) * (1 - fraction) + Double(acf[lower + 1]) * fraction
        }
        func score(_ bpm: Double, multiples: [Double]) -> Double {
            let period = 60 / bpm * fps
            var total = 0.0, used = 0.0
            for multiple in multiples where period * multiple + 1 < Double(acf.count) {
                total += value(atLag: period * multiple)
                used += 1
            }
            return used > 0 ? total / used : 0
        }
        func prior(_ bpm: Double) -> Double {
            let octaves = log2(bpm / 120)
            return exp(-0.5 * (octaves / 0.45) * (octaves / 0.45))
        }

        // Coarse pass over the whole range.
        var best = (bpm: 0.0, score: -Double.infinity)
        var scores: [Double] = []
        var bpm = range.lowerBound
        while bpm <= range.upperBound {
            let raw = score(bpm, multiples: [1, 2, 4, 8])
            scores.append(raw)
            let weighted = raw * prior(bpm)
            if weighted > best.score { best = (bpm, weighted) }
            bpm += 0.1
        }
        guard best.score > 0 else { return nil }

        // Fine pass near the winner, using the longest lags for precision.
        var refined = (bpm: best.bpm, score: -Double.infinity)
        var candidate = best.bpm - 0.6
        while candidate <= best.bpm + 0.6 {
            let value = score(candidate, multiples: [4, 8, 16])
            if value > refined.score { refined = (candidate, value) }
            candidate += 0.01
        }

        let mean = scores.reduce(0, +) / Double(scores.count)
        let peak = score(refined.bpm, multiples: [1, 2, 4, 8])
        let confidence = max(0, min(1, (peak - mean) / Double(acf[0])))
        return Estimate(bpm: (refined.bpm * 100).rounded() / 100, confidence: confidence)
    }

    /// Positive spectral change per frame: large where new sounds start.
    /// `bassWeight` counts change below about 150 Hz that many times over again, which makes
    /// the kick drum stand out from the hats; the beat tracker uses it to stay on the kick.
    static func onsetEnvelope(samples: [Float], bassWeight: Float = 0) -> [Float] {
        let n = frameSize, half = n / 2
        guard samples.count >= n * 2 else { return [] }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)

        let frameCount = (samples.count - n) / hop + 1
        var envelope = [Float](repeating: 0, count: frameCount)

        samples.withUnsafeBufferPointer { input in
            for index in 0..<frameCount {
                vDSP_vmul(input.baseAddress! + index * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                real.withUnsafeMutableBufferPointer { realPointer in
                    imag.withUnsafeMutableBufferPointer { imagPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                        frame.withUnsafeBufferPointer { framePointer in
                            framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
                var flux: Float = 0
                for bin in 1..<half {
                    // Log compression stops a loud kick drowning out everything else.
                    let level = log1p(magnitudes[bin] * 0.05)
                    let rise = level - previous[bin]
                    if rise > 0 { flux += bin <= 14 ? rise * (1 + bassWeight) : rise }
                    previous[bin] = level
                }
                envelope[index] = flux
            }
        }

        // Remove the slow-moving average so sustained loudness is not mistaken for rhythm.
        let span = 44  // about a quarter of a second
        var smoothed = [Float](repeating: 0, count: frameCount)
        var running: Float = 0
        for index in 0..<frameCount {
            running += envelope[index]
            if index >= span { running -= envelope[index - span] }
            smoothed[index] = running / Float(min(index + 1, span))
        }
        for index in 0..<frameCount {
            envelope[index] = max(0, envelope[index] - smoothed[index])
        }
        return envelope
    }

    static func autocorrelation(_ signal: [Float], maxLag: Int) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(signal.count))
        var centred = [Float](repeating: 0, count: signal.count)
        var negativeMean = -mean
        vDSP_vsadd(signal, 1, &negativeMean, &centred, 1, vDSP_Length(signal.count))

        var result = [Float](repeating: 0, count: maxLag + 1)
        centred.withUnsafeBufferPointer { pointer in
            for lag in 0...maxLag {
                let count = signal.count - lag
                var dot: Float = 0
                vDSP_dotpr(pointer.baseAddress!, 1, pointer.baseAddress! + lag, 1, &dot, vDSP_Length(count))
                result[lag] = dot / Float(count)
            }
        }
        return result
    }
}
