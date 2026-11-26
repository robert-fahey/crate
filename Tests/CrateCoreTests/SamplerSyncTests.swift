import XCTest
@testable import CrateCore

/// The sampler kept in time with the decks. Deck A plays clicks on the left channel only, and a
/// pad's audio goes to both, so the right channel is the pad alone and left minus right the deck.
final class SamplerSyncTests: XCTestCase {
    /// Everything comes out of the engine this many frames after it was made: the limiter looks that far ahead.
    private static let delay = 88
    private static let delaySeconds = Double(delay) / Probe.rate

    private struct Rig {
        let engine: DeckEngine
        let decks: DeckSync
        let sync: SamplerSync
        var sampler: Sampler { engine.sampler }
        var heard = StereoAudio(sampleRate: Probe.rate)

        mutating func render(_ seconds: Double) throws {
            let more = try engine.render(seconds: seconds)
            heard.left += more.left
            heard.right += more.right
        }

        /// When the pad's sounds started, in seconds from the start of the render.
        func padOnsets(from start: Double = 0) -> [Double] {
            Probe.onsets(in: heard.right, threshold: 0.05).map { Double($0) / Probe.rate - delaySeconds }.filter { $0 >= start }
        }

        func deckOnsets(from start: Double = 0) -> [Double] {
            let deck = zip(heard.left, heard.right).map { $0 - $1 }
            return Probe.onsets(in: deck, threshold: 0.05).map { Double($0) / Probe.rate - delaySeconds }.filter { $0 >= start }
        }
    }

    /// Deck A with a click on every beat at `bpm`, its first beat a quarter of a second in.
    private func rig(bpm: Double = 120, seconds: Double = 40) throws -> Rig {
        let engine = try DeckEngine(offline: true)
        let decks = DeckSync(engine: engine)
        let sync = SamplerSync(engine: engine, decks: decks)
        let beats = Array(stride(from: 0.25, to: seconds - 0.1, by: 60 / bpm))
        let clicks = Probe.clicks(at: beats, seconds: seconds)
        engine.deck(.a).load(TrackAudio(left: clicks, right: [Float](repeating: 0, count: clicks.count), sampleRate: Probe.rate))
        decks.setGrid(BeatGrid(beats: beats), for: .a)
        return Rig(engine: engine, decks: decks, sync: sync)
    }

    /// A loop with a blip on each of its beats. Not `Probe.clicks`: those are at the top of the
    /// spectrum and vanish when a pad is played at any speed but its own.
    private func loop(beats: Int, bpm: Double, blips: [Int]? = nil) -> SampleClip {
        let beat = 60 / bpm
        var samples = [Float](repeating: 0, count: Int((Double(beats) * beat * Probe.rate).rounded()))
        for index in blips ?? Array(0..<beats) {
            let start = Int((Double(index) * beat * Probe.rate).rounded())
            for offset in 0..<130 where start + offset < samples.count {
                samples[start + offset] = 0.7 * Float(cos(2 * Double.pi * 2000 * Double(offset) / Probe.rate))
            }
        }
        return SampleClip(audio: TrackAudio(left: samples, sampleRate: Probe.rate))
    }

    /// How far each of the pad's sounds is from the nearest of the deck's, in milliseconds.
    private func distances(_ pad: [Double], from deck: [Double]) -> [Double] {
        pad.map { time in (deck.map { abs($0 - time) }.min() ?? 1) * 1000 }
    }

    private func load(_ clip: SampleClip, on rig: Rig, timing: SampleTiming? = nil, loops: Bool = true) {
        rig.sampler.load(clip, on: 0)
        rig.sampler.set(loops: loops, on: 0)
        rig.sync.set(synced: true, timing: loops ? (timing ?? SampleTiming.assumed(duration: clip.duration)) : nil, for: 0)
    }

    // MARK: Tempo from length

