import XCTest
@testable import CrateCore

extension Synth {
    /// Drums with a sharp attack: a kick (click plus low thump) on each of `beats`, a hat halfway between.
    static func drums(beats: [Double], seconds: Double, sampleRate: Double, kickEvery: Int = 1) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var generator = SystemRandomNumberGenerator()
        func add(at time: Double, length: Double, _ value: (Double) -> Float) {
            let start = Int((time * sampleRate).rounded())
            for offset in 0..<Int(length * sampleRate) where start + offset >= 0 && start + offset < samples.count {
                samples[start + offset] += value(Double(offset) / sampleRate)
            }
        }
        for (index, beat) in beats.enumerated() {
            if index % kickEvery == 0 {
                add(at: beat, length: 0.15) { t in
                    Float(sin(2 * .pi * 60 * t) * exp(-t * 25)) * 0.7
                        + Float.random(in: -1...1, using: &generator) * Float(exp(-t * 900)) * 0.5
                }
            }
            if index + 1 < beats.count {
                add(at: (beat + beats[index + 1]) / 2, length: 0.03) { t in
                    Float.random(in: -1...1, using: &generator) * Float(exp(-t * 200)) * 0.2
                }
            }
        }
        return samples
    }

    /// Beat times for a tempo that glides from `from` to `to` BPM over the length.
    static func driftingBeats(from: Double, to: Double, seconds: Double, start: Double = 0.3) -> [Double] {
        var beats: [Double] = []
        var time = start
        while time < seconds {
            beats.append(time)
            time += 60 / (from + (to - from) * time / seconds)
        }
        return beats
    }
}

