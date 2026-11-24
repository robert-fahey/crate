import Foundation

/// Finds the fixed tempo of music made with a drum machine or a sequencer.
///
/// Such a track has one exact tempo from start to finish, and its grid should be
/// a ruler: one beat length, one starting point. Following the drums beat by
/// beat, as is right for a live band, goes wrong here, because every breakdown
/// is a chance to lose count, and a grid that has lost count wanders.
///
/// So this ignores the count. All the drum attacks in the track are folded onto
/// one beat length; at the right length they pile up at a few places in the beat
/// (the kick, the off-beat hat, the sixteenths), however many breakdowns come
/// between them. The pile with the most bass under it is the kick: the beat.
///
/// A recording that keeps count but slides a few milliseconds around its tempo
/// (tape, vinyl, a hardware sequencer) is followed along that slide. A band
/// playing live fits no fixed tempo at all, and is left to `BeatTracker.follow`.
public enum SteadyTempo {
    public struct Attack: Sendable {
        public var time: Double
        public var strength: Double
    }

    /// One place in the beat where attacks pile up, as a possible position for the grid.
    public struct Candidate: Sendable {
        /// Seconds per beat.
        public var period: Double
        /// Time of one beat. Every beat is this plus a whole number of periods.
        public var anchor: Double
        /// Share of the attacks' weight that sits on this candidate.
        public var weight: Double
        /// How much the bass rises just after these beats, against the track's average level.
        public var bass: Double
        /// Share of the track, in four-bar stretches, where at least half the beats have a drum on them.
        public var covered: Double
        /// Of those stretches, the share where the drums sit within 3 ms of the grid.
        public var tight: Double
        /// Typical distance of a drum from its beat, in seconds.
        public var spread: Double

        public var bpm: Double { 60 / period }
        /// True when the drums keep to this grid all the way through. A band playing live
        /// fails on every count: little of the track is covered, and what is covered is
        /// there by chance, spread evenly across the 8 ms allowed (about 4.5 ms typical).
        public var isSteady: Bool { covered >= 0.4 && tight >= 0.85 && spread <= 0.0036 }
        /// How likely this is the kick drum: plenty of attacks, with bass under them. A track bounced
        /// from a computer starts exactly on a beat, so a candidate with a beat at the very start of
        /// the file counts double. (Across this kind of music the two clues nearly always agree.)
        var kick: Double { weight * (0.3 + bass) * (min(anchor, period - anchor) < 0.012 ? 2 : 1) }
    }

    /// How close to a beat an attack must be to count as on it, in seconds.
    static let onBeat = 0.008

    /// - Parameters:
    ///   - samples: mono audio, the whole track, at about 11 kHz.
    ///   - bpm: the tempo to look around (3% either side).
    /// - Returns: the possible grids, best first; empty when the attacks keep to no fixed tempo.
    public static func candidates(samples: [Float], sampleRate: Double, bpm: Double) -> [Candidate] {
        let duration = Double(samples.count) / sampleRate
        guard bpm > 20, duration > 20, duration <= TransientDetector.longestTrack else { return [] }
        let attacks = TransientDetector.attacks(samples: samples, sampleRate: sampleRate)
        return candidates(attacks: attacks, samples: samples, sampleRate: sampleRate, bpm: bpm)
    }

    static func candidates(attacks: [Attack], samples: [Float], sampleRate: Double, bpm: Double) -> [Candidate] {
        let duration = Double(samples.count) / sampleRate
        guard attacks.count >= 32 else { return [] }
        let period = bestPeriod(attacks: attacks, around: 60 / bpm)
        let bass = bassLevel(samples: samples, sampleRate: sampleRate)
        var found: [Candidate] = []
        for phase in pileUps(attacks: attacks, period: period) {
            guard var candidate = refine(attacks: attacks, period: period, anchor: phase, duration: duration) else { continue }
            candidate.bass = bassRise(bass, sampleRate: sampleRate, candidate: candidate, duration: duration)
            found.append(candidate)
        }
        return found.sorted { $0.weight > $1.weight }
    }

    /// How a grid was arrived at.
    public enum Kind: String, Sendable {
        /// One exact tempo throughout.
        case fixed
        /// A fixed tempo that the recording wanders around by a few milliseconds (tape, vinyl, a hardware sequencer).
        case drifting
    }