    func testALoopsTempoIsReadFromItsLength() throws {
        XCTAssertEqual(try XCTUnwrap(SampleTiming.assumed(duration: 4 * 60 / 124.0)).bpm, 124, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(SampleTiming.assumed(duration: 8 * 60 / 90.0)).bpm, 90, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(SampleTiming.assumed(duration: 1 * 60 / 128.0)).bpm, 128, accuracy: 1e-6, "one beat is a loop too")
        XCTAssertEqual(try XCTUnwrap(SampleTiming.assumed(duration: 64 * 60 / 140.0)).bpm, 140, accuracy: 1e-6)
        // A tempo outside the range comes out at half or double, which a pad plays in time all the same.
        XCTAssertEqual(try XCTUnwrap(SampleTiming.assumed(duration: 16 * 60 / 174.0)).bpm, 87, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(SampleTiming.assumed(duration: 4 * 60 / 70.0)).bpm, 140, accuracy: 1e-6)
        XCTAssertNil(SampleTiming.assumed(duration: 0.1), "a hit, not a loop")
        XCTAssertNil(SampleTiming.assumed(duration: 90), "too long to be a loop cut to length")
        XCTAssertEqual(SampleTiming(beats: 6, in: 3).bpm, 120)
        XCTAssertEqual(SampleTiming(bpm: 120).beats(in: 4), 8)
    }

    func testAStretchOfATrackTakesItsTimingFromTheTracksGrid() throws {
        let grid = BeatGrid(bpm: 125, firstBeat: 0.1, duration: 60)
        let taken = try XCTUnwrap(SampleTiming(grid: grid, from: grid.time(atBeat: 16), to: grid.time(atBeat: 20)))
        XCTAssertEqual(taken.bpm, 125, accuracy: 1e-6)
        XCTAssertEqual(taken.firstBeat, 0, accuracy: 1e-6, "a loop taken on the beat starts on a beat")
        let top = try XCTUnwrap(SampleTiming(grid: grid, from: 0, to: 30))
        XCTAssertEqual(top.bpm, 125, accuracy: 1e-6)
        XCTAssertEqual(top.firstBeat, 0.1, accuracy: 1e-6, "the top of a track is not as a rule a beat")
        XCTAssertNil(SampleTiming(grid: BeatGrid(beats: [1, 2]), from: 0, to: 2), "no grid to speak of")
    }

    // MARK: The audio core

    func testAHitGivenAFrameStartsOnThatFrameAndALateOneIsStillInTime() throws {
        let engine = try DeckEngine(offline: true)
        let sampler = engine.sampler
        sampler.load(loop(beats: 4, bpm: 120), on: 0)
        sampler.set(loops: true, on: 0)
        _ = try engine.render(frames: 3000)
        let now = sampler.snapshot().frame
        XCTAssertEqual(now, 3000)

        // Asked for part-way through a render, it starts there and not at the render's edge.
        sampler.trigger(0, at: now + 1111)
        let out = try engine.render(frames: 30000).left
        XCTAssertEqual(Probe.onsets(in: out, threshold: 0.05).first, 1111 + Self.delay)
        XCTAssertEqual(Probe.onsets(in: out, threshold: 0.05).dropFirst().first, 1111 + 22050 + Self.delay)

        // Asked for 5000 frames ago, it starts 5000 frames in: its second beat comes when it would have.
        sampler.stop()
        _ = try engine.render(frames: 4000)
        let later = sampler.snapshot().frame
        sampler.trigger(0, at: later - 5000)
        let late = try engine.render(frames: 30000).left
        XCTAssertEqual(Probe.onsets(in: late, threshold: 0.05).first, 22050 - 5000 + Self.delay)

        // At another speed its beats are that much closer together.
        sampler.stop()
        _ = try engine.render(frames: 4000)
        sampler.trigger(0, rate: 1.25)
        let fast = Probe.onsets(in: try engine.render(frames: 30000).left, threshold: 0.05)
        XCTAssertEqual(fast.first, Self.delay)
        XCTAssertEqual(Double(try XCTUnwrap(fast.dropFirst().first)), 22050 / 1.25 + Double(Self.delay), accuracy: 1.5)

        // A one-shot asked for late is not started part-way through: it is heard whole.
        sampler.stop()
        sampler.set(loops: false, on: 0)
        _ = try engine.render(frames: 4000)
        sampler.trigger(0, at: sampler.snapshot().frame - 5000)
        XCTAssertEqual(Probe.onsets(in: try engine.render(frames: 30000).left, threshold: 0.05).first, Self.delay)
    }