final class BeatGridTests: XCTestCase {
    func testPositionsAndTimesAreInverses() {
        let grid = BeatGrid(bpm: 120, firstBeat: 0.25, duration: 60)
        XCTAssertEqual(grid.beats[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(grid.bpm, 120, accuracy: 1e-6)
        XCTAssertTrue(grid.isSteady)
        XCTAssertEqual(grid.beatPosition(at: 0.25), 0, accuracy: 1e-9)
        XCTAssertEqual(grid.beatPosition(at: 1.0), 1.5, accuracy: 1e-9)
        XCTAssertEqual(grid.beatPosition(at: 0), -0.5, accuracy: 1e-9, "before the first beat the spacing carries on")
        XCTAssertEqual(grid.time(atBeat: 1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(grid.time(atBeat: -2), -0.75, accuracy: 1e-9)
        for seconds in [0.1, 3.3, 27.77, 59.9, 61.5] {
            XCTAssertEqual(grid.time(atBeat: grid.beatPosition(at: seconds)), seconds, accuracy: 1e-9)
        }
        XCTAssertEqual(grid.nearestBeat(to: 1.1), 1.25, accuracy: 1e-9)
    }

    func testAnUnevenGridReportsTheTempoWhereYouAre() {
        let grid = BeatGrid(beats: Synth.driftingBeats(from: 110, to: 130, seconds: 120))
        XCTAssertEqual(grid.bpm(at: 5), 110.8, accuracy: 1)
        XCTAssertEqual(grid.bpm(at: 115), 129.2, accuracy: 1)
        XCTAssertFalse(grid.isSteady)
    }

    func testBarsPhrasesAndEdits() {
        var grid = BeatGrid(bpm: 120, firstBeat: 0, duration: 120)
        grid.downbeat = 2
        XCTAssertEqual(grid.beatInBar(2), 1)
        XCTAssertEqual(grid.beatInBar(5), 4)
        XCTAssertEqual(grid.beatInBar(1), 4)
        XCTAssertEqual(grid.boundary(atOrAfter: 2.1, every: 4, anchoredAt: 2), 6, "beat 4.2 → next bar starts at beat 6")
        XCTAssertEqual(grid.boundary(atOrAfter: 3.0, every: 4, anchoredAt: 2), 6, "exactly on a bar line counts")

        let moved = grid.shifted(by: -0.01)
        XCTAssertEqual(moved.beats[10], grid.beats[10] - 0.01, accuracy: 1e-9)

        let set = grid.settingDownbeat(at: 3.55)  // nearest beat is 7
        XCTAssertEqual(set.downbeat, 3)
        XCTAssertEqual(set.beatInBar(7), 1)
        XCTAssertEqual(set.phrase, 7)

        let double = grid.doubled()
        XCTAssertEqual(double.bpm, 240, accuracy: 1e-6)
        XCTAssertEqual(double.halved().beats.count, grid.beats.count)
        XCTAssertEqual(grid.halved().bpm, 60, accuracy: 1e-6)

        let restored = BeatGrid(data: grid.data, downbeat: grid.downbeat, phrase: grid.phrase, isSteady: grid.isSteady)
        XCTAssertEqual(restored, grid)
    }
}

final class BeatTrackerTests: XCTestCase {
    private let rate = 11025.0

    /// How far each true beat is from the nearest tracked beat, in seconds.
    private func errors(of grid: BeatGrid, against truth: [Double]) -> [Double] {
        truth.map { beat in abs(grid.nearestBeat(to: beat) - beat) }
    }

    func testASteadyDrumMachineGetsAnEvenGridOnTheAttacks() throws {
        let truth = stride(from: 0.2, to: 45, by: 60.0 / 124).map { $0 }
        let samples = Synth.drums(beats: truth, seconds: 45, sampleRate: rate)
        let grid = try XCTUnwrap(BeatTracker.track(samples: samples, sampleRate: rate, bpm: 124))
        XCTAssertTrue(grid.isSteady)
        XCTAssertEqual(grid.bpm, 124, accuracy: 0.02)
        let errors = errors(of: grid, against: truth)
        XCTAssertLessThan(errors.max() ?? 1, 0.004, "every beat within 4 ms of the drum's attack")
        XCTAssertGreaterThanOrEqual(grid.beats.count, truth.count, "the grid covers the whole track")
        XCTAssertLessThan(grid.beats[0], 60.0 / 124)
    }

    func testATempoHintThatIsSlightlyOffStillLocks() throws {
        let truth = stride(from: 0.2, to: 40, by: 60.0 / 121.4).map { $0 }
        let samples = Synth.drums(beats: truth, seconds: 40, sampleRate: rate)
        let grid = try XCTUnwrap(BeatTracker.track(samples: samples, sampleRate: rate, bpm: 120))
        XCTAssertEqual(grid.bpm, 121.4, accuracy: 0.05)
        XCTAssertLessThan(errors(of: grid, against: truth).max() ?? 1, 0.004)
    }

    func testADriftingDrummerIsFollowed() throws {
        let truth = Synth.driftingBeats(from: 114, to: 124, seconds: 70)
        let samples = Synth.drums(beats: truth, seconds: 70, sampleRate: rate)
        let grid = try XCTUnwrap(BeatTracker.track(samples: samples, sampleRate: rate, bpm: 119))
        XCTAssertFalse(grid.isSteady)
        let errors = errors(of: grid, against: truth)
        XCTAssertLessThan(errors.sorted()[errors.count * 95 / 100], 0.005, "95% of beats within 5 ms")
        XCTAssertLessThan(errors.max() ?? 1, 0.012)
        XCTAssertEqual(grid.bpm(at: 5), 114.7, accuracy: 1)
        XCTAssertEqual(grid.bpm(at: 65), 123.3, accuracy: 1)
    }

    func testABreakWithNoDrumsKeepsTheGridGoing() throws {
        let truth = stride(from: 0.2, to: 60, by: 60.0 / 120).map { $0 }
        let drummed = truth.filter { $0 < 24 || $0 > 36 }  // twelve seconds of silence in the middle
        let samples = Synth.drums(beats: drummed, seconds: 60, sampleRate: rate)
            .enumerated().map { index, value in value }
        let grid = try XCTUnwrap(BeatTracker.track(samples: samples, sampleRate: rate, bpm: 120))
        let errors = errors(of: grid, against: drummed)
        XCTAssertLessThan(errors.max() ?? 1, 0.006, "the beat is in the same place when the drums return")
        XCTAssertEqual(grid.beats.count, truth.count, accuracy: 2)
    }

    func testTooLittleAudioGivesNoGrid() {
        XCTAssertNil(BeatTracker.track(samples: [Float](repeating: 0, count: 2000), sampleRate: rate, bpm: 120))
        XCTAssertNil(BeatTracker.track(samples: Synth.drums(beats: [1, 2], seconds: 30, sampleRate: rate), sampleRate: rate, bpm: 0))
    }
}

/// Music with a fixed tempo: the grid is a ruler, whatever happens in between.
final class SteadyTempoTests: XCTestCase {
    private let rate = 11025.0

    /// A dance track: kick on the beat, a bright hat between the beats, and a breakdown with only the hats.
    private func track(bpm: Double, first: Double, seconds: Double, hat: Float = 0.2, breakdown: ClosedRange<Double>? = nil) -> (samples: [Float], kicks: [Double]) {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        var generator = SystemRandomNumberGenerator()
        func add(at time: Double, length: Double, _ value: (Double) -> Float) {
            let start = Int((time * rate).rounded())
            for offset in 0..<Int(length * rate) where start + offset >= 0 && start + offset < samples.count {
                samples[start + offset] += value(Double(offset) / rate)
            }
        }
        var kicks: [Double] = []
        var time = first
        while time < seconds - 0.5 {
            if breakdown?.contains(time) != true {
                kicks.append(time)
                add(at: time, length: 0.15) { t in
                    Float(sin(2 * .pi * 60 * t) * exp(-t * 25)) * 0.7 + Float.random(in: -1...1, using: &generator) * Float(exp(-t * 900)) * 0.3
                }
            }
            add(at: time + 30 / bpm, length: 0.04) { t in Float.random(in: -1...1, using: &generator) * Float(exp(-t * 150)) * hat }
            time += 60 / bpm
        }
        return (samples, kicks)
    }

    private func worstMiss(_ grid: BeatGrid, _ kicks: [Double]) -> Double {
        kicks.map { abs(grid.nearestBeat(to: $0) - $0) }.max() ?? 1
    }

    func testAnExactTempoIsMeasuredAcrossABreakdown() throws {
        // 16.5 beats without a kick: counting beats through it is where a tracker slips.
        let made = track(bpm: 124.3, first: 0.137, seconds: 90, breakdown: 30...38)
        let grid = try XCTUnwrap(BeatTracker.track(samples: made.samples, sampleRate: rate, bpm: 124))
        XCTAssertTrue(grid.isSteady)
        XCTAssertEqual(grid.markers.count, 2, "a ruler: one tempo from one starting point")
        XCTAssertEqual(grid.bpm, 124.3, accuracy: 0.005)
        XCTAssertLessThan(worstMiss(grid, made.kicks), 0.002, "every kick, before and after the breakdown, within 2 ms of a beat")
    }

    func testAWholeNumberTempoComesOutExact() throws {
        let made = track(bpm: 125, first: 0.05, seconds: 80)
        let grid = try XCTUnwrap(BeatTracker.track(samples: made.samples, sampleRate: rate, bpm: 125.4))
        XCTAssertEqual(grid.bpm, 125, accuracy: 0.000001)
        XCTAssertLessThan(worstMiss(grid, made.kicks), 0.002)
    }

    func testTheGridSitsOnTheKickNotTheLouderHat() throws {
        // The hats are much the sharper, more numerous sound; the kick still has the bass.
        let made = track(bpm: 128, first: 0.3, seconds: 70, hat: 0.9, breakdown: 20...35)
        let grid = try XCTUnwrap(BeatTracker.track(samples: made.samples, sampleRate: rate, bpm: 128))
        XCTAssertLessThan(worstMiss(grid, made.kicks), 0.003, "beats are on the kicks, not half a beat away on the hats")
    }

    func testABandPlayingLiveIsNotGivenARuler() throws {
        let truth = Synth.driftingBeats(from: 114, to: 124, seconds: 70)
        let samples = Synth.drums(beats: truth, seconds: 70, sampleRate: rate)
        XCTAssertNil(SteadyTempo.grid(samples: samples, sampleRate: rate, bpm: 119))
    }

    func testARecordingThatWandersAFewMillisecondsIsFollowed() throws {
        // A fixed tempo on a machine that slides up to 7 ms either side of it, slowly: tape, or a hardware sequencer.
        var beats: [Double] = []
        var index = 0.0
        while 0.2 + index * 0.48 < 89 {
            let straight = 0.2 + index * 0.48
            beats.append(straight + 0.007 * sin(2 * .pi * straight / 50))
            index += 1
        }
        let samples = Synth.drums(beats: beats, seconds: 90, sampleRate: rate)
        let found = try XCTUnwrap(SteadyTempo.grid(samples: samples, sampleRate: rate, bpm: 125))
        XCTAssertEqual(found.kind, .drifting)
        let misses = beats.map { abs(found.grid.nearestBeat(to: $0) - $0) }.sorted()
        XCTAssertLessThan(misses[misses.count * 95 / 100], 0.003)
        let within = found.grid.beats.filter { $0 > beats[0] - 0.1 && $0 < beats[beats.count - 1] + 0.1 }
        XCTAssertEqual(within.count, beats.count, "no beat gained or lost")
    }

    func testMovingAGridHalfABeat() {
        let grid = BeatGrid(bpm: 120, firstBeat: 0.1, duration: 20)
        let moved = grid.shiftedHalfBeat()
        XCTAssertEqual(moved.beats[0], 0.35, accuracy: 1e-9)
        XCTAssertEqual(moved.bpm, 120, accuracy: 1e-6)
        XCTAssertEqual(moved.count, grid.count)
    }
}

final class BeatGridMarkerTests: XCTestCase {
    private func intervals(_ grid: BeatGrid) -> [Double] { zip(grid.beats, grid.beats.dropFirst()).map { $1 - $0 } }

    func testASteadyGridNeedsTwoMarkersAndADriftingOneAFew() {
        let steady = BeatGrid(bpm: 124, firstBeat: 0.2, duration: 300).withMarkers()
        XCTAssertEqual(steady.markers, [0, steady.count - 1])
        XCTAssertTrue(steady.isSteady)

        let truth = Synth.driftingBeats(from: 114, to: 126, seconds: 300)
        let drifting = BeatGrid(beats: truth).withMarkers(tolerance: 0.004)
        XCTAssertGreaterThan(drifting.markers.count, 2)
        XCTAssertLessThan(drifting.markers.count, truth.count / 8, "far fewer markers than beats")
        XCTAssertFalse(drifting.isSteady)
        let worst = zip(drifting.beats, truth).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThanOrEqual(worst, 0.004 + 1e-9, "the markers reproduce every beat within the tolerance")
        // Between two markers the beats are exactly even.
        let from = drifting.markers[1], to = drifting.markers[2]
        let inside = Array(intervals(drifting)[from..<to])
        XCTAssertEqual(inside.max() ?? 0, inside.min() ?? 1, accuracy: 1e-9)
    }

    func testMovingAMarkerOnlyMovesTheBeatsBetweenItsNeighbours() {
        var grid = BeatGrid(bpm: 120, firstBeat: 0, duration: 60).withMarkers()
        grid = grid.addingMarker(atBeat: 16).addingMarker(atBeat: 32).addingMarker(atBeat: 48)
        let before = grid
        XCTAssertEqual(before.beats, BeatGrid(bpm: 120, firstBeat: 0, duration: 60).beats, "pinning a beat moves nothing")

        let moved = grid.movingMarker(atBeat: 32, to: 16.08)   // 80 ms late
        XCTAssertEqual(moved.beats[32], 16.08, accuracy: 1e-9)
        XCTAssertEqual(Array(moved.beats[0...16]), Array(before.beats[0...16]), "before the previous marker: untouched")
        XCTAssertEqual(Array(moved.beats[48...]), Array(before.beats[48...]), "after the next marker: untouched")
        XCTAssertEqual(moved.beats[24], 12.04, accuracy: 1e-9, "halfway to the moved marker moves half as far")
        XCTAssertEqual(moved.segmentBPM(after: 16), 60 / (8.08 / 16), accuracy: 1e-6)
        XCTAssertEqual(moved.segmentBPM(after: 32), 60 / (7.92 / 16), accuracy: 1e-6)
        XCTAssertFalse(moved.isSteady)
        XCTAssertEqual(moved.beats, moved.beats.sorted())

        // It cannot be dragged past its neighbours.
        let tooFar = grid.movingMarker(atBeat: 32, to: 40)
        XCTAssertLessThan(tooFar.beats[32], tooFar.beats[48])
        XCTAssertEqual(tooFar.beats, tooFar.beats.sorted())
        XCTAssertGreaterThan(intervals(tooFar).min() ?? 0, 0.05)

        // Dragging a beat that is not a marker pins it first.
        let pinned = before.movingMarker(atBeat: 20, to: 10.02)
        XCTAssertTrue(pinned.isMarker(20))
        XCTAssertEqual(pinned.beats[20], 10.02, accuracy: 1e-9)
    }

    func testRemovingAMarkerEvensOutTheGap() {
        let grid = BeatGrid(bpm: 120, firstBeat: 0, duration: 60).withMarkers()
            .addingMarker(atBeat: 16).addingMarker(atBeat: 32).addingMarker(atBeat: 48)
        let moved = grid.movingMarker(atBeat: 32, to: 16.08)
        let removed = moved.removingMarker(atBeat: 32)
        XCTAssertFalse(removed.isMarker(32))
        XCTAssertEqual(removed.beats, grid.beats, "with the marker gone the stretch is even again")
        XCTAssertEqual(grid.removingMarker(atBeat: 5), grid, "not a marker: nothing to remove")
    }

    func testMovingAnEndMarkerCarriesItsTempoOutwards() {
        // Two markers in the middle of the track: the beats outside them follow.
        let even = BeatGrid(bpm: 120, firstBeat: 0, duration: 30)
        var grid = BeatGrid(beats: even.beats, markers: [8, 24])
        grid = grid.movingMarker(atBeat: 24, to: 12.16)   // 16 beats now take 8.16 s
        let step = 8.16 / 16
        XCTAssertEqual(grid.beats[25] - grid.beats[24], step, accuracy: 1e-9, "after the last marker")
        XCTAssertEqual(grid.beats[8] - grid.beats[7], step, accuracy: 1e-9, "before the first marker")
        XCTAssertEqual(grid.beats[8], 4, accuracy: 1e-9, "the other marker stays put")
        XCTAssertTrue(grid.isSteady, "one tempo throughout")

        // A lone marker slides the whole grid.
        let lone = BeatGrid(beats: even.beats, markers: [4]).movingMarker(atBeat: 4, to: 2.01)
        XCTAssertEqual(lone.beats[0], 0.01, accuracy: 1e-9)
        XCTAssertEqual(lone.beats[20], even.beats[20] + 0.01, accuracy: 1e-9)
    }

    func testStraighteningAndSegmentTempo() {
        let drifting = BeatGrid(beats: Synth.driftingBeats(from: 114, to: 126, seconds: 120)).withMarkers()
        let straight = drifting.straightened(from: 40, bpm: 120)
        XCTAssertEqual(Array(straight.beats[0...40]), Array(drifting.beats[0...40]), "everything before stays as it was")
        for interval in intervals(straight)[40...] { XCTAssertEqual(interval, 0.5, accuracy: 1e-9) }
        XCTAssertTrue(straight.isMarker(40))
        XCTAssertEqual(straight.markers.filter { $0 > 40 }, [straight.count - 1], "later markers are replaced by one at the end")
        // Without a tempo it keeps the one already there.
        let kept = drifting.straightened(from: 40)
        XCTAssertEqual(kept.segmentBPM(after: 40), drifting.segmentBPM(after: 40), accuracy: 1e-6)
        // From the very first beat with nothing pinned before it, the whole track is one tempo.
        XCTAssertTrue(BeatGrid(beats: drifting.beats).straightened(from: 0, bpm: 118).isSteady)

        let grid = BeatGrid(bpm: 120, firstBeat: 0, duration: 60).withMarkers().addingMarker(atBeat: 16).addingMarker(atBeat: 32)
        let faster = grid.settingSegmentTempo(after: 16, bpm: 128)
        XCTAssertEqual(faster.segmentBPM(after: 16), 128, accuracy: 1e-6)
        XCTAssertEqual(faster.beats[16], 8, accuracy: 1e-9)
        let shift = faster.beats[32] - grid.beats[32]
        XCTAssertEqual(shift, 16 * (60.0 / 128 - 0.5), accuracy: 1e-9)
        XCTAssertEqual(faster.beats[60] - grid.beats[60], shift, accuracy: 1e-9, "what follows slides as a block")
        XCTAssertEqual(faster.segmentBPM(after: 40), 120, accuracy: 1e-6, "and keeps its own tempo")
    }

    func testMarkersSurviveHalvingDoublingAndStorage() throws {
        let grid = BeatGrid(bpm: 120, firstBeat: 0, duration: 60).withMarkers().addingMarker(atBeat: 16).movingMarker(atBeat: 16, to: 8.05)
        XCTAssertEqual(grid.doubled().markers, grid.markers.map { $0 * 2 })
        XCTAssertEqual(grid.doubled().beats[32], 8.05, accuracy: 1e-9)
        XCTAssertTrue(grid.halved().isMarker(8))
        XCTAssertEqual(grid.shifted(by: 0.01).markers, grid.markers)

        let restored = BeatGrid(data: grid.data, downbeat: grid.downbeat, phrase: grid.phrase, isSteady: grid.isSteady, markerData: grid.markerData)
        XCTAssertEqual(restored, grid)

        let store = try LibraryStore(path: ":memory:")
        let id = try store.upsertLocal(ScannedFile(path: "/music/m.wav", title: "M", artist: "", duration: 60, format: "wav"))
        try store.setBeatGrid(id: id, grid, edited: true)
        XCTAssertEqual(try store.beatGrid(id: id), grid)
        // Re-analysis leaves a hand-edited grid alone, unless asked to discard the edits.
        let analysed = BeatGrid(bpm: 121, firstBeat: 0, duration: 60).withMarkers()
        try store.setBeatGrid(id: id, analysed, edited: false)
        XCTAssertEqual(try store.beatGrid(id: id), grid)
        try store.setBeatGrid(id: id, analysed, edited: false, discardingEdits: true)
        XCTAssertEqual(try store.beatGrid(id: id), analysed)
    }
}