    /// The beat grid of a track with a fixed tempo, or nil when its drums keep to none
    /// (a live band), in which case the beats have to be followed one by one.
    public static func grid(samples: [Float], sampleRate: Double, bpm: Double) -> (grid: BeatGrid, kind: Kind)? {
        let duration = Double(samples.count) / sampleRate
        guard bpm > 20, duration > 20, duration <= TransientDetector.longestTrack else { return nil }
        let attacks = TransientDetector.attacks(samples: samples, sampleRate: sampleRate)
        let found = candidates(attacks: attacks, samples: samples, sampleRate: sampleRate, bpm: bpm)
        guard let widest = found.max(by: { $0.covered < $1.covered }) else { return nil }
        // The kick is the pile with the most bass under it, among those present for most of the track.
        guard let kick = found.filter({ $0.covered >= widest.covered * 0.5 }).max(by: { $0.kick < $1.kick }) else { return nil }

        // Any one part of the kit keeping exact time proves the tempo is fixed; the cleanest one measures it best.
        if let proof = found.filter(\.isSteady).min(by: { $0.spread / max(0.1, $0.covered) < $1.spread / max(0.1, $1.covered) }) {
            // Music made on a computer is nearly always at a whole number of beats a minute. Where the
            // measured tempo is that close to one (under 6 ms apart by the end of the track), it is the whole number.
            var period = proof.period
            let whole = 60 / (60 / period).rounded()
            let length = (attacks.last?.time ?? 0) - (attacks.first?.time ?? 0)
            if abs(whole - period) / period * length < 0.006 { period = whole }
            var anchor = position(of: kick, attacks: attacks, period: period)
            anchor -= (anchor / period).rounded(.down) * period
            var beats: [Double] = []
            var index = 0.0
            while anchor + index * period <= duration {
                beats.append(anchor + index * period)
                index += 1
            }
            guard beats.count >= 8 else { return nil }
            return (BeatGrid(beats: beats, isSteady: true).withMarkers(tolerance: BeatTracker.markerTolerance), .fixed)
        }
        // The count holds all the way through, but the recording wanders: follow the wander.
        guard widest.covered >= 0.6, kick.covered >= 0.5 else { return nil }
        let beats = followDrift(of: kick, attacks: attacks, duration: duration)
        guard beats.count >= 8 else { return nil }
        return (BeatGrid(beats: beats, isSteady: false).withMarkers(tolerance: BeatTracker.markerTolerance), .drifting)
    }

    /// Where a candidate's beats sit when the beat length is fixed from elsewhere: the time of one of its beats.
    static func position(of candidate: Candidate, attacks: [Attack], period: Double) -> Double {
        // Re-measure against the middle of the track, so a small difference in beat length tilts about the centre.
        let middle = ((attacks.last?.time ?? 0) / 2 - candidate.anchor) / candidate.period
        let pivot = candidate.anchor + middle.rounded() * candidate.period
        var total = 0.0, weight = 0.0
        for attack in attacks {
            let beat = ((attack.time - pivot) / period).rounded()
            let miss = attack.time - (pivot + beat * period)
            if abs(miss) <= onBeat {
                total += miss * attack.strength
                weight += attack.strength
            }
        }
        return pivot + (weight > 0 ? total / weight : 0)
    }

    /// Beat times for a track that keeps count with a candidate but slides a few milliseconds
    /// either side of it. Works along the track four bars at a time, measuring how far the
    /// drums have moved since the last look, so a slow slide of any size is followed.
    static func followDrift(of candidate: Candidate, attacks: [Attack], duration: Double) -> [Double] {
        let period = candidate.period, anchor = candidate.anchor
        let beats = max(1, Int((duration - anchor) / period) + 1)
        let hop = 8, span = 16
        let windows = max(1, (beats + hop - 1) / hop)
        // The strongest attack near each beat, as its distance from the straight grid.
        var nearest = [[(miss: Double, strength: Double)]](repeating: [], count: beats)
        for attack in attacks {
            let beat = Int(((attack.time - anchor) / period).rounded())
            guard beat >= 0, beat < beats else { continue }
            let miss = attack.time - (anchor + Double(beat) * period)
            if abs(miss) <= 0.04 { nearest[beat].append((miss, attack.strength)) }
        }
        func measure(_ window: Int, around slide: Double) -> Double? {
            let from = window * hop, to = min(beats, from + span)
            var misses: [Double] = []
            for beat in from..<to {
                if let hit = nearest[beat].filter({ abs($0.miss - slide) <= 0.012 }).max(by: { $0.strength < $1.strength }) { misses.append(hit.miss) }
            }
            guard misses.count >= 6 else { return nil }
            misses.sort()
            return misses[misses.count / 2]
        }
        // Start where the drums are most surely on the straight grid, and work outwards both ways.
        var slides = [Double?](repeating: nil, count: windows)
        guard let start = (0..<windows).filter({ measure($0, around: 0) != nil }).min(by: { abs(measure($0, around: 0) ?? 1) < abs(measure($1, around: 0) ?? 1) })
        else { return [] }
        var slide = measure(start, around: 0) ?? 0
        slides[start] = slide
        for window in (start + 1)..<max(start + 1, windows) {
            if let measured = measure(window, around: slide) {
                slide = measured
                slides[window] = measured
            }
        }
        slide = slides[start] ?? 0
        for window in stride(from: start - 1, through: 0, by: -1) {
            if let measured = measure(window, around: slide) {
                slide = measured
                slides[window] = measured
            }
        }
        // Between measured stretches the slide is spread evenly; before the first and after the last it holds.
        let known = slides.indices.filter { slides[$0] != nil }
        func slideAt(_ beat: Int) -> Double {
            let place = (Double(beat) - Double(span) / 2) / Double(hop)  // in windows, measured at each window's centre
            guard let first = known.first, let last = known.last else { return 0 }
            if place <= Double(first) { return slides[first] ?? 0 }
            if place >= Double(last) { return slides[last] ?? 0 }
            let after = known.first { Double($0) >= place } ?? last
            let before = known.last { Double($0) <= place } ?? first
            guard after > before else { return slides[before] ?? 0 }
            let fraction = (place - Double(before)) / Double(after - before)
            return (slides[before] ?? 0) * (1 - fraction) + (slides[after] ?? 0) * fraction
        }
        var result = (0..<beats).map { anchor + Double($0) * period + slideAt($0) }
        while let first = result.first, result.count > 1, first - (result[1] - first) >= 0 { result.insert(first - (result[1] - first), at: 0) }
        return result.filter { $0 >= 0 && $0 <= duration }
    }