    func testAPadWaitingForItsFrameCountsAsPlayingAndCanBeCalledOff() throws {
        let engine = try DeckEngine(offline: true)
        let sampler = engine.sampler
        sampler.load(loop(beats: 4, bpm: 120), on: 0)
        _ = try engine.render(frames: 1024)
        sampler.trigger(0, at: sampler.snapshot().frame + 20000)
        _ = try engine.render(frames: 1024)
        XCTAssertTrue(sampler.state()[0].isPlaying)
        XCTAssertFalse(sampler.state()[0].isSounding)
        sampler.stop(0)
        let out = try engine.render(frames: 30000).left
        XCTAssertFalse(sampler.state()[0].isPlaying)
        XCTAssertEqual(out.map(abs).max() ?? 1, 0, accuracy: 1e-6, "stopped before it began")
    }

    // MARK: Starting on the beat

    func testALoopHitJustBeforeABeatWaitsForItAndStaysOnTheBeat() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.engine.deck(.a).play()
        try rig.render(1.65)   // the deck's beats fall at 0.25, 0.75, 1.25, 1.75...
        rig.sync.trigger(0)
        try rig.render(0.05)
        XCTAssertTrue(rig.sampler.state()[0].isPlaying)
        XCTAssertFalse(rig.sampler.state()[0].isSounding, "waiting for the beat")
        try rig.render(10)

