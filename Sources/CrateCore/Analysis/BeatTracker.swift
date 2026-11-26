import Accelerate
import Foundation

/// Finds every beat in a track.
///
/// 1. The onset envelope (as used for tempo) is searched for the sequence of
///    beats that best fits it while staying close to the expected beat length
///    (dynamic programming, after Ellis 2007). A second pass uses the tempo the
///    first found around each moment, so a band that drifts is followed.
/// 2. Each beat is then moved onto the sharp attack of the drum nearest it. The
///    onset envelope is too coarse for that, and a kick's low-end swell peaks
///    tens of milliseconds after its attack, which is heard as dragging.
/// 3. The attacks are smoothed over a few bars, so one ghost note or missing
///    drum does not bend the grid. If the result is evenly spaced, the grid is
///    made exactly even.
///
/// Which of the beats start bars is a separate question, answered by `BarFinder`.
public enum BeatTracker {
    /// Raised whenever the tracker gets better at its job, so grids it made earlier are made again.
    /// Grids corrected by hand are left alone.
    public static let version = 3
    /// How strongly beats are held to the expected spacing.
    static let tightness: Float = 100
    /// How far from the first-pass beat an attack is looked for, in seconds.
    static let attackWindow = 0.04
    /// How closely the markers must reproduce the tracked beats, in seconds. Looser
    /// means fewer markers to look at, but every millisecond given away here is a
    /// millisecond of timing error in Sync.
    public static let markerTolerance = 0.002
    /// How much more the bass must jump between the beats than on them before the grid is moved half a beat.
    static let offBeatMargin = 1.5
    /// How much extra the bass counts when looking for beats. Without it the tracker is as happy
    /// on the off-beat hi-hat as on the kick, and can swap between them from one section to the next.
    static let kickWeight: Float = 6

    /// - Parameters:
    ///   - samples: mono audio, the whole track. Around 11 kHz is plenty.
    ///   - bpm: the track's tempo, from a tag or `BPMDetector`.
    public static func track(samples: [Float], sampleRate: Double, bpm: Double) -> BeatGrid? {
        guard bpm > 20, sampleRate > 0 else { return nil }
        // Music with a fixed tempo gets a grid that is a ruler; counting its beats one by one only invites mistakes.
        if var grid = SteadyTempo.grid(samples: samples, sampleRate: sampleRate, bpm: bpm)?.grid {
            let bars = BarFinder.find(grid: grid, samples: samples, sampleRate: sampleRate)
            grid.downbeat = bars.downbeat
            grid.phrase = bars.phrase
            return grid
        }
        return follow(samples: samples, sampleRate: sampleRate, bpm: bpm)
    }

    /// Finds the beats one by one, for music whose tempo moves: a band playing live.
    static func follow(samples: [Float], sampleRate: Double, bpm: Double) -> BeatGrid? {
        guard bpm > 20, sampleRate > 0 else { return nil }
        var envelope = BPMDetector.onsetEnvelope(samples: samples, bassWeight: kickWeight)
        let fps = sampleRate / Double(BPMDetector.hop)
        let duration = Double(samples.count) / sampleRate
        guard envelope.count > Int(fps * 8) else { return nil }

        // Scale so the tightness means the same for a quiet track as a loud one.
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(envelope, 1, nil, 1, &mean, &deviation, vDSP_Length(envelope.count))
        if deviation > 0 {
            var scale = 1 / deviation
            vDSP_vsmul(envelope, 1, &scale, &envelope, 1, vDSP_Length(envelope.count))
        }

        let period = Float(60 / bpm * fps)
        var frames = search(envelope, period: [Float](repeating: period, count: envelope.count))
        guard frames.count >= 8 else { return nil }
        frames = search(envelope, period: localPeriods(beats: frames, count: envelope.count, fallback: period))
        guard frames.count >= 8 else { return nil }

        // A change in the spectrum shows up most strongly a little after it enters the analysis window.
        let offset = Double(BPMDetector.frameSize) * 0.75
        let coarse = frames.map { (Double($0) * Double(BPMDetector.hop) + offset) / sampleRate }
        var refined = refine(coarse, samples: samples, sampleRate: sampleRate)
        // The first pass can settle half a beat out, on the off-beat hi-hat. The kick gives it away:
        // if the bass jumps between the beats much more than on them, the beats are the in-betweens.
        let bass = SteadyTempo.bassLevel(samples: samples, sampleRate: sampleRate)
        let between = zip(refined.beats, refined.beats.dropFirst()).map { ($0 + $1) / 2 }
        let onBeats = SteadyTempo.bassRise(bass, sampleRate: sampleRate, at: refined.beats)
        let offBeats = SteadyTempo.bassRise(bass, sampleRate: sampleRate, at: between)
        if between.count >= 8, offBeats > onBeats * offBeatMargin { refined = refine(between, samples: samples, sampleRate: sampleRate) }
        var beats = refined.beats

        // Carry the grid out to both ends of the track.
        if beats.count > 1 {
            let first = beats[1] - beats[0], last = beats[beats.count - 1] - beats[beats.count - 2]
            while beats[0] - first >= 0 { beats.insert(beats[0] - first, at: 0) }
            while beats[beats.count - 1] + last <= duration { beats.append(beats[beats.count - 1] + last) }
        }
        // Reduce the beats to markers, as an editor would place them.
        var grid = BeatGrid(beats: beats, isSteady: refined.isSteady).withMarkers(tolerance: markerTolerance)
        let bars = BarFinder.find(grid: grid, samples: samples, sampleRate: sampleRate)
        grid.downbeat = bars.downbeat
        grid.phrase = bars.phrase
        return grid
    }

