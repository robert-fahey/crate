import Accelerate
import Foundation

/// Key estimation: builds a 12-bin chroma profile of the audio and compares it
/// with the Krumhansl-Kessler major and minor key profiles. Assumes A = 440 Hz.
/// Right for most tonal music, unreliable for drum tracks and atonal material.
public enum KeyDetector {
    public struct Estimate: Equatable, Sendable {
        public var key: CamelotKey
        /// Correlation margin between the best and second-best key, 0...1.
        public var confidence: Double
    }

    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    public static func estimate(samples: [Float], sampleRate: Double) -> Estimate? {
        guard let chroma = chroma(samples: samples, sampleRate: sampleRate) else { return nil }
        return estimate(chroma: chroma)
    }

    static func estimate(chroma: [Double]) -> Estimate? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        var results: [(key: CamelotKey, correlation: Double)] = []
        for tonic in 0..<12 {
            for (profile, isMajor) in [(majorProfile, true), (minorProfile, false)] {
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                results.append((CamelotKey(pitchClass: tonic, isMajor: isMajor), correlation(chroma, rotated)))
            }
        }
        results.sort { $0.correlation > $1.correlation }
        guard let best = results.first, best.correlation > 0 else { return nil }
        let margin = best.correlation - results[1].correlation
        return Estimate(key: best.key, confidence: max(0, min(1, margin * 5)))
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
        var numerator = 0.0, squaresA = 0.0, squaresB = 0.0
        for index in a.indices {
            let da = a[index] - meanA, db = b[index] - meanB
            numerator += da * db
            squaresA += da * da
            squaresB += db * db
        }
        let denominator = (squaresA * squaresB).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }

    /// Energy per pitch class (C = 0) between about 65 Hz and 2 kHz.
    static func chroma(samples: [Float], sampleRate: Double) -> [Double]? {
        let n = 8192, half = n / 2, hop = n / 2
        guard samples.count >= n else { return nil }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var spectrum = [Double](repeating: 0, count: half)

        let frameCount = (samples.count - n) / hop + 1
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
                for bin in 1..<half { spectrum[bin] += Double(magnitudes[bin]) }
            }
        }

        // Records cut from tape are rarely tuned to exactly A = 440 Hz. Try tunings up to
        // 30 cents either way and keep the one where the energy sits closest to note
        // centres. Beyond that a note is as near to its neighbour, and naming it is a guess.
        let binHz = sampleRate / Double(n)
        var best: (sharpness: Double, chroma: [Double])?
        for tuning in stride(from: -0.3, through: 0.31, by: 0.1) {
            let folded = fold(spectrum: spectrum, binHz: binHz, tuning: tuning)
            if best == nil || folded.sharpness > best!.sharpness { best = folded }
        }
        return best?.chroma
    }

    /// Folds a magnitude spectrum into pitch classes, with notes shifted by `tuning` semitones.
    /// `sharpness` measures how much of the energy above 200 Hz lies near a note centre.
    static func fold(spectrum: [Double], binHz: Double, tuning: Double) -> (sharpness: Double, chroma: [Double]) {
        var chroma = [Double](repeating: 0, count: 12)
        var near = 0.0, total = 0.0
        for bin in 1..<spectrum.count {
            let frequency = Double(bin) * binHz
            guard frequency >= 65, frequency <= 2000 else { continue }
            let midi = 69 + 12 * log2(frequency / 440) - tuning
            let nearest = midi.rounded()
            let distance = abs(midi - nearest)
            if frequency >= 200 {
                total += spectrum[bin]
                if distance < 0.15 { near += spectrum[bin] }
            }
            guard distance < 0.35 else { continue }
            chroma[(Int(nearest) % 12 + 12) % 12] += spectrum[bin] * cos(distance / 0.35 * .pi / 2)
        }
        return (total > 0 ? near / total : 0, chroma)
    }
}