        let pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 1.75, accuracy: 0.0005, "it starts from the top on the beat")
        XCTAssertEqual(pad.count, 20, accuracy: 1, "a blip on every beat from then on")
        let off = distances(pad, from: rig.deckOnsets())
        XCTAssertLessThan(off.max() ?? 99, 1, "every one of the loop's beats is within a millisecond of the deck's")
        XCTAssertEqual(rig.sync.rate(of: 0), 120.0 / 126, accuracy: 0.002, "slowed from 126 to the deck's 120")
    }

    func testALoopHitJustAfterABeatComesInAtOnceAsFarInAsItWouldHaveGot() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.engine.deck(.a).play()
        try rig.render(1.35)   // a tenth of a second after the beat at 1.25
        rig.sync.trigger(0)
        try rig.render(0.03)
        XCTAssertTrue(rig.sampler.state()[0].isSounding, "no waiting for the next beat")
        XCTAssertEqual(rig.sampler.state()[0].position, 0.13 * 120 / 126, accuracy: 0.002, "as far in as the beat is gone")
        try rig.render(10)

        let pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 1.75, accuracy: 0.001, "its second beat lands on the deck's next")
        XCTAssertLessThan(distances(pad, from: rig.deckOnsets()).max() ?? 99, 1)
    }

    func testALoopFollowsTheDeckWhenItsTempoIsMoved() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 120), on: rig)
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(3)
        rig.engine.deck(.a).set(.tempo, to: 1.06)
        try rig.render(2)   // a moment to catch up
        let from = Double(rig.heard.frames) / Probe.rate
        try rig.render(8)

        let deck = rig.deckOnsets(from: from), pad = rig.padOnsets(from: from)
        XCTAssertEqual(deck[5] - deck[4], 0.5 / 1.06, accuracy: 0.0005, "the deck is faster")
        XCTAssertGreaterThan(pad.count, 14)
        XCTAssertLessThan(distances(pad, from: deck).max() ?? 99, 1)
        XCTAssertEqual(rig.sync.rate(of: 0), 1.06, accuracy: 0.003)
        XCTAssertEqual(try XCTUnwrap(rig.sync.phaseError(for: 0)), 0, accuracy: 0.005)
    }

    func testALoopAtHalfOrDoubleTheTempoIsNotForcedToTheDecks() throws {
        // 61 against the deck's 120: played at 60, a beat to every two of the deck's, and not at double speed.
        var rig = try rig()
        load(loop(beats: 4, bpm: 61), on: rig, timing: SampleTiming(bpm: 61))
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(10)
        var pad = rig.padOnsets()
        XCTAssertEqual(rig.sync.rate(of: 0), 60.0 / 61, accuracy: 0.003)
        XCTAssertEqual(pad[3] - pad[2], 1, accuracy: 0.002)
        XCTAssertLessThan(distances(pad, from: rig.deckOnsets()).max() ?? 99, 1)

        // 236 against 120: played at 240, two beats to each of the deck's.
        rig = try self.rig()
        load(loop(beats: 8, bpm: 236), on: rig, timing: SampleTiming(bpm: 236))
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(6)
        pad = rig.padOnsets()
        XCTAssertEqual(rig.sync.rate(of: 0), 240.0 / 236, accuracy: 0.003)
        XCTAssertEqual(pad[5] - pad[4], 0.25, accuracy: 0.002)
        let halves = rig.deckOnsets().flatMap { [$0, $0 + 0.25] }
        XCTAssertLessThan(distances(pad, from: halves).max() ?? 99, 1)
    }

    func testAOneShotStartsOnTheBeatAtItsOwnSpeed() throws {
        var rig = try rig()
        load(SampleClip(audio: TrackAudio(left: Probe.sine(1000, seconds: 1), sampleRate: Probe.rate)), on: rig, loops: false)
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(1)
        let start = try XCTUnwrap(Probe.onsets(in: rig.heard.right, threshold: 0.02).first)
        XCTAssertEqual(Double(start) / Probe.rate - Self.delaySeconds, 1.75, accuracy: 0.0005)
        XCTAssertEqual(Probe.frequency(of: rig.heard.right[(start + 2000)..<(start + 20000)]), 1000, accuracy: 1, "not sped up or slowed down")
        XCTAssertEqual(rig.sync.rate(of: 0), 1)
    }

    func testWithNothingPlayingOrWithSyncAndQuantizeOffAPadStartsAtOnceAtItsOwnSpeed() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        // A track is on the deck but nothing has played: there is no beat to wait for.
        try rig.render(0.5)
        rig.sync.trigger(0)
        try rig.render(2)
        var pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 0.5, accuracy: 0.0005)
        XCTAssertEqual(pad[1] - pad[0], 60.0 / 126, accuracy: 0.0005)

        // Sync and Quantize both off, with the deck playing: straight away, wherever the beat is.
        rig = try self.rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.sync.set(synced: false, timing: SampleTiming(bpm: 126), for: 0)
        rig.sync.quantize = nil
        rig.engine.deck(.a).play()
        try rig.render(1.4)
        rig.sync.trigger(0)
        try rig.render(2)
        pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 1.4, accuracy: 0.0005)
        XCTAssertEqual(pad[1] - pad[0], 60.0 / 126, accuracy: 0.0005)
    }

    // MARK: Quantize

    /// When a one-shot hit at `time` starts sounding, with the deck's beats at 0.25, 0.75, 1.25, 1.75...
    private func oneShotStart(hitAt time: Double, quantize: Double?) throws -> Double {
        var rig = try rig()
        load(SampleClip(audio: TrackAudio(left: Probe.sine(1000, seconds: 0.3), sampleRate: Probe.rate)), on: rig, loops: false)
        rig.sync.quantize = quantize
        rig.engine.deck(.a).play()
        try rig.render(time)
        rig.sync.trigger(0)
        try rig.render(1.5)
        let start = try XCTUnwrap(Probe.onsets(in: rig.heard.right, threshold: 0.02).first)
        // Whole: it sounds for its full length from there, so none of its start was skipped.
        let loud = rig.heard.right.lastIndex { abs($0) > 0.02 } ?? 0
        XCTAssertEqual(Double(loud - start) / Probe.rate, 0.3, accuracy: 0.003)
        return Double(start) / Probe.rate - Self.delaySeconds
    }

    func testQuantizePutsAOneShotOnTheNextGridLineAndPlaysItWhole() throws {
        XCTAssertEqual(try oneShotStart(hitAt: 1.3, quantize: 1), 1.75, accuracy: 0.0005, "the next beat, not part-way in on the last")
        XCTAssertEqual(try oneShotStart(hitAt: 1.3, quantize: 0.5), 1.5, accuracy: 0.0005, "half beats")
        XCTAssertEqual(try oneShotStart(hitAt: 1.3, quantize: 0.25), 1.375, accuracy: 0.0005, "quarter beats")
        XCTAssertEqual(try oneShotStart(hitAt: 1.3, quantize: 4), 1.75, accuracy: 0.0005, "a one-shot does not wait for a bar")
        XCTAssertEqual(try oneShotStart(hitAt: 1.26, quantize: 1), 1.26, accuracy: 0.0005, "a hundredth of a second late is on the beat near enough")
        XCTAssertEqual(try oneShotStart(hitAt: 1.3, quantize: nil), 1.3, accuracy: 0.0005, "Quantize off")
    }

    func testQuantizeToTheBarBringsALoopInWhereTheBarIs() throws {
        // The loop sounds on its first beat only, so where that falls shows how it stands to the deck's bars.
        // The deck's bars start on its beat 1, 5, 9...: at 0.75, 2.75, 4.75 seconds.
        func rigged() throws -> Rig {
            let rig = try self.rig()
            var grid = try XCTUnwrap(rig.decks.grid(for: .a))
            grid.downbeat = 1
            rig.decks.setGrid(grid, for: .a)
            load(loop(beats: 4, bpm: 120, blips: [0]), on: rig)
            rig.sync.quantize = 4
            rig.engine.deck(.a).play()
            return rig
        }
        // Hit a beat and a bit into the bar: in at once, that far into the loop.
        var rig = try rigged()
        try rig.render(3.35)
        rig.sync.trigger(0)
        try rig.render(0.03)
        XCTAssertTrue(rig.sampler.state()[0].isSounding)
        XCTAssertEqual(rig.sampler.state()[0].position, 0.63, accuracy: 0.002)
        try rig.render(6)
        var pad = rig.padOnsets()
        XCTAssertEqual(pad.count, 3)
        for (onset, bar) in zip(pad, [4.75, 6.75, 8.75]) { XCTAssertEqual(onset, bar, accuracy: 0.001) }

        // Hit in the back half of the bar: it waits for the next one.
        rig = try rigged()
        try rig.render(4.2)
        rig.sync.trigger(0)
        try rig.render(0.03)
        XCTAssertFalse(rig.sampler.state()[0].isSounding)
        try rig.render(5)
        pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 4.75, accuracy: 0.0005)
        XCTAssertEqual(pad[1], 6.75, accuracy: 0.001)
    }

    func testQuantizePutsALoopWithoutSyncOnTheBeatAtItsOwnSpeed() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.sync.set(synced: false, timing: SampleTiming(bpm: 126), for: 0)
        rig.engine.deck(.a).play()
        try rig.render(1.65)
        rig.sync.trigger(0)
        try rig.render(2)
        let pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 1.75, accuracy: 0.0005, "started on the beat")
        XCTAssertEqual(pad[1] - pad[0], 60.0 / 126, accuracy: 0.0005, "and left at its own tempo from there")
        XCTAssertEqual(rig.sync.rate(of: 0), 1)
    }

    func testALoopWithSyncStartsOnTheBeatEvenWithQuantizeOff() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.sync.quantize = nil
        rig.engine.deck(.a).play()
        try rig.render(1.65)
        rig.sync.trigger(0)
        try rig.render(4)
        let pad = rig.padOnsets()
        XCTAssertEqual(try XCTUnwrap(pad.first), 1.75, accuracy: 0.0005)
        XCTAssertLessThan(distances(pad, from: rig.deckOnsets()).max() ?? 99, 1)
    }

    // MARK: Staying on it

    func testALoopCarriesOnAtItsTempoWhenTheDeckStops() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(3)
        rig.engine.deck(.a).pause()
        try rig.render(0.5)
        let from = Double(rig.heard.frames) / Probe.rate
        try rig.render(4)
        let pad = rig.padOnsets(from: from)
        XCTAssertGreaterThan(pad.count, 6)
        for (earlier, later) in zip(pad, pad.dropFirst()) {
            XCTAssertEqual(later - earlier, 0.5, accuracy: 0.004, "still at the deck's 120, not back at its own 126")
        }
    }

    func testALoopJumpsBackOntoTheBeatWhenTheDeckJumpsOffIt() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 120), on: rig)
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(3)
        // The deck is moved on by a beat and two fifths: its clicks now fall elsewhere.
        let state = rig.engine.deck(.a).state()
        rig.engine.deck(.a).seek(to: state.position + 0.7)
        try rig.render(0.6)
        let from = Double(rig.heard.frames) / Probe.rate
        try rig.render(5)
        let pad = rig.padOnsets(from: from)
        XCTAssertGreaterThan(pad.count, 8)
        XCTAssertLessThan(distances(pad, from: rig.deckOnsets()).max() ?? 99, 1, "back on the deck's beat within a moment")
    }

    func testALoopStartedOnItsOwnJoinsTheDeckWhenTheDeckStarts() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        try rig.render(0.3)
        rig.sync.trigger(0)
        try rig.render(2.13)
        rig.engine.deck(.a).play()
        try rig.render(1)
        let from = Double(rig.heard.frames) / Probe.rate
        try rig.render(5)
        let pad = rig.padOnsets(from: from)
        XCTAssertGreaterThan(pad.count, 8)
        XCTAssertLessThan(distances(pad, from: rig.deckOnsets()).max() ?? 99, 1)
        XCTAssertEqual(pad[3] - pad[2], 0.5, accuracy: 0.001)
    }

    func testTurningSyncOffPutsALoopBackToItsOwnSpeed() throws {
        var rig = try rig()
        load(loop(beats: 4, bpm: 126), on: rig)
        rig.engine.deck(.a).play()
        try rig.render(1.6)
        rig.sync.trigger(0)
        try rig.render(2)
        rig.sync.set(synced: false, timing: SampleTiming(bpm: 126), for: 0)
        try rig.render(0.5)
        let from = Double(rig.heard.frames) / Probe.rate
        try rig.render(3)
        let pad = rig.padOnsets(from: from)
        XCTAssertEqual(pad[2] - pad[1], 60.0 / 126, accuracy: 0.0005)
        XCTAssertNil(rig.sync.phaseError(for: 0))
    }

    // MARK: Which deck

    func testThePadsFollowTheDeckThatCanBeHeard() throws {
        let rig = try rig()
        let beats = Array(stride(from: 0.1, to: 39, by: 60 / 100.0))
        rig.engine.deck(.b).load(TrackAudio(left: [Float](repeating: 0, count: Int(40 * Probe.rate)), sampleRate: Probe.rate))
        rig.decks.setGrid(BeatGrid(beats: beats), for: .b)
        XCTAssertNil(rig.sync.reference, "nothing has played")
        rig.engine.deck(.a).play()
        _ = try rig.engine.render(seconds: 0.5)
        XCTAssertEqual(rig.sync.reference, .a)
        rig.engine.deck(.b).play()
        _ = try rig.engine.render(seconds: 0.5)
        XCTAssertEqual(rig.sync.reference, .a, "the master, while both are heard")

        // Mixed over to B, with A left running under a closed fader.
        var settings = rig.engine.settings
        settings.fader[0] = 0
        rig.engine.settings = settings
        _ = try rig.engine.render(seconds: 0.2)
        XCTAssertEqual(rig.decks.currentMaster, .a)
        XCTAssertEqual(rig.sync.reference, .b)

        settings.fader[0] = 1
        settings.crossfader = -1
        rig.engine.settings = settings
        XCTAssertEqual(rig.sync.reference, .a, "the crossfader counts as much as the fader")
    }
}

