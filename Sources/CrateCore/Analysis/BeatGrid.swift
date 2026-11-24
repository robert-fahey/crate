import Foundation

/// Where every beat of a track falls, in seconds from its start.
///
/// The beats are stored one by one, not as a tempo and an offset, so the grid
/// can follow a drummer who speeds up and slows down. A drum-machine track is
/// simply a grid whose beats happen to be evenly spaced.
///
/// Some beats are *markers*: pinned to a moment in the audio, like Ableton's
/// warp markers. The beats between two markers are evenly spaced, and outside
/// the first and last marker the neighbouring tempo carries on. Editing a grid
/// means adding, moving and removing markers; the other beats follow.
public struct BeatGrid: Equatable, Sendable {
    /// Beat times in seconds, ascending. Covers the whole track, including stretches with no drums.
    public private(set) var beats: [Double]
    /// Index of a beat that starts a bar. Bars are four beats.
    public var downbeat: Int
    /// Index of a beat that starts a 32-beat phrase. A guess; music is not always that regular.
    public var phrase: Int
    /// True when the beats are evenly spaced (a drum machine, or a very tight band).
    public var isSteady: Bool
    /// Indices of the pinned beats, ascending. Empty for a grid that has not been given markers yet.
    public private(set) var markers: [Int]

    public static let beatsPerBar = 4
    public static let beatsPerPhrase = 32

    public init(beats: [Double], downbeat: Int = 0, phrase: Int? = nil, isSteady: Bool = false, markers: [Int] = []) {
        self.beats = beats.sorted()
        self.downbeat = downbeat
        self.phrase = phrase ?? downbeat
        self.isSteady = isSteady
        let count = self.beats.count
        self.markers = Array(Set(markers.filter { $0 >= 0 && $0 < count })).sorted()
    }

    /// An evenly spaced grid: `bpm` from `firstBeat` to `duration`.
    public init(bpm: Double, firstBeat: Double, duration: Double, downbeat: Int = 0) {
        let interval = 60 / max(1, bpm)
        var beats: [Double] = []
        var time = firstBeat - (firstBeat / interval).rounded(.down) * interval
        while time <= duration {
            beats.append(time)
            time += interval
        }
        self.init(beats: beats, downbeat: downbeat, isSteady: true)
    }

    public var count: Int { beats.count }
    public var isUsable: Bool { beats.count >= 8 }

    /// Tempo across the whole track: the median beat length.
    public var bpm: Double {
        guard beats.count > 1 else { return 0 }
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        let median = intervals[intervals.count / 2]
        return median > 0 ? 60 / median : 0
    }

    /// Tempo around a moment in the track, over a bar either side.
    public func bpm(at seconds: Double) -> Double {
        guard beats.count > 1 else { return 0 }
        let index = Int(beatPosition(at: seconds).rounded(.down))
        let from = max(0, min(beats.count - 2, index - 4))
        let to = max(from + 1, min(beats.count - 1, index + 4))
        let span = beats[to] - beats[from]
        return span > 0 ? 60 * Double(to - from) / span : 0
    }

    /// How many beats into the grid a moment is: 12.5 is halfway between beat 12 and beat 13.
    /// Before the first beat and after the last, the nearest beat length carries on.
    public func beatPosition(at seconds: Double) -> Double {
        guard beats.count > 1 else { return 0 }
        if seconds <= beats[0] { return (seconds - beats[0]) / (beats[1] - beats[0]) }
        let last = beats.count - 1
        if seconds >= beats[last] { return Double(last) + (seconds - beats[last]) / (beats[last] - beats[last - 1]) }
        var low = 0, high = last
        while high - low > 1 {
            let middle = (low + high) / 2
            if beats[middle] <= seconds { low = middle } else { high = middle }
        }
        return Double(low) + (seconds - beats[low]) / (beats[high] - beats[low])
    }

    /// The moment a beat position falls at; the inverse of `beatPosition(at:)`.
    public func time(atBeat position: Double) -> Double {
        guard beats.count > 1 else { return 0 }
        let last = beats.count - 1
        if position <= 0 { return beats[0] + position * (beats[1] - beats[0]) }
        if position >= Double(last) { return beats[last] + (position - Double(last)) * (beats[last] - beats[last - 1]) }
        let index = Int(position)
        return beats[index] + (position - Double(index)) * (beats[index + 1] - beats[index])
    }

    public func nearestBeat(to seconds: Double) -> Double {
        time(atBeat: beatPosition(at: seconds).rounded())
    }

    /// Beat position of the bar (or other multiple of beats) boundary at or after a moment.
    public func boundary(atOrAfter seconds: Double, every beatsPerUnit: Int, anchoredAt anchor: Int) -> Double {
        let position = beatPosition(at: seconds) - 1e-6
        let units = ((position - Double(anchor)) / Double(beatsPerUnit)).rounded(.up)
        return Double(anchor) + units * Double(beatsPerUnit)
    }