    // MARK: The beat length

    /// The beat length at which the attacks line up best, searched 3% either side of a guess.
    static func bestPeriod(attacks: [Attack], around guess: Double) -> Double {
        // The strongest attacks say enough, and keep a long track quick.
        let used = attacks.count > 2500 ? Array(attacks.sorted { $0.strength > $1.strength }.prefix(2500)) : attacks
        let span = max(30, (used.map(\.time).max() ?? 0) - (used.map(\.time).min() ?? 0))
        // Fine enough that the sixteenths cannot slip between two steps.
        let step = 0.01 * guess / span
        let steps = Int(0.03 / step)
        var best = guess, bestScore = -1.0
        for offset in -steps...steps {
            let period = guess * (1 + Double(offset) * step)
            let score = alignment(used, period: period)
            if score > bestScore {
                bestScore = score
                best = period
            }
        }
        return best
    }

    /// How well attacks repeat at a beat length: the strength of the rhythm at one, two and four to the beat.
    static func alignment(_ attacks: [Attack], period: Double) -> Double {
        var c1 = 0.0, s1 = 0.0, c2 = 0.0, s2 = 0.0, c4 = 0.0, s4 = 0.0
        let scale = 2 * Double.pi / period
        for attack in attacks {
            let angle = attack.time * scale
            let c = cos(angle), s = sin(angle), w = attack.strength
            let cc = c * c - s * s, ss = 2 * s * c
            c1 += w * c
            s1 += w * s
            c2 += w * cc
            s2 += w * ss
            c4 += w * (cc * cc - ss * ss)
            s4 += w * 2 * ss * cc
        }
        return (c1 * c1 + s1 * s1).squareRoot() + (c2 * c2 + s2 * s2).squareRoot() + (c4 * c4 + s4 * s4).squareRoot()
    }

    // MARK: Where in the beat the attacks fall