final class SampleClipTests: XCTestCase {
    func testAFileNamedAsALoopSaysSoAndGivesItsTempo() throws {
        XCTAssertEqual(SampleTiming.named("Drum Loop 124bpm")?.bpm, 124)
        XCTAssertEqual(SampleTiming.named("break_93.5 BPM_dry")?.bpm, 93.5)
        XCTAssertEqual(SampleTiming.named("TopLoop-128-bpm-Am")?.bpm, 128)
        XCTAssertNil(SampleTiming.named("Airhorn 3"), "a number alone is not a tempo")
        XCTAssertNil(SampleTiming.named("808 kick 2024bpm"), "nor is a year")
        XCTAssertNil(SampleTiming.named("slow 20bpm"), "nor a tempo nothing is played at")
        XCTAssertTrue(SampleTiming.namesALoop("Conga loop"))
        XCTAssertTrue(SampleTiming.namesALoop("hats 126 bpm"))
        XCTAssertFalse(SampleTiming.namesALoop("Airhorn"))
    }

    func testAClipsOutlineFollowsItsLoudness() {
        // Quiet for the first half, loud for the second, and only the stretch the clip covers is looked at.
        var samples = [Float](repeating: 0.1, count: 8000)
        for index in 4000..<8000 { samples[index] = index % 2 == 0 ? 0.5 : -0.5 }
        let audio = TrackAudio(left: [Float](repeating: 0.9, count: 1000) + samples, sampleRate: 44100)
        let peaks = SampleClip(audio: audio, range: 1000..<9000).peaks(bins: 8)
        XCTAssertEqual(peaks.count, 8)
        for bin in 0..<4 { XCTAssertEqual(peaks[bin], 0.2, accuracy: 1e-5) }
        for bin in 4..<8 { XCTAssertEqual(peaks[bin], 1, accuracy: 1e-5) }
        XCTAssertEqual(SampleClip(audio: audio, range: 0..<0).peaks(bins: 8), [])
    }
}