    /// 1...4: which beat of the bar a beat index is.
    public func beatInBar(_ index: Int) -> Int {
        let offset = (index - downbeat) % Self.beatsPerBar
        return (offset + Self.beatsPerBar) % Self.beatsPerBar + 1
    }

    // MARK: Editing

    /// Moves every beat earlier (negative) or later.
    public func shifted(by seconds: Double) -> BeatGrid {
        var copy = self
        copy.beats = beats.map { $0 + seconds }
        return copy
    }

    /// Moves every beat half a beat later, for a grid that sits on the off-beat instead of the kick.
    /// Twice returns the grid to the same drums, one beat on.
    public func shiftedHalfBeat() -> BeatGrid {
        guard beats.count > 1 else { return self }
        var copy = self
        let last = beats.count - 1
        copy.beats = beats.indices.map { index in
            index < last ? (beats[index] + beats[index + 1]) / 2 : beats[last] + (beats[last] - beats[last - 1]) / 2
        }
        return copy
    }

    // MARK: Markers

    public func isMarker(_ beat: Int) -> Bool { markers.contains(beat) }

    /// Tempo of the stretch that starts at a beat: up to the next marker, or the end.
    public func segmentBPM(after beat: Int) -> Double {
        guard beats.count > 1 else { return 0 }
        let index = max(0, min(beats.count - 2, beat))
        let interval = beats[index + 1] - beats[index]
        return interval > 0 ? 60 / interval : 0
    }

    /// Chooses markers for a grid that has none: the fewest beats that reproduce
    /// all the others to within `tolerance` seconds. A drum machine needs two; a
    /// drummer who drifts needs one every few bars. The beats are then re-spaced
    /// from those markers, so the result is exactly what its markers describe.
    public func withMarkers(tolerance: Double = 0.004) -> BeatGrid {
        guard beats.count > 2 else {
            var copy = self
            copy.markers = Array(beats.indices)
            return copy
        }
        // Keep the two ends; wherever the straight line between two kept beats strays
        // too far from the real beats, keep the worst offender and look again either side.
        var keep = Set([0, beats.count - 1])
        var pending = [(0, beats.count - 1)]
        while let (from, to) = pending.popLast() {
            guard to - from > 1 else { continue }
            let slope = (beats[to] - beats[from]) / Double(to - from)
            var worst = from, worstMiss = 0.0
            for index in (from + 1)..<to {
                let miss = abs(beats[index] - (beats[from] + slope * Double(index - from)))
                if miss > worstMiss {
                    worstMiss = miss
                    worst = index
                }
            }
            if worstMiss > tolerance {
                keep.insert(worst)
                pending.append((from, worst))
                pending.append((worst, to))
            }
        }
        var copy = self
        copy.markers = keep.sorted()
        copy.respace()
        return copy
    }