    // MARK: Step 1: the best-fitting sequence of beats

    /// Frame indices of the beats, given the expected beat length at each frame.
    static func search(_ envelope: [Float], period: [Float]) -> [Int] {
        let count = envelope.count
        var score = [Float](repeating: 0, count: count)
        var previous = [Int32](repeating: -1, count: count)
        for frame in 0..<count {
            let expected = max(2, period[frame])
            let earliest = frame - Int(expected * 2), latest = frame - Int(expected / 2)
            var best = -Float.greatestFiniteMagnitude
            var bestFrame: Int32 = -1
            if latest >= 0 {
                for candidate in max(0, earliest)...latest {
                    let stretch = log(Float(frame - candidate) / expected)
                    let value = score[candidate] - tightness * stretch * stretch
                    if value > best {
                        best = value
                        bestFrame = Int32(candidate)
                    }
                }
            }
            score[frame] = envelope[frame] + (bestFrame >= 0 ? best : 0)
            previous[frame] = bestFrame
        }
        // Start from the best-scoring frame in the last beat or so and walk back.
        let tail = max(0, count - Int(max(2, period[count - 1]) * 1.5))
        var frame = (tail..<count).max { score[$0] < score[$1] } ?? count - 1
        var beats: [Int] = []
        while frame >= 0 {
            beats.append(frame)
            frame = Int(previous[frame])
        }
        return beats.reversed()
    }

    /// The beat length around each frame, from the spacing of the beats found so far.
    static func localPeriods(beats: [Int], count: Int, fallback: Float) -> [Float] {
        guard beats.count > 4 else { return [Float](repeating: fallback, count: count) }
        let intervals = zip(beats, beats.dropFirst()).map { Float($1 - $0) }
        // Median over four bars: steady against a single odd interval, quick enough to follow drift.
        var smoothed = [Float](repeating: fallback, count: intervals.count)
        for index in intervals.indices {
            let window = intervals[max(0, index - 8)...min(intervals.count - 1, index + 8)].sorted()
            smoothed[index] = window[window.count / 2]
        }
        var periods = [Float](repeating: fallback, count: count)
        var beat = 0
        for frame in 0..<count {
            while beat < beats.count - 2, frame >= beats[beat + 1] { beat += 1 }
            periods[frame] = smoothed[min(beat, smoothed.count - 1)]
        }
        return periods
    }

    // MARK: Steps 2 and 3: onto the drum attacks, then smoothed

    static func refine(_ coarse: [Double], samples: [Float], sampleRate: Double) -> (beats: [Double], isSteady: Bool) {
        let attacks = attackTimes(near: coarse, samples: samples, sampleRate: sampleRate)
        let count = coarse.count
        let offsets = (0..<count).map { attacks[$0].time - coarse[$0] }

        // An attack far from what its neighbours say is a ghost note or a fill, not the beat.
        var weights = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let window = (max(0, index - 8)...min(count - 1, index + 8)).filter { attacks[$0].strength > 0 }
            guard window.count >= 3, attacks[index].strength > 0 else { continue }
            let nearby = window.map { offsets[$0] }.sorted()
            let median = nearby[nearby.count / 2]
            if abs(offsets[index] - median) <= 0.012 { weights[index] = min(1, attacks[index].strength) }
        }
        let confident = weights.filter { $0 > 0 }.count
        guard confident >= max(8, count / 5) else { return (coarse, false) }  // too few drums to improve on the first pass