    /// The places in the beat where attacks pile up, as seconds into the beat.
    static func pileUps(attacks: [Attack], period: Double) -> [Double] {
        let bins = max(8, Int(period * 1000))
        var histogram = [Double](repeating: 0, count: bins)
        for attack in attacks {
            let fraction = attack.time / period - (attack.time / period).rounded(.down)
            histogram[min(bins - 1, Int(fraction * Double(bins)))] += attack.strength
        }
        // Smooth over a few milliseconds, wrapping round the end of the beat.
        var smooth = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            for offset in -3...3 { smooth[bin] += histogram[(bin + offset + bins) % bins] * Double(4 - abs(offset)) }
        }
        let highest = smooth.max() ?? 0
        guard highest > 0 else { return [] }
        var peaks: [(bin: Int, value: Double)] = []
        for bin in 0..<bins where smooth[bin] >= highest * 0.25 {
            let isPeak = (-10...10).allSatisfy { smooth[(bin + $0 + bins) % bins] <= smooth[bin] }
            if isPeak, !peaks.contains(where: { min(abs($0.bin - bin), bins - abs($0.bin - bin)) <= 10 }) { peaks.append((bin, smooth[bin])) }
        }
        return peaks.sorted { $0.value > $1.value }.prefix(4).map { (Double($0.bin) + 0.5) / Double(bins) * period }
    }

    /// Fits beat length and position to the attacks that sit on a candidate, and measures how well they keep to it.
    static func refine(attacks: [Attack], period: Double, anchor: Double, duration: Double) -> Candidate? {
        var period = period, anchor = anchor
        var chosen: [(beat: Double, time: Double, weight: Double)] = []
        for reach in [0.014, 0.010, onBeat, onBeat] {
            chosen = []
            for attack in attacks {
                let beat = ((attack.time - anchor) / period).rounded()
                if abs(attack.time - (anchor + beat * period)) <= reach { chosen.append((beat, attack.time, attack.strength)) }
            }
            guard chosen.count >= 16 else { return nil }
            let line = BeatTracker.fitLine(x: chosen.map(\.beat), y: chosen.map(\.time), weights: chosen.map(\.weight))
            guard line.slope > 0 else { return nil }
            period = line.slope
            anchor = line.intercept
        }
        // Keep the anchor as the first beat at or after the start of the track.
        anchor -= (anchor / period).rounded(.down) * period

        // The drum on each beat, where there is one; the strongest if there are two.
        var onBeat: [Int: (miss: Double, weight: Double)] = [:]
        for attack in attacks {
            let beat = ((attack.time - anchor) / period).rounded()
            let miss = attack.time - (anchor + beat * period)
            guard abs(miss) <= Self.onBeat else { continue }
            if let existing = onBeat[Int(beat)], existing.weight >= attack.strength { continue }
            onBeat[Int(beat)] = (miss, attack.strength)
        }
        let beats = max(1, Int(duration / period))
        var stretches = 0, covered = 0, tight = 0
        for start in stride(from: 0, to: beats, by: 16) {
            stretches += 1
            let misses = (start..<min(beats, start + 16)).compactMap { onBeat[$0]?.miss }.sorted()
            guard misses.count >= 8 else { continue }
            covered += 1
            if abs(misses[misses.count / 2]) <= 0.003 { tight += 1 }
        }
        let total = attacks.reduce(0) { $0 + $1.strength }
        let squares = onBeat.values.reduce(0) { $0 + $1.miss * $1.miss }
        return Candidate(
            period: period, anchor: anchor, weight: onBeat.values.reduce(0) { $0 + $1.weight } / max(1e-9, total), bass: 0,
            covered: Double(covered) / Double(max(1, stretches)), tight: Double(tight) / Double(max(1, covered)),
            spread: (squares / Double(max(1, onBeat.count))).squareRoot())
    }

    // MARK: Which pile is the kick

    /// The level of the track below about 110 Hz, at the sample rate given.
    static func bassLevel(samples: [Float], sampleRate: Double) -> [Float] {
        // Two one-pole low-passes in a row, then the level of what is left, smoothed over a few milliseconds.
        let coefficient = Float(1 - exp(-2 * Double.pi * 110 / sampleRate))
        let smoothing = Float(1 - exp(-1 / (0.006 * sampleRate)))
        var first: Float = 0, second: Float = 0, level: Float = 0
        var result = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            first += (samples[index] - first) * coefficient
            second += (first - second) * coefficient
            level += (abs(second) - level) * smoothing
            result[index] = level
        }
        return result
    }

    /// How much the bass jumps in the 60 ms after each of a candidate's beats, against the track's average bass level.
    static func bassRise(_ bass: [Float], sampleRate: Double, candidate: Candidate, duration: Double) -> Double {
        var times: [Double] = []
        var time = candidate.anchor
        while time < duration {
            times.append(time)
            time += candidate.period
        }
        return bassRise(bass, sampleRate: sampleRate, at: times)
    }

    /// How much the bass jumps in the 60 ms after each of some moments, against the track's average bass level.
    static func bassRise(_ bass: [Float], sampleRate: Double, at times: [Double]) -> Double {
        var total = 0.0, average = 0.0
        var beats = 0
        let after = Int(0.06 * sampleRate), before = Int(0.004 * sampleRate)
        for time in times {
            let center = Int(time * sampleRate)
            guard center - before >= 0, center + after < bass.count else { continue }
            var peak: Float = 0
            for index in center...(center + after) where bass[index] > peak { peak = bass[index] }
            total += Double(max(0, peak - bass[center - before]))
            beats += 1
        }
        for index in stride(from: 0, to: bass.count, by: 64) { average += Double(bass[index]) }
        average /= Double(max(1, bass.count / 64))
        guard beats > 0, average > 0 else { return 0 }
        return total / Double(beats) / average
    }
}