    /// Puts every beat where the markers say it should be.
    private mutating func respace() {
        guard beats.count > 1, let first = markers.first, let last = markers.last else { return }
        for (from, to) in zip(markers, markers.dropFirst()) where to - from > 1 {
            let step = (beats[to] - beats[from]) / Double(to - from)
            for index in (from + 1)..<to { beats[index] = beats[from] + step * Double(index - from) }
        }
        // Outside the markers, carry on at the nearest stretch's tempo.
        if markers.count > 1 {
            let lead = (beats[markers[1]] - beats[first]) / Double(markers[1] - first)
            for index in 0..<first { beats[index] = beats[first] - lead * Double(first - index) }
            let previous = markers[markers.count - 2]
            let tail = (beats[last] - beats[previous]) / Double(last - previous)
            for index in (last + 1)..<max(last + 1, beats.count) { beats[index] = beats[last] + tail * Double(index - last) }
        }
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }
        isSteady = (intervals.max() ?? 0) - (intervals.min() ?? 0) < 0.0001
    }

    /// Pins a beat where it is. Nothing moves.
    public func addingMarker(atBeat beat: Int) -> BeatGrid {
        guard beats.indices.contains(beat), !markers.contains(beat) else { return self }
        var copy = self
        copy.markers = (markers + [beat]).sorted()
        return copy
    }

    /// Unpins a beat. The beats between its neighbouring markers are spread evenly again.
    public func removingMarker(atBeat beat: Int) -> BeatGrid {
        guard markers.contains(beat), markers.count > 1 else { return self }
        var copy = self
        copy.markers.removeAll { $0 == beat }
        copy.respace()
        return copy
    }

    /// Moves a marker to another moment in the audio. Only the beats between its
    /// neighbouring markers move with it; with a single marker the whole grid slides.
    public func movingMarker(atBeat beat: Int, to seconds: Double) -> BeatGrid {
        guard beats.indices.contains(beat) else { return self }
        var copy = markers.contains(beat) ? self : addingMarker(atBeat: beat)
        guard copy.markers.count > 1 else { return shifted(by: seconds - beats[beat]) }
        // It cannot be dragged past the markers either side of it; leave room for the beats between.
        let position = copy.markers.firstIndex(of: beat) ?? 0
        let smallest = 0.06
        var target = seconds
        if position > 0 {
            let previous = copy.markers[position - 1]
            target = max(target, beats[previous] + smallest * Double(beat - previous))
        }
        if position < copy.markers.count - 1 {
            let next = copy.markers[position + 1]
            target = min(target, beats[next] - smallest * Double(next - beat))
        }
        copy.beats[beat] = target
        copy.respace()
        return copy
    }

    /// "Warp from here (straight)": one fixed tempo from a beat to the end of the track.
    /// Markers after it are dropped. Without `bpm`, the tempo already at that beat is kept.
    public func straightened(from beat: Int, bpm: Double? = nil) -> BeatGrid {
        guard beats.count > 1, beats.indices.contains(beat) else { return self }
        let tempo = bpm ?? segmentBPM(after: beat)
        guard tempo > 20 else { return self }
        var copy = self
        copy.markers = (markers.filter { $0 < beat } + [beat]).sorted()
        let interval = 60 / tempo
        for index in (beat + 1)..<max(beat + 1, beats.count) { copy.beats[index] = beats[beat] + interval * Double(index - beat) }
        if copy.markers.count == 1 {
            // Nothing pinned before it: the same tempo runs back to the start too.
            for index in 0..<beat { copy.beats[index] = beats[beat] - interval * Double(beat - index) }
        }
        // A second marker at the end holds the tempo against later edits.
        if beat < beats.count - 1 { copy.markers.append(beats.count - 1) }
        copy.respace()
        return copy
    }

    /// Sets the tempo of the stretch from a marker to the next one. Everything after
    /// that stretch keeps its own timing and slides earlier or later as a block.
    public func settingSegmentTempo(after beat: Int, bpm: Double) -> BeatGrid {
        guard bpm > 20, beats.count > 1, beats.indices.contains(beat) else { return self }
        var copy = markers.contains(beat) ? self : addingMarker(atBeat: beat)
        guard let next = copy.markers.first(where: { $0 > beat }) else { return copy.straightened(from: beat, bpm: bpm) }
        let moved = beats[beat] + 60 / bpm * Double(next - beat) - beats[next]
        for index in next..<beats.count { copy.beats[index] += moved }
        copy.respace()
        return copy
    }

    /// Makes the beat nearest `seconds` the start of a bar (and of a phrase).
    public func settingDownbeat(at seconds: Double) -> BeatGrid {
        var copy = self
        let index = Int(beatPosition(at: seconds).rounded())
        copy.downbeat = ((index % Self.beatsPerBar) + Self.beatsPerBar) % Self.beatsPerBar
        copy.phrase = ((index % Self.beatsPerPhrase) + Self.beatsPerPhrase) % Self.beatsPerPhrase
        return copy
    }

    /// Twice the tempo: a beat added halfway between each pair.
    public func doubled() -> BeatGrid {
        guard beats.count > 1 else { return self }
        var result: [Double] = []
        for (current, next) in zip(beats, beats.dropFirst()) {
            result.append(current)
            result.append((current + next) / 2)
        }
        result.append(beats[beats.count - 1])
        return BeatGrid(beats: result, downbeat: downbeat * 2, phrase: phrase * 2, isSteady: isSteady, markers: markers.map { $0 * 2 })
    }

    /// Half the tempo: every other beat, keeping the downbeat.
    public func halved() -> BeatGrid {
        let start = downbeat % 2
        let kept = stride(from: start, to: beats.count, by: 2).map { beats[$0] }
        // A marker on a dropped beat moves to the beat before it.
        let halvedMarkers = markers.map { max(0, ($0 - start) / 2) }
        return BeatGrid(
            beats: kept, downbeat: (downbeat - start) / 2 % Self.beatsPerBar, phrase: (phrase - start) / 2, isSteady: isSteady,
            markers: halvedMarkers)
    }

    // MARK: Storage

    public var data: Data {
        beats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public var markerData: Data {
        markers.map(Int32.init).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public init?(data: Data, downbeat: Int, phrase: Int, isSteady: Bool, markerData: Data? = nil) {
        guard data.count % MemoryLayout<Double>.size == 0 else { return nil }
        var beats = [Double](repeating: 0, count: data.count / MemoryLayout<Double>.size)
        _ = beats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var markers: [Int32] = []
        if let markerData, markerData.count % MemoryLayout<Int32>.size == 0 {
            markers = [Int32](repeating: 0, count: markerData.count / MemoryLayout<Int32>.size)
            _ = markers.withUnsafeMutableBytes { markerData.copyBytes(to: $0) }
        }
        self.init(beats: beats, downbeat: downbeat, phrase: phrase, isSteady: isSteady, markers: markers.map(Int.init))
    }
}
