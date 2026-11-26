import Foundation

/// Finds which beats start bars and phrases, once the beats themselves are known.
///
/// Three things say where a bar starts, and they are asked together:
///
/// 1. **The backbeat.** In nearly all dance music, funk and disco the snare or clap is on
///    beats 2 and 4 and the kick is on 1 and 3 (or on all four). The snare is bright and the
///    kick is deep, so the beats with more top end and less bottom are 2 and 4. This is what
///    keeps a bar from starting on the snare; when a track has a backbeat it is by far the
///    strongest clue, and it holds bar after bar.
/// 2. **Where the music changes.** Instruments come in and drop out at the start of a bar,
///    so the places where the sound changes most pile up on beat 1. This tells beat 1 from
///    beat 3, which the backbeat cannot.
/// 3. **Where the track starts.** The first beat with music on it is usually a beat 1.
///
/// Measured on a library of 162 tracks, clues 1 and 2 (which have nothing in common) agree
/// with each other on the kick's beats far more often than chance, which is the evidence
/// that each is sound. None of this is certain: a track with no drums, or one that starts
/// with a pick-up, can still come out wrong, which is why a bar can be set by hand.
public enum BarFinder {
    /// What each beat sounds like.
    struct Measures {
        /// Level below about 110 Hz in the tenth of a second around each beat: the kick.
        var low: [Float]
        /// Level above about 2.5 kHz in the same window: the snare or clap.
        var high: [Float]
        /// Loudness from each beat to the next.
        var loud: [Float]
        var count: Int { loud.count }
    }

    /// A place where the music changes: the beat it happens on and how much it changes.
    struct Boundary: Equatable {
        var beat: Int
        var strength: Float
    }

    /// How much a clear backbeat counts against the other clues. A backbeat that is there at all
    /// measures 0.1 to 0.5, so it outweighs them; one that is barely there leaves them to decide.
    static let backbeatWeight: Float = 12
    static let backbeatLimit: Float = 4
    /// The share of the changes that fall on a beat, times this.
    static let boundaryWeight: Float = 2
    /// For being the beat the music starts on.
    static let startWeight: Float = 1

    public static func find(grid: BeatGrid, samples: [Float], sampleRate: Double) -> (downbeat: Int, phrase: Int) {
        let beats = grid.beats
        guard beats.count > 40, sampleRate > 0 else { return (0, 0) }
        let measures = measures(beats: beats, samples: samples, sampleRate: sampleRate)
        let boundaries = boundaries(measures)
        let start = firstLoudBeat(measures)
        let scores = scores(measures, boundaries: boundaries, start: start)
        let bar = BeatGrid.beatsPerBar, phrase = BeatGrid.beatsPerPhrase
        let downbeat = (0..<bar).max { scores[$0] < scores[$1] } ?? 0

        // Phrases: of the bars, the one in eight where the changes pile up, counting the start as one.
        var votes = [Float](repeating: 0, count: phrase)
        for boundary in boundaries where boundary.beat % bar == downbeat { votes[boundary.beat % phrase] += boundary.strength }
        if let start, start % bar == downbeat { votes[start % phrase] += 1 }
        let candidates = Array(stride(from: downbeat, to: phrase, by: bar))
        return (downbeat, candidates.max { votes[$0] < votes[$1] } ?? downbeat)
    }

    /// How well each of the four beats does as the first of the bar.
    static func scores(_ measures: Measures, boundaries: [Boundary], start: Int?) -> [Float] {
        let bar = BeatGrid.beatsPerBar
        var share = [Float](repeating: 0, count: bar)
        for boundary in boundaries { share[boundary.beat % bar] += boundary.strength }
        let total = share.reduce(0, +)
        return (0..<bar).map { beat in
            var score = max(-backbeatLimit, min(backbeatLimit, backbeat(measures, from: beat) * backbeatWeight))
            if total > 0 { score += boundaryWeight * share[beat] / total }
            if let start, start % bar == beat { score += startWeight }
            return score
        }
    }

    // MARK: What each beat sounds like