final class SamplerBankPadTests: XCTestCase {
    func testEachDeckHasEightPadsOfItsOwn() throws {
        XCTAssertEqual(Sampler.padCount, 16)
        XCTAssertEqual(Sampler.pad(0, of: .a), 0)
        XCTAssertEqual(Sampler.pad(7, of: .a), 7)
        XCTAssertEqual(Sampler.pad(0, of: .b), 8)
        XCTAssertEqual(Sampler.pad(7, of: .b), 15)

        // The last of deck B's plays and stops like any other, and alone.
        let engine = try DeckEngine(offline: true)
        let sampler = engine.sampler
        sampler.load(SampleClip(audio: TrackAudio(left: Probe.sine(440, seconds: 2), sampleRate: Probe.rate)), on: 15)
        sampler.trigger(15)
        let out = try engine.render(seconds: 0.2)
        XCTAssertEqual(out.left.map(abs).max() ?? 0, 0.5, accuracy: 0.02)
        let states = sampler.state()
        XCTAssertEqual(states.count, 16)
        XCTAssertTrue(states[15].isPlaying)
        XCTAssertEqual(states.filter(\.isPlaying).count, 1)
        sampler.stop(15)
        _ = try engine.render(seconds: 0.1)
        XCTAssertFalse(sampler.state()[15].isPlaying)
    }
}
