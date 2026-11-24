import Foundation

/// Finds the sharp attacks in a track: drum hits, mostly. The grid editor shows
/// them as ticks and snaps markers to them.
public enum TransientDetector {
    /// Tracks longer than this are skipped: a recorded hour-long mix has tens of thousands of hits.
    public static let longestTrack = 20.0 * 60

    /// Attack times in seconds, ascending.
    public static func find(in audio: TrackAudio) -> [Double] {
        guard audio.duration <= longestTrack, audio.frames > 0 else { return [] }
        // Mono at about 11 kHz is plenty, and a quarter of the work.
        let factor = max(1, Int((audio.sampleRate / 11025).rounded()))
        let count = audio.frames / factor
        var mono = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0
            for offset in 0..<factor { sum += audio.left[index * factor + offset] + audio.right[index * factor + offset] }
            mono[index] = sum / Float(factor * 2)
        }
        return find(samples: mono, sampleRate: audio.sampleRate / Double(factor))
    }

    static func find(samples: [Float], sampleRate: Double) -> [Double] {
        attacks(samples: samples, sampleRate: sampleRate).map(\.time)
    }

    /// Attacks with how far each stands out from what is around it (1 is a clear hit).
    static func attacks(samples: [Float], sampleRate: Double) -> [SteadyTempo.Attack] {
        let count = samples.count
        guard count > Int(sampleRate) else { return [] }
        let level = BeatTracker.attackLevel(samples: samples, sampleRate: sampleRate)
        let lag = max(1, Int(0.003 * sampleRate))
        var rise = [Float](repeating: 0, count: count)
        for index in lag..<count { rise[index] = max(0, level[index] - level[index - lag]) }

        // An attack stands well clear of what is going on around it.
        let window = Int(sampleRate * 0.5)
        var prefix = [Float](repeating: 0, count: count + 1)
        for index in 0..<count { prefix[index + 1] = prefix[index] + rise[index] }
        let reach = Int(0.03 * sampleRate)
        var found: [SteadyTempo.Attack] = []
        var index = lag
        while index < count {
            let from = max(0, index - window), to = min(count, index + window)
            let around = (prefix[to] - prefix[from]) / Float(to - from)
            guard rise[index] > around * 6, rise[index] > 0.002 else {
                index += 1
                continue
            }
            // The steepest point of this attack, within 30 ms.
            var best = index
            for candidate in index..<min(count, index + reach) where rise[candidate] > rise[best] { best = candidate }
            // Its start: where the level leaves the floor.
            let floor = level[max(0, best - lag)]
            var start = best
            while start > max(0, best - reach), level[start - 1] > floor + rise[best] * 0.15 { start -= 1 }
            found.append(SteadyTempo.Attack(time: Double(start) / sampleRate, strength: min(1, Double(rise[best] / max(1e-9, around)) / 24)))
            index = best + reach  // one attack per 30 ms
        }
        return found
    }
}