    static func measures(beats: [Double], samples: [Float], sampleRate: Double) -> Measures {
        // The kick: what two gentle low-passes at 110 Hz leave. The snare: what two at 2.5 kHz take away.
        let lowStep = Float(1 - exp(-2 * Double.pi * 110 / sampleRate))
        let highStep = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))
        var low = [Float](repeating: 0, count: samples.count)
        var high = [Float](repeating: 0, count: samples.count)
        var lowFirst: Float = 0, lowSecond: Float = 0, highFirst: Float = 0, highSecond: Float = 0
        samples.withUnsafeBufferPointer { input in
            low.withUnsafeMutableBufferPointer { lowOut in
                high.withUnsafeMutableBufferPointer { highOut in
                    for index in 0..<input.count {
                        let sample = input[index]
                        lowFirst += (sample - lowFirst) * lowStep
                        lowSecond += (lowFirst - lowSecond) * lowStep
                        highFirst += (sample - highFirst) * highStep
                        highSecond += (highFirst - highSecond) * highStep
                        lowOut[index] = abs(lowSecond)
                        highOut[index] = abs(sample - highSecond)
                    }
                }
            }
        }
        func mean(_ level: [Float], from: Double, to: Double, squared: Bool = false) -> Float {
            let first = Int(from * sampleRate), last = Int(to * sampleRate)
            guard first >= 0, last <= level.count, first < last else { return 0 }
            var sum: Float = 0
            level.withUnsafeBufferPointer { values in
                if squared {
                    for index in first..<last { sum += values[index] * values[index] }
                } else {
                    for index in first..<last { sum += values[index] }
                }
            }
            return sum / Float(last - first)
        }
        var result = Measures(low: [], high: [], loud: [])
        for (index, beat) in beats.enumerated() {
            // From just before the beat, to catch a drum that is a touch early, to well into its ring.
            result.low.append(mean(low, from: beat - 0.01, to: beat + 0.09))
            result.high.append(mean(high, from: beat - 0.01, to: beat + 0.09))
            let next = index + 1 < beats.count ? beats[index + 1] : beat + (index > 0 ? beat - beats[index - 1] : 0.5)
            result.loud.append(mean(samples, from: beat, to: next, squared: true).squareRoot())
        }
        return result
    }

    // MARK: Clue 1: the backbeat

    /// Above zero when, counting `first` as beat 1, beats 2 and 4 are the bright ones and 1 and 3 the
    /// deep ones; below zero when it is the other way round, which is a bar starting on the snare.
    /// Judged bar by bar and averaged, so one loud section does not decide for the whole track.
    static func backbeat(_ measures: Measures, from first: Int) -> Float {
        let bar = BeatGrid.beatsPerBar
        let bars = (measures.count - first) / bar
        guard bars >= 8 else { return 0 }
        func total(_ values: [Float], _ index: Int) -> Float {
            let at = first + index * bar
            return values[at] + values[at + 1] + values[at + 2] + values[at + 3]
        }
        // Bars with next to no top end (a breakdown, the silence at either end) say nothing.
        let brightness = (0..<bars).map { total(measures.high, $0) }.sorted()
        let floor = brightness[bars / 2] * 0.25
        var sum: Float = 0
        var counted = 0
        for index in 0..<bars where total(measures.high, index) > floor {
            let at = first + index * bar
            func lean(_ values: [Float]) -> Float {
                (values[at + 1] + values[at + 3] - values[at] - values[at + 2]) / (total(values, index) + 1e-9)
            }
            sum += lean(measures.high) - lean(measures.low)
            counted += 1
        }
        return counted >= 8 ? sum / Float(counted) : 0
    }

    // MARK: Clue 2: where the music changes

    /// The most a single change counts for. Music stopping dead measures ten times what a bassline
    /// coming in does; without a limit the end of a track would outvote every section in it.
    static let strongestBoundary: Float = 2

    /// The beats where the two bars after sound most unlike the two bars before, in loudness, in
    /// bass and in top end. At most 24, the strongest first, no two within a bar and a half.
    static func boundaries(_ measures: Measures) -> [Boundary] {
        let count = measures.count, half = 2 * BeatGrid.beatsPerBar
        guard count > half * 2 else { return [] }
        // Sums up to each beat of the three levels, in logarithms: a change is a ratio, not a difference.
        let features = [measures.loud, measures.low, measures.high].map { values -> [Float] in
            var sums = [Float](repeating: 0, count: count + 1)
            for index in 0..<count { sums[index + 1] = sums[index] + log(values[index] + 1e-4) }
            return sums
        }
        var change = [Float](repeating: 0, count: count)
        for beat in half..<(count - half) {
            for sums in features {
                change[beat] += abs((sums[beat + half] - sums[beat]) - (sums[beat] - sums[beat - half])) / Float(half)
            }
        }
        var found: [Boundary] = []
        var taken = [Bool](repeating: false, count: count)
        for beat in (0..<count).sorted(by: { change[$0] > change[$1] }) {
            // Half a unit is the loudness and the tone together changing by about a fifth.
            guard change[beat] >= 0.5, found.count < 24 else { break }
            guard !taken[max(0, beat - 6)...min(count - 1, beat + 6)].contains(true) else { continue }
            // The very beat of the change, not a beat on the slope up to a bigger one next to it.
            guard change[beat] >= change[max(0, beat - 4)...min(count - 1, beat + 4)].max() ?? 0 else { continue }
            taken[beat] = true
            found.append(Boundary(beat: beat, strength: min(strongestBoundary, change[beat])))
        }
        return found
    }

    // MARK: Clue 3: where the track starts

    /// The first beat from which the music is going for a whole bar.
    static func firstLoudBeat(_ measures: Measures) -> Int? {
        let sounding = measures.loud.filter { $0 > 0 }.sorted()
        guard !sounding.isEmpty else { return nil }
        let floor = sounding[sounding.count / 2] * 0.3
        let bar = BeatGrid.beatsPerBar
        guard measures.count > bar else { return nil }
        return (0..<(measures.count - bar)).first { beat in (beat..<(beat + bar)).allSatisfy { measures.loud[$0] > floor } }
    }
}