        // The whole track as one straight line. If the attacks sit on it, the tempo is fixed.
        let indices = (0..<count).map(Double.init)
        let times = (0..<count).map { attacks[$0].time }
        let line = fitLine(x: indices, y: times, weights: weights)
        var worst = 0.0, squares = 0.0, total = 0.0
        for index in 0..<count where weights[index] > 0 {
            let miss = times[index] - (line.intercept + line.slope * Double(index))
            squares += weights[index] * miss * miss
            total += weights[index]
        }
        // The largest drift from the line over any stretch of four bars.
        for start in stride(from: 0, to: count, by: 8) {
            let window = (start..<min(count, start + 16)).filter { weights[$0] > 0 }
            guard window.count >= 6 else { continue }
            let misses = window.map { times[$0] - (line.intercept + line.slope * Double($0)) }.sorted()
            worst = max(worst, abs(misses[misses.count / 2]))
        }
        if (squares / total).squareRoot() < 0.006, worst < 0.007 {
            return ((0..<count).map { line.intercept + line.slope * Double($0) }, true)
        }

        // Otherwise follow the band: each beat from a straight line through the attacks two bars either side.
        var beats = coarse
        for index in 0..<count {
            let from = max(0, index - 8), to = min(count - 1, index + 8)
            let window = Array(from...to)
            let local = window.map { weights[$0] }
            guard local.filter({ $0 > 0 }).count >= 4 else {
                // No drums here: keep the first-pass beat, moved by what the nearest drums suggest.
                let nearby = (max(0, index - 16)...min(count - 1, index + 16)).filter { weights[$0] > 0 }.map { offsets[$0] }.sorted()
                if !nearby.isEmpty { beats[index] = coarse[index] + nearby[nearby.count / 2] }
                continue
            }
            let fit = fitLine(x: window.map(Double.init), y: window.map { times[$0] }, weights: local)
            beats[index] = fit.intercept + fit.slope * Double(index)
        }
        // Smoothing must never put beats out of order.
        for index in 1..<count where beats[index] <= beats[index - 1] { beats[index] = beats[index - 1] + 0.05 }
        return (beats, false)
    }

    static func fitLine(x: [Double], y: [Double], weights: [Double]) -> (intercept: Double, slope: Double) {
        var sum = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        for index in x.indices {
            let weight = weights[index]
            sum += weight
            sumX += weight * x[index]
            sumY += weight * y[index]
            sumXX += weight * x[index] * x[index]
            sumXY += weight * x[index] * y[index]
        }
        let denominator = sum * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { return (sum > 0 ? sumY / sum : 0, 0) }
        let slope = (sum * sumXY - sumX * sumY) / denominator
        return ((sumY - slope * sumX) / sum, slope)
    }

    /// For each rough beat time, the start of the sharpest attack within `attackWindow` of it,
    /// and how much that attack stands out (0 when there is nothing there).
    static func attackTimes(near beats: [Double], samples: [Float], sampleRate: Double) -> [(time: Double, strength: Double)] {
        let count = samples.count
        let level = attackLevel(samples: samples, sampleRate: sampleRate)
        let reach = Int(attackWindow * sampleRate)
        let lag = max(1, Int(0.003 * sampleRate))
        return beats.map { beat in
            let center = Int(beat * sampleRate)
            let from = max(lag, center - reach), to = min(count - 1, center + reach)
            guard from < to else { return (beat, 0) }
            var best = from
            var bestRise: Float = 0
            var total: Float = 0
            for index in from...to {
                let rise = level[index] - level[index - lag]
                if rise > bestRise {
                    bestRise = rise
                    best = index
                }
                total += level[index]
            }
            let average = total / Float(to - from + 1)
            guard bestRise > 0, average > 0 else { return (beat, 0) }
            // The steepest rise is partway up the attack; its start is where the level leaves the floor.
            let floor = level[best - lag]
            var start = best
            while start > from, level[start - 1] > floor + bestRise * 0.15 { start -= 1 }
            return (Double(start) / sampleRate, Double(bestRise / average) / 2)
        }
    }

    /// Brightness is what makes an attack sharp, so this is the level of the signal's
    /// sample-to-sample change, which favours the click of a drum over its body.
    static func attackLevel(samples: [Float], sampleRate: Double) -> [Float] {
        let count = samples.count
        var level = [Float](repeating: 0, count: count)
        let smoothing = Float(1 - exp(-1 / (0.0015 * sampleRate)))
        var running: Float = 0
        for index in 1..<max(1, count) {
            let change = abs(samples[index] - samples[index - 1])
            running += (change - running) * smoothing
            level[index] = running
        }
        return level
    }
}
