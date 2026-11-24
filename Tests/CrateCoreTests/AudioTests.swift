import AVFoundation
import XCTest
@testable import CrateCore

/// Signals with known timing and pitch, and ways to measure what comes out of the mixer.
enum Probe {
    static let rate = DeckEngine.sampleRate

    /// Silence with a short click at each of `times` (seconds).
    static func clicks(at times: [Double], seconds: Double, rate: Double = Probe.rate) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for time in times {
            let start = Int((time * rate).rounded())
            for offset in 0..<32 where start + offset < samples.count {
                samples[start + offset] = offset % 2 == 0 ? 0.8 : -0.8  // a burst right across the spectrum
            }
        }
        return samples
    }

    static func sine(_ hertz: Double, seconds: Double, amplitude: Float = 0.5, rate: Double = Probe.rate) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / rate)) }
    }

    /// The frame where each burst of sound starts.
    static func onsets(in samples: [Float], threshold: Float = 0.05, quiet: Int = 2000) -> [Int] {
        var found: [Int] = []
        var lastLoud = -quiet - 1
        for (index, sample) in samples.enumerated() where abs(sample) > threshold {
            if index - lastLoud > quiet { found.append(index) }
            lastLoud = index
        }
        return found
    }

    /// Frequency from the spacing of upward zero crossings.
    static func frequency(of samples: ArraySlice<Float>, rate: Double = Probe.rate) -> Double {
        var crossings: [Double] = []
        var previous: Float = 0
        for (index, sample) in zip(samples.indices, samples) {
            if previous < 0, sample >= 0 {
                crossings.append(Double(index) - Double(sample / (sample - previous)))
            }
            previous = sample
        }
        guard crossings.count > 2 else { return 0 }
        return Double(crossings.count - 1) * rate / (crossings[crossings.count - 1] - crossings[0])
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

final class DeckEngineTests: XCTestCase {
    private func engine() throws -> DeckEngine { try DeckEngine(offline: true) }

    func testATrackPlaysAtItsOwnSpeedAndStopsAtTheEnd() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.clicks(at: [0.5, 1.0, 1.5], seconds: 2), sampleRate: Probe.rate))
        XCTAssertEqual(deck.state().duration, 2, accuracy: 0.001)

        let silent = try engine.render(seconds: 0.25)
        XCTAssertLessThan(silent.left.map(abs).max() ?? 1, 1e-9, "a loaded deck is silent until it plays")

        deck.play()
        let played = try engine.render(seconds: 2.5)
        let onsets = Probe.onsets(in: played.left)
        XCTAssertEqual(onsets.count, 3)
        XCTAssertEqual(onsets[1] - onsets[0], 22050, "clicks half a second apart stay half a second apart")
        XCTAssertEqual(onsets[2] - onsets[1], 22050)

        let state = deck.state()
        XCTAssertTrue(state.isEnded)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.position, 2, accuracy: 0.001)
    }

    func testTempoChangesTheSpacingOfTheBeats() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.clicks(at: [0.5, 1.0, 1.5, 2.0], seconds: 3), sampleRate: Probe.rate))
        deck.set(.tempo, to: 1.05)
        _ = try engine.render(seconds: 0.1)
        deck.play()
        let onsets = Probe.onsets(in: try engine.render(seconds: 3).left)
        XCTAssertEqual(onsets.count, 4)
        for (earlier, later) in zip(onsets, onsets.dropFirst()) {
            XCTAssertEqual(Double(later - earlier), 22050 / 1.05, accuracy: 1.5)
        }
    }

    func testATrackAtAnotherSampleRatePlaysAtTheRightSpeed() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.sine(1000, seconds: 2, rate: 48000), sampleRate: 48000))
        deck.play()
        let output = try engine.render(seconds: 1.5)
        XCTAssertEqual(Probe.frequency(of: output.left[20000..<60000]), 1000, accuracy: 0.5)
    }

    func testVarispeedShiftsPitchAndKeyLockHoldsIt() throws {
        for keyLock in [false, true] {
            let engine = try engine()
            let deck = engine.deck(.a)
            deck.load(TrackAudio(left: Probe.sine(440, seconds: 6), sampleRate: Probe.rate))
            deck.keyLock = keyLock
            deck.set(.tempo, to: 1.06)
            deck.play()
            let output = try engine.render(seconds: 4)
            let frequency = Probe.frequency(of: output.left[88200..<154350])
            if keyLock {
                XCTAssertEqual(frequency, 440, accuracy: 2, "key lock keeps the note")
            } else {
                XCTAssertEqual(frequency, 440 * 1.06, accuracy: 0.5, "varispeed raises it with the speed")
            }
            // Either way the track is consumed 6% faster.
            XCTAssertEqual(deck.state().position, 4 * 1.06, accuracy: 0.02)
        }
    }

    func testKeyLockCanBeSwitchedWhilePlayingWithoutLosingThePlace() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.sine(440, seconds: 12), sampleRate: Probe.rate))
        deck.set(.tempo, to: 1.06)
        deck.play()
        _ = try engine.render(seconds: 1)
        XCTAssertEqual(deck.state().lead, 0)

        deck.keyLock = true
        let locked = try engine.render(seconds: 3)
        XCTAssertEqual(Probe.frequency(of: locked.left[66150...]), 440, accuracy: 2)
        XCTAssertGreaterThan(deck.state().lead, 1000, "the pitch shifter buffers, so the deck runs ahead of the output")
        XCTAssertEqual(deck.state().position, 4 * 1.06, accuracy: 0.03, "the reported place is what is heard")

        deck.keyLock = false
        let unlocked = try engine.render(seconds: 2)
        XCTAssertEqual(Probe.frequency(of: unlocked.left[44100...]), 440 * 1.06, accuracy: 0.5)
        XCTAssertEqual(deck.state().lead, 0)
        XCTAssertEqual(deck.state().position, 6 * 1.06, accuracy: 0.04, "taking key lock off does not skip the track")
        XCTAssertEqual(deck.state().frame - engine.outputFrame, deck.state().frameOffset)
    }

    func testCommandsLandOnTheExactFrame() throws {
        let engine = try engine()
        let a = engine.deck(.a), b = engine.deck(.b)
        // A click on the very first sample: starting a deck must not soften or delay it.
        let click = Probe.clicks(at: [0], seconds: 1)
        a.load(TrackAudio(left: click, sampleRate: Probe.rate))
        b.load(TrackAudio(left: click, sampleRate: Probe.rate))
        a.play(at: 10_000)
        b.play(at: 10_777)
        var settings = engine.settings
        settings.crossfader = -1
        engine.settings = settings
        let onlyA = Probe.onsets(in: try engine.render(frames: 20_000).left, threshold: 0.02)
        XCTAssertEqual(onlyA.count, 1, "deck B is faded out")

        a.seek(to: 0)
        b.seek(to: 0)
        a.pause()
        b.pause()
        settings.crossfader = 1
        engine.settings = settings
        _ = try engine.render(frames: 4000)
        XCTAssertEqual(b.state().frame, engine.outputFrame, "with key lock off a deck is not rendered ahead")
        let base = b.state().frame
        b.play(at: base + 5000)
        let rendered = try engine.render(frames: 12_000).left
        let onlyB = Probe.onsets(in: rendered, threshold: 0.02)
        XCTAssertEqual(onlyB.count, 1)
        // The same fixed delay through the mixer applies to both, so the difference is exact.
        XCTAssertEqual((onlyB[0] - 5000) - (onlyA[0] - 10_000), 0)
        XCTAssertGreaterThan(rendered[onlyB[0]..<(onlyB[0] + 40)].map(abs).max() ?? 0, 0.6, "the click keeps its level")
    }

    func testALoopRepeatsToTheSample() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        var random = SystemRandomNumberGenerator()
        let noise = (0..<Int(Probe.rate * 4)).map { _ in Float.random(in: -0.3...0.3, using: &random) }
        deck.load(TrackAudio(left: noise, sampleRate: Probe.rate))
        deck.loop(from: 1.0, to: 1.5)
        deck.play()
        let output = try engine.render(seconds: 5).left
        XCTAssertNotNil(deck.state().loop)
        XCTAssertEqual(deck.state().position, 1.25, accuracy: 0.26, "still inside the loop")
        // Compare two later passes of the loop, away from the short crossfade at the seam.
        let period = 22050
        let first = 44100 * 2 + 4000, second = first + period * 3
        var worst: Float = 0
        for offset in 0..<16000 { worst = max(worst, abs(output[first + offset] - output[second + offset])) }
        XCTAssertLessThan(worst, 1e-4)

        deck.endLoop()
        _ = try engine.render(seconds: 3)
        XCTAssertTrue(deck.state().isEnded, "with the loop off it plays out")
    }

    func testEQKillsRemoveTheirBandAndLeaveTheOthers() throws {
        func level(of hertz: Double, kill: DeckParam?) throws -> Float {
            let engine = try engine()
            let deck = engine.deck(.a)
            deck.load(TrackAudio(left: Probe.sine(hertz, seconds: 3, amplitude: 0.3), sampleRate: Probe.rate))
            if let kill { deck.set(kill, to: 0) }
            deck.play()
            return Probe.rms(try engine.render(seconds: 2).left[44100...])
        }
        let flatBass = try level(of: 60, kill: nil)
        XCTAssertEqual(flatBass, Float(0.3 / 2.0.squareRoot()), accuracy: 0.01, "flat EQ passes the level unchanged")
        XCTAssertLessThan(try level(of: 60, kill: .eqLow), flatBass * 0.01, "bass kill: at least 40 dB down")
        XCTAssertGreaterThan(try level(of: 60, kill: .eqHigh), flatBass * 0.95)
        let flatTop = try level(of: 9000, kill: nil)
        XCTAssertLessThan(try level(of: 9000, kill: .eqHigh), flatTop * 0.02)
        XCTAssertGreaterThan(try level(of: 9000, kill: .eqLow), flatTop * 0.95)
        let flatMid = try level(of: 800, kill: nil)
        XCTAssertLessThan(try level(of: 800, kill: .eqMid), flatMid * 0.12)
    }

    func testTheFilterKnobClosesFromEitherSide() throws {
        func level(of hertz: Double, knob: Double) throws -> Float {
            let engine = try engine()
            let deck = engine.deck(.a)
            deck.load(TrackAudio(left: Probe.sine(hertz, seconds: 3, amplitude: 0.3), sampleRate: Probe.rate))
            deck.set(.filter, to: knob)
            deck.play()
            return Probe.rms(try engine.render(seconds: 2).left[44100...])
        }
        let open = try level(of: 5000, knob: 0)
        XCTAssertLessThan(try level(of: 5000, knob: -0.8), open * 0.05, "low-pass closed: the highs are gone")
        XCTAssertGreaterThan(try level(of: 100, knob: -0.5), open * 0.9, "and the bass stays")
        XCTAssertLessThan(try level(of: 100, knob: 0.8), open * 0.05, "high-pass closed: the bass is gone")
    }

    func testEchoRepeatsInTimeAndCanBeCutDead() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.clicks(at: [0.2], seconds: 6), sampleRate: Probe.rate))
        deck.set(.echoFrames, to: 11025)  // a quarter of a second
        deck.set(.echoSend, to: 1)
        deck.set(.echoFeedback, to: 0.7)
        deck.play()
        let output = try engine.render(seconds: 1.5).left
        let onsets = Probe.onsets(in: output, threshold: 0.01)
        XCTAssertGreaterThanOrEqual(onsets.count, 4, "the click and at least three repeats")
        for (earlier, later) in zip(onsets, onsets.dropFirst()).prefix(3) {
            XCTAssertEqual(later - earlier, 11025, accuracy: 2)
        }
        deck.clearEcho()
        let after = try engine.render(seconds: 1).left
        XCTAssertLessThan(after[1000...].map(abs).max() ?? 1, 1e-4, "no tail after the cut")
    }

    func testATapeStopSlowsToSilenceAndScratchingFollowsTheHand() throws {
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.sine(1000, seconds: 10), sampleRate: Probe.rate))
        deck.play()
        _ = try engine.render(seconds: 1)
        deck.pause(brake: 1)
        let braking = try engine.render(seconds: 1).left
        XCTAssertLessThan(Probe.frequency(of: braking[30000..<40000]), 400, "the pitch falls as the platter slows")
        XCTAssertEqual(Probe.rms(try engine.render(seconds: 0.5).left[2000...]), 0, accuracy: 1e-4)
        XCTAssertFalse(deck.state().isPlaying)
        let stoppedAt = deck.state().position
        XCTAssertEqual(stoppedAt, 1.5, accuracy: 0.05, "braking over a second covers half a second of track")

        // Drag the record back a second over half a second: it plays backwards at twice speed.
        deck.beginScratch(at: stoppedAt)
        var heard: [Float] = []
        for step in 1...40 {
            deck.scratch(to: stoppedAt - Double(step) / 40)
            heard += try engine.render(frames: 551).left
        }
        XCTAssertTrue(deck.state().isScratching)
        XCTAssertEqual(Probe.frequency(of: heard[8000..<20000]), 2000, accuracy: 150)
        _ = try engine.render(seconds: 0.2)
        XCTAssertEqual(deck.state().position, stoppedAt - 1, accuracy: 0.01, "it ends where the hand stopped")
        deck.endScratch()
        _ = try engine.render(seconds: 0.5)
        XCTAssertFalse(deck.state().isScratching)
        XCTAssertEqual(deck.state().position, stoppedAt - 1, accuracy: 0.02, "the deck was paused, so it stays put")
    }

    func testCrossfaderAndFadersSetEachDecksLevel() throws {
        XCTAssertEqual(DeckEngine.crossfaderGains(0), [1, 1])
        XCTAssertEqual(DeckEngine.crossfaderGains(-1), [1, 0])
        XCTAssertEqual(DeckEngine.crossfaderGains(0.5), [0.5, 1])

        let engine = try engine()
        let deck = engine.deck(.b)
        deck.load(TrackAudio(left: Probe.sine(500, seconds: 4, amplitude: 0.4), sampleRate: Probe.rate))
        deck.play()
        var settings = engine.settings
        settings.fader[1] = 0.5
        engine.settings = settings
        XCTAssertEqual(Probe.rms(try engine.render(seconds: 1).left[22050...]), Float(0.2 / 2.0.squareRoot()), accuracy: 0.005)
        XCTAssertEqual(deck.state().peak, 0.2, accuracy: 0.01)
    }

    func testLoadingAFileDecodesItAndASecondLoadReplacesTheFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crate-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.wav")
        try Synth.writeWAV(Probe.sine(660, seconds: 3), sampleRate: 44100, to: url)

        let audio = try TrackAudio.load(path: url.path)
        XCTAssertEqual(audio.duration, 3, accuracy: 0.001)
        XCTAssertEqual(audio.progress, 1)
        let engine = try engine()
        let deck = engine.deck(.a)
        deck.load(audio)
        deck.play()
        XCTAssertEqual(Probe.frequency(of: try engine.render(seconds: 1).left[10000...]), 660, accuracy: 0.5)

        deck.load(TrackAudio(left: Probe.sine(220, seconds: 2), sampleRate: Probe.rate))
        _ = try engine.render(seconds: 0.1)
        XCTAssertEqual(deck.state().position, 0, "a newly loaded track waits at its start")
        XCTAssertFalse(deck.state().isPlaying)
        deck.play()
        XCTAssertEqual(Probe.frequency(of: try engine.render(seconds: 1).left[10000...]), 220, accuracy: 0.5)
        XCTAssertThrowsError(try TrackAudio.load(path: folder.appendingPathComponent("missing.wav").path))
    }
}

final class DeckSyncTests: XCTestCase {
    /// Deck A's clicks on the left channel only, deck B's on the right, so each can be timed in the mix.
    private func load(_ engine: DeckEngine, _ sync: DeckSync, deck: DeckID, beats: [Double], seconds: Double) {
        let clicks = Probe.clicks(at: beats, seconds: seconds)
        let silence = [Float](repeating: 0, count: clicks.count)
        engine.deck(deck).load(TrackAudio(left: deck == .a ? clicks : silence, right: deck == .a ? silence : clicks, sampleRate: Probe.rate))
        sync.setGrid(BeatGrid(beats: beats), for: deck)
    }

    /// For each click of deck A after `after` seconds, how far the nearest click of deck B is, in milliseconds.
    private func gaps(_ audio: StereoAudio, after: Double) -> [Double] {
        let a = Probe.onsets(in: audio.left, threshold: 0.03, quiet: 1000)
        let b = Probe.onsets(in: audio.right, threshold: 0.03, quiet: 1000)
        return a.filter { Double($0) > after * Probe.rate }.compactMap { click in
            b.map { abs($0 - click) }.min().map { Double($0) / Probe.rate * 1000 }
        }
    }

    private func steady(_ bpm: Double, seconds: Double, first: Double = 0.25) -> [Double] {
        Array(stride(from: first, to: seconds - 0.1, by: 60 / bpm))
    }

    func testASyncedDeckLandsOnTheMastersBeatsFromItsFirstBeat() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: steady(120, seconds: 30), seconds: 30)
        load(engine, sync, deck: .b, beats: steady(126, seconds: 30, first: 0.4), seconds: 30)
        engine.deck(.a).play()
        var audio = try engine.render(seconds: 2.13)   // press play on B at an arbitrary moment
        sync.setSync(true, for: .b)
        sync.play(.b)
        let rest = try engine.render(seconds: 12)
        audio.left += rest.left
        audio.right += rest.right

        XCTAssertEqual(sync.currentMaster, .a)
        let all = gaps(audio, after: 2.6)
        XCTAssertGreaterThan(all.count, 15)
        XCTAssertLessThan(all.max() ?? 99, 2, "in time from the first beat, not after a wobble: worst gap \(all.max() ?? 99) ms")
        XCTAssertEqual(engine.deck(.b).value(of: .tempo), 120.0 / 126.0, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(sync.beat(for: .b)).bpm, 120, accuracy: 0.3)
        XCTAssertLessThan(abs(try XCTUnwrap(sync.phaseError(for: .b))), 0.01)
    }

    func testSyncPullsInADeckThatWasStartedOutOfTime() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: steady(120, seconds: 40), seconds: 40)
        load(engine, sync, deck: .b, beats: steady(123, seconds: 40, first: 0.37), seconds: 40)
        engine.deck(.a).play()
        engine.deck(.b).play()          // free-running at its own tempo
        _ = try engine.render(seconds: 3)
        sync.setSync(true, for: .b)     // Sync pressed while both play
        let audio = try engine.render(seconds: 10)
        let settled = gaps(audio, after: 0.6)
        XCTAssertGreaterThan(settled.count, 15)
        XCTAssertLessThan(settled.max() ?? 99, 3, "it jumps onto the beat at once: worst gap from the next beat on \(settled.max() ?? 99) ms")
    }

    func testATrackReadAtHalfTempoStillSyncsAtItsOwnSpeed() throws {
        // A 134 BPM tune whose grid counts 67: every other beat. It must not be played at double speed.
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: steady(130, seconds: 40), seconds: 40)
        load(engine, sync, deck: .b, beats: steady(67, seconds: 40, first: 0.4), seconds: 40)
        engine.deck(.a).play()
        _ = try engine.render(seconds: 2.2)
        sync.setSync(true, for: .b)
        sync.play(.b)
        let audio = try engine.render(seconds: 14)
        XCTAssertEqual(engine.deck(.b).value(of: .tempo), 130.0 / 134.0, accuracy: 0.003)
        // Every click of B (one every two beats) lands on a click of A.
        let a = Probe.onsets(in: audio.left, threshold: 0.03, quiet: 1000)
        let b = Probe.onsets(in: audio.right, threshold: 0.03, quiet: 1000)
        let misses = b.compactMap { click in a.map { abs($0 - click) }.min().map { Double($0) / Probe.rate * 1000 } }
        XCTAssertGreaterThan(misses.count, 10)
        XCTAssertLessThan(misses.max() ?? 99, 2)

        // And the other way round: a deck counting every beat follows a master counting every other one.
        sync.setSync(false, for: .b)
        XCTAssertEqual(DeckSync.beatRatio(masterBPM: 67, ownBPM: 130), 0.5)
        XCTAssertEqual(DeckSync.phaseError(master: 10.25, own: 20.5, ratio: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(DeckSync.phaseError(master: 10.25, own: 21.5, ratio: 0.5), 0, accuracy: 1e-9, "either of its beats may sit on the master's")
        XCTAssertEqual(DeckSync.phaseError(master: 10.3, own: 20.5, ratio: 0.5), 0.05, accuracy: 1e-9)
    }

    func testSyncFollowsAMasterWhoseTempoDrifts() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: Synth.driftingBeats(from: 116, to: 126, seconds: 45), seconds: 45)
        load(engine, sync, deck: .b, beats: steady(121, seconds: 60), seconds: 60)
        engine.deck(.a).play()
        _ = try engine.render(seconds: 1)
        sync.setSync(true, for: .b)
        sync.play(.b)
        let audio = try engine.render(seconds: 40)
        let all = gaps(audio, after: 1)
        XCTAssertGreaterThan(all.count, 60)
        XCTAssertLessThan(all.max() ?? 99, 5, "worst gap \(all.max() ?? 99) ms")
        XCTAssertLessThan(all.sorted()[all.count / 2], 2)
    }

    func testSyncHoldsWithKeyLockOnTheFollower() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: steady(120, seconds: 40), seconds: 40)
        load(engine, sync, deck: .b, beats: steady(125, seconds: 40, first: 0.4), seconds: 40)
        engine.deck(.b).keyLock = true
        engine.deck(.a).play()
        _ = try engine.render(seconds: 2)
        sync.setSync(true, for: .b)
        sync.play(.b)
        let audio = try engine.render(seconds: 14)
        let settled = gaps(audio, after: 4)
        XCTAssertGreaterThan(settled.count, 10)
        // The pitch shifter smears a click over a few milliseconds, so this is looser than varispeed.
        XCTAssertLessThan(settled.max() ?? 99, 12, "worst gap \(settled.max() ?? 99) ms")
    }

    func testWhenTheMasterStopsTheOtherDeckTakesOverAndKeepsTheJob() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: steady(120, seconds: 40), seconds: 40)
        load(engine, sync, deck: .b, beats: steady(126, seconds: 40), seconds: 40)
        engine.deck(.a).play()
        _ = try engine.render(seconds: 1)
        sync.setSync(true, for: .b)
        sync.play(.b)
        _ = try engine.render(seconds: 3)
        XCTAssertEqual(sync.currentMaster, .a)
        let followed = engine.deck(.b).value(of: .tempo)
        XCTAssertEqual(followed, 120.0 / 126.0, accuracy: 0.002)

        engine.deck(.a).pause()
        _ = try engine.render(seconds: 1)
        XCTAssertEqual(sync.currentMaster, .b, "the deck still playing is the master now")
        XCTAssertEqual(engine.deck(.b).value(of: .tempo), followed, accuracy: 0.002, "and it carries on at the tempo it had")

        // The first deck starting again does not take the job back; synced, it follows the new master.
        engine.deck(.a).play()
        _ = try engine.render(seconds: 1)
        XCTAssertEqual(sync.currentMaster, .b)
        sync.setSync(true, for: .a)
        _ = try engine.render(seconds: 3)
        XCTAssertEqual(sync.currentMaster, .b)
        XCTAssertEqual(try XCTUnwrap(sync.beat(for: .a)).bpm, 120, accuracy: 0.3)
        XCTAssertLessThan(abs(try XCTUnwrap(sync.phaseError(for: .a))), 0.01)
    }

    func testAMasterPickedByHandAlsoHandsOverWhenItStopsOrItsTrackEnds() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        load(engine, sync, deck: .a, beats: steady(120, seconds: 6), seconds: 6)   // a short track
        load(engine, sync, deck: .b, beats: steady(124, seconds: 40), seconds: 40)
        engine.deck(.b).play()
        _ = try engine.render(seconds: 0.5)
        sync.master = .a
        XCTAssertEqual(sync.currentMaster, .a, "picked while stopped, it sets the tempo for the deck that is playing")
        engine.deck(.a).play()
        _ = try engine.render(seconds: 2)
        XCTAssertEqual(sync.currentMaster, .a)
        _ = try engine.render(seconds: 6)      // deck A runs off the end of its track
        XCTAssertFalse(engine.deck(.a).state().isPlaying)
        XCTAssertEqual(sync.currentMaster, .b)
        XCTAssertEqual(sync.master, .b)
    }

    func testTheMasterIsTheChosenDeckOrElseThePlayingOne() throws {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        XCTAssertNil(sync.currentMaster)
        load(engine, sync, deck: .a, beats: steady(120, seconds: 20), seconds: 20)
        load(engine, sync, deck: .b, beats: steady(110, seconds: 20), seconds: 20)
        _ = try engine.render(seconds: 0.1)
        XCTAssertNil(sync.currentMaster, "nothing playing, nothing chosen")
        engine.deck(.b).play()
        _ = try engine.render(seconds: 0.5)
        XCTAssertEqual(sync.currentMaster, .b)
        sync.master = .a
        XCTAssertEqual(sync.currentMaster, .a)

        // A stopped synced deck is matched in tempo to the master, ready to start.
        sync.master = .b
        sync.setSync(true, for: .a)
        _ = try engine.render(seconds: 0.2)
        XCTAssertEqual(engine.deck(.a).value(of: .tempo), 110.0 / 120.0, accuracy: 0.002)

        // With sync off the deck keeps the tempo it had.
        sync.setSync(false, for: .a)
        _ = try engine.render(seconds: 0.2)
        XCTAssertEqual(engine.deck(.a).value(of: .tempo), 110.0 / 120.0, accuracy: 0.002)
        XCTAssertNil(sync.phaseError(for: .a))
    }
}

final class RecordingTests: XCTestCase {
    func testARecordingHoldsWhatTheMixerPlayed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crate-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("mix.wav")

        let engine = try DeckEngine(offline: true)
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.sine(440, seconds: 5, amplitude: 0.4), sampleRate: Probe.rate))
        deck.play()
        _ = try engine.render(seconds: 0.5)
        XCTAssertFalse(engine.isRecording)
        try engine.startRecording(to: url)
        let played = try engine.render(seconds: 2)
        XCTAssertTrue(engine.isRecording)
        // The output is handed over in tenth-of-a-second pieces, so the very end can be missing.
        XCTAssertEqual(engine.stopRecording(), 2, accuracy: 0.25)
        XCTAssertEqual(engine.takeMasterPeak(), 0.4, accuracy: 0.06)
        XCTAssertEqual(engine.takeMasterPeak(), 0, "reading the peak resets it")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2, accuracy: 0.25)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let recorded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        XCTAssertEqual(Probe.frequency(of: recorded[2000...]), 440, accuracy: 0.5)
        XCTAssertEqual(Probe.rms(recorded[2000...]), Probe.rms(played.left[2000...]), accuracy: 0.005)
    }
}

final class TransitionTests: XCTestCase {
    private struct Rig {
        let engine: DeckEngine
        let sync: DeckSync
        let runner: TransitionRunner
    }

    /// Deck A at 120 BPM with its clicks on the left channel, deck B at 126 with its clicks on the right.
    private func rig(seconds: Double = 60) throws -> Rig {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        let runner = TransitionRunner(engine: engine, sync: sync)
        for (deck, bpm, first) in [(DeckID.a, 120.0, 0.25), (.b, 126.0, 0.4)] {
            let beats = Array(stride(from: first, to: seconds - 0.1, by: 60 / bpm))
            let clicks = Probe.clicks(at: beats, seconds: seconds)
            let silence = [Float](repeating: 0, count: clicks.count)
            engine.deck(deck).load(TrackAudio(left: deck == .a ? clicks : silence, right: deck == .a ? silence : clicks, sampleRate: Probe.rate))
            sync.setGrid(BeatGrid(beats: beats), for: deck)
        }
        return Rig(engine: engine, sync: sync, runner: runner)
    }

    private func render(_ rig: Rig, seconds: Double, into audio: inout StereoAudio) throws {
        let more = try rig.engine.render(seconds: seconds)
        audio.left += more.left
        audio.right += more.right
    }

    func testTheShapeOfEachStyle() {
        let swap = Transition(style: .bassSwap, beats: 32, startBeat: 0, incomingBeat: 0)
        XCTAssertEqual(swap.levels(at: 0), Transition.Levels(outgoingFader: 1, incomingFader: 0, outgoingLow: 1, incomingLow: 0, outgoingFilter: 0))
        XCTAssertEqual(swap.levels(at: 0.4).incomingFader, 1, "the new track is up by a quarter of the way")
        XCTAssertEqual(swap.levels(at: 0.4).incomingLow, 0, "but only one bass line plays at a time")
        XCTAssertEqual(swap.levels(at: 0.6).outgoingLow, 0)
        XCTAssertEqual(swap.levels(at: 0.6).incomingLow, 1)
        XCTAssertEqual(swap.levels(at: 1).outgoingFader, 0)

        let blend = Transition(style: .blend, beats: 16, startBeat: 0, incomingBeat: 0)
        XCTAssertEqual(blend.levels(at: 0.25).incomingFader, 0.5)
        XCTAssertEqual(blend.levels(at: 0.75).outgoingFader, 0.5)
        XCTAssertEqual(blend.levels(at: 0.5).outgoingLow, 1, "a plain blend leaves the EQ alone")
        XCTAssertEqual(Transition(style: .filter, startBeat: 0, incomingBeat: 0).levels(at: 1).outgoingFilter, 0.8, accuracy: 1e-9)
        XCTAssertFalse(Transition.Style.cut.overlaps)
    }

    func testABassSwapStartsOnTheBeatSwapsHalfwayAndHandsOver() throws {
        let rig = try rig()
        let finished = Atomic()
        rig.runner.onFinish = { deck in finished.set(deck == .b ? 1 : -1) }
        rig.engine.deck(.a).play()
        var audio = try rig.engine.render(seconds: 1)

        // Mix out of A from its beat 8, over 16 beats, bringing B in from its beat 4.
        try rig.runner.start(Transition(style: .bassSwap, beats: 16, startBeat: 8, incomingBeat: 4), from: .a)
        XCTAssertEqual(rig.runner.status.phase, .armed)
        XCTAssertEqual(rig.runner.status.beatsToGo, 6.5, accuracy: 0.1)
        XCTAssertEqual(rig.engine.settings.fader[1], 0, "the incoming deck starts silent")

        try render(rig, seconds: 2.5, into: &audio)   // 3.5 s: still before beat 8 (at 4.25 s)
        XCTAssertFalse(rig.engine.deck(.b).state().isPlaying)
        try render(rig, seconds: 3.75, into: &audio)  // 7.25 s: beat 14, six beats in
        XCTAssertEqual(rig.runner.status.phase, .mixing)
        XCTAssertTrue(rig.engine.deck(.b).state().isPlaying)
        XCTAssertEqual(rig.engine.settings.fader[1], 1, "up by a quarter of the way")
        XCTAssertEqual(rig.engine.deck(.b).value(of: .eqLow), 0, accuracy: 0.01)
        XCTAssertEqual(rig.engine.deck(.a).value(of: .eqLow), 1, accuracy: 0.01)

        try render(rig, seconds: 2, into: &audio)     // 9.25 s: beat 18, past the swap at beat 16
        XCTAssertEqual(rig.engine.deck(.b).value(of: .eqLow), 1, accuracy: 0.01)
        XCTAssertEqual(rig.engine.deck(.a).value(of: .eqLow), 0, accuracy: 0.01)
        XCTAssertEqual(finished.value, 0)

        try render(rig, seconds: 3.5, into: &audio)   // 12.75 s: past beat 24, the end
        XCTAssertEqual(finished.value, 1)
        XCTAssertFalse(rig.engine.deck(.a).state().isPlaying)
        XCTAssertTrue(rig.engine.deck(.b).state().isPlaying)
        XCTAssertEqual(rig.engine.settings.fader, [1, 1], "faders back up, ready for the next mix")
        XCTAssertEqual(rig.engine.deck(.a).value(of: .eqLow), 1)
        XCTAssertEqual(rig.sync.master, .b)
        XCTAssertFalse(rig.sync.isSynced(.b))
        XCTAssertEqual(rig.runner.status.phase, .settling)

        // Through the overlap every click of B that can be heard sits on a click of A.
        let a = Probe.onsets(in: audio.left, threshold: 0.03, quiet: 1000)
        let b = Probe.onsets(in: audio.right, threshold: 0.03, quiet: 1000)
        let overlap = b.filter { Double($0) / Probe.rate < 11.5 }
        XCTAssertGreaterThan(overlap.count, 10)
        XCTAssertGreaterThan(Double(overlap[0]) / Probe.rate, 4.2, "B is not heard before the mix starts")
        let worst = overlap.map { click in a.map { abs($0 - click) }.min() ?? 99999 }.max() ?? 99999
        XCTAssertLessThan(Double(worst) / Probe.rate * 1000, 2, "worst gap \(Double(worst) / Probe.rate * 1000) ms")

        // Afterwards B eases back to its own tempo.
        try render(rig, seconds: 10, into: &audio)
        XCTAssertEqual(rig.runner.status.phase, .idle)
        XCTAssertEqual(rig.engine.deck(.b).value(of: .tempo), 1, accuracy: 0.0001)
    }

    func testACutSwitchesDecksOnTheBeat() throws {
        let rig = try rig()
        rig.engine.deck(.a).play()
        var audio = try rig.engine.render(seconds: 1)
        try rig.runner.start(Transition(style: .cut, startBeat: 8, incomingBeat: 8, keepTempo: true), from: .a)
        try render(rig, seconds: 6, into: &audio)
        XCTAssertFalse(rig.engine.deck(.a).state().isPlaying)
        XCTAssertTrue(rig.engine.deck(.b).state().isPlaying)
        XCTAssertEqual(rig.runner.status.phase, .idle)
        XCTAssertEqual(rig.engine.deck(.b).value(of: .tempo), 120.0 / 126.0, accuracy: 0.002, "asked to keep the old tempo")

        let a = Probe.onsets(in: audio.left, threshold: 0.03, quiet: 1000).map { Double($0) / Probe.rate }
        let b = Probe.onsets(in: audio.right, threshold: 0.03, quiet: 1000).map { Double($0) / Probe.rate }
        XCTAssertEqual(a.count, 8, "A plays beats 0 to 7 and is gone by beat 8")
        // B's first click is where A's ninth would have been: 0.25 + 8 × 0.5 seconds.
        XCTAssertEqual(try XCTUnwrap(b.first), try XCTUnwrap(a.last) + 0.5, accuracy: 0.002)
        XCTAssertEqual(b[1] - b[0], 0.5, accuracy: 0.002, "and it carries on at A's tempo")
    }

    func testAMixCanBeRefusedOrCancelled() throws {
        let rig = try rig()
        let mix = Transition(style: .blend, beats: 8, startBeat: 8, incomingBeat: 0)
        XCTAssertThrowsError(try rig.runner.start(mix, from: .a)) { error in
            XCTAssertEqual(error.localizedDescription, "Deck A is not playing.")
        }
        rig.engine.deck(.a).play()
        _ = try rig.engine.render(seconds: 6)
        XCTAssertThrowsError(try rig.runner.start(mix, from: .a)) { error in
            XCTAssertEqual(error.localizedDescription, "That point in the track has already gone by.")
        }
        rig.engine.deck(.b).load(nil)
        _ = try rig.engine.render(seconds: 0.1)
        XCTAssertThrowsError(try rig.runner.start(Transition(style: .blend, beats: 8, startBeat: 20, incomingBeat: 0), from: .a))

        let fresh = try self.rig()
        fresh.engine.deck(.a).play()
        _ = try fresh.engine.render(seconds: 1)
        try fresh.runner.start(Transition(style: .blend, beats: 8, startBeat: 8, incomingBeat: 0), from: .a)
        _ = try fresh.engine.render(seconds: 5)   // two beats into the mix
        XCTAssertEqual(fresh.runner.status.phase, .mixing)
        fresh.runner.cancel()
        let fader = fresh.engine.settings.fader[1]
        _ = try fresh.engine.render(seconds: 3)
        XCTAssertEqual(fresh.runner.status.phase, .idle)
        XCTAssertEqual(fresh.engine.settings.fader[1], fader, "after a cancel nothing moves on its own")
        XCTAssertTrue(fresh.engine.deck(.a).state().isPlaying)
        XCTAssertTrue(fresh.engine.deck(.b).state().isPlaying)
    }
}

/// A value shared with a callback from another thread.
final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func set(_ value: Int) { lock.withLock { stored = value } }
}

final class MetronomeTests: XCTestCase {
    func testClicksLandOnTheGridsBeatsAtAnyTempo() throws {
        for tempo in [1.0, 1.06] {
            let engine = try DeckEngine(offline: true)
            let deck = engine.deck(.a)
            // A silent track, so only the metronome is heard.
            deck.load(TrackAudio(left: [Float](repeating: 0, count: Int(Probe.rate * 12)), sampleRate: Probe.rate))
            let grid = BeatGrid(beats: Synth.driftingBeats(from: 118, to: 126, seconds: 12, start: 0.37))
            deck.setMetronome(beats: grid.beats, accents: grid.beats.indices.map { grid.beatInBar($0) == 1 }, level: 1)
            deck.set(.tempo, to: tempo)
            _ = try engine.render(seconds: 0.1)
            let offset = try engine.render(frames: 0).frames  // no audio; keeps the arithmetic below honest
            XCTAssertEqual(offset, 0)
            deck.play()
            let output = try engine.render(seconds: 6).left
            let heard = Probe.onsets(in: output, threshold: 0.02, quiet: 3000)
            let expected = grid.beats.filter { $0 / tempo < 5.9 }.map { $0 / tempo * Probe.rate }
            XCTAssertEqual(heard.count, expected.count, "one click per beat at tempo \(tempo)")
            // The limiter delays everything by the same 88 frames; allow a couple of frames for the click's first rise.
            let delays = zip(heard, expected).map { Double($0) - $1 }
            XCTAssertLessThan((delays.max() ?? 0) - (delays.min() ?? 0), 3, "every click the same distance from its beat")
        }
    }

    func testTheBarStartSoundsDifferentAndTheMetronomeFollowsSeeksAndCanBeTurnedOff() throws {
        let engine = try DeckEngine(offline: true)
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: [Float](repeating: 0, count: Int(Probe.rate * 30)), sampleRate: Probe.rate))
        let grid = BeatGrid(bpm: 120, firstBeat: 0.25, duration: 30)
        deck.setMetronome(beats: grid.beats, accents: grid.beats.indices.map { grid.beatInBar($0) == 1 }, level: 1)
        deck.play()
        let output = try engine.render(seconds: 2.2).left
        let clicks = Probe.onsets(in: output, threshold: 0.02, quiet: 3000)
        XCTAssertEqual(clicks.count, 4)
        XCTAssertEqual(Probe.frequency(of: output[(clicks[0] + 20)..<(clicks[0] + 500)]), 1760, accuracy: 60, "beat 1 of the bar")
        XCTAssertEqual(Probe.frequency(of: output[(clicks[1] + 20)..<(clicks[1] + 500)]), 1100, accuracy: 40)

        // Jump back: the clicks pick up from the new place.
        deck.seek(to: 10.2)
        let after = Probe.onsets(in: try engine.render(seconds: 1).left, threshold: 0.02, quiet: 3000)
        XCTAssertEqual(after.count, 2, "beats at 10.25 and 10.75")
        XCTAssertEqual(Double(after[1] - after[0]) / Probe.rate, 0.5, accuracy: 0.001)

        deck.setMetronome(beats: [], accents: [], level: 0)
        _ = try engine.render(seconds: 0.2)
        XCTAssertLessThan(try engine.render(seconds: 2).left.map(abs).max() ?? 1, 1e-6, "off means silent")
    }
}

/// Headphone monitoring: the second pair of the engine's four channels.
final class HeadphoneTests: XCTestCase {
    private func level(_ samples: ArraySlice<Float>) -> Float { samples.map(abs).max() ?? 0 }

    func testTheHeadphonesHearACuedDeckBeforeItsFaderAndTheMasterInStep() throws {
        let engine = try DeckEngine(offline: true)
        let a = engine.deck(.a), b = engine.deck(.b)
        a.load(TrackAudio(left: Probe.sine(440, seconds: 12), sampleRate: Probe.rate))
        b.load(TrackAudio(left: Probe.sine(1000, seconds: 12), sampleRate: Probe.rate))
        var settings = engine.settings
        settings.fader = [1, 0]            // B is not in the mix yet
        settings.cue = [false, true]       // …but it is cued
        settings.headphoneMix = 0          // headphones: cue only
        engine.settings = settings
        a.play()
        b.play()
        _ = try engine.render(seconds: 0.3)

        var out = try engine.renderBoth(seconds: 1)
        XCTAssertEqual(Probe.frequency(of: out.master.left[...]), 440, accuracy: 2, "the room hears deck A")
        XCTAssertEqual(Probe.frequency(of: out.phones.left[...]), 1000, accuracy: 4, "the headphones hear deck B, whose fader is down")
        XCTAssertEqual(level(out.phones.left[...]), 0.5, accuracy: 0.02, "at its own level, before the fader")

        // Uncued, the deck is not heard anywhere.
        settings.cue = [false, false]
        engine.settings = settings
        _ = try engine.render(seconds: 0.2)
        out = try engine.renderBoth(seconds: 0.5)
        XCTAssertLessThan(level(out.phones.left[...]), 0.001)

        // Turned to the master, the headphones carry the master mix, sample for sample.
        settings.headphoneMix = 1
        engine.settings = settings
        _ = try engine.render(seconds: 0.2)
        out = try engine.renderBoth(seconds: 1)
        XCTAssertEqual(level(out.phones.left[...]), level(out.master.left[...]), accuracy: 0.001)
        XCTAssertLessThan(zip(out.master.left, out.phones.left).map { abs($0 - $1) }.max() ?? 1, 0.0005)

        // The master volume turns the room down, not the cue.
        settings.headphoneMix = 0
        settings.cue = [true, false]
        settings.master = 0.25
        engine.settings = settings
        _ = try engine.render(seconds: 0.2)
        out = try engine.renderBoth(seconds: 0.5)
        XCTAssertEqual(level(out.master.left[...]), 0.125, accuracy: 0.01)
        XCTAssertEqual(level(out.phones.left[...]), 0.5, accuracy: 0.02)
    }

    func testTheCueStaysInStepWithTheMasterUnderKeyLock() throws {
        let engine = try DeckEngine(offline: true)
        let a = engine.deck(.a)
        let beats = stride(from: 0.25, to: 19.0, by: 0.5).map { $0 }
        a.load(TrackAudio(left: Probe.clicks(at: beats, seconds: 20), sampleRate: Probe.rate))
        var settings = engine.settings
        settings.cue = [true, false]
        settings.headphoneMix = 0
        engine.settings = settings
        a.keyLock = true
        a.set(.tempo, to: 1.04)
        a.play()
        let out = try engine.renderBoth(seconds: 8)
        let room = Probe.onsets(in: out.master.left, threshold: 0.03, quiet: 1000)
        let ears = Probe.onsets(in: out.phones.left, threshold: 0.03, quiet: 1000)
        XCTAssertGreaterThan(room.count, 10)
        XCTAssertEqual(room.count, ears.count)
        // The pitch shifter smears a click a little differently on each channel, so where each one
        // crosses the threshold can differ by a millisecond or so. What matters is that neither
        // output runs ahead of the other: no buffer's worth, let alone a beat's.
        let apart = zip(room, ears).map { abs($0 - $1) }.max() ?? 999
        XCTAssertLessThan(apart, 88, "every click reaches the headphones with the speakers: \(apart) frames (of 44,100 a second) apart at most")
        let differences: [Double] = zip(room, ears).map { Double($0 - $1) }
        let lean: Double = differences.reduce(0, +) / Double(room.count)
        XCTAssertLessThan(abs(lean), 22, "and neither leads on average: \(lean) frames")
    }
}

/// The DDJ-FLX4's MIDI, read against the controller's published message list.
final class ControllerTests: XCTestCase {
    private func events(_ messages: [[UInt8]]) -> [ControlEvent] {
        var decoder = DDJFLX4.Decoder()
        return messages.compactMap { decoder.decode(status: $0[0], data1: $0[1], data2: $0[2]) }
    }

    func testButtonsJogWheelsAndPads() {
        XCTAssertEqual(events([[0x90, 0x0B, 0x7F], [0x90, 0x0B, 0x00], [0x91, 0x0B, 0x7F]]), [.play(.a), .play(.b)], "a press, not the release")
        XCTAssertEqual(events([[0x91, 0x0C, 0x7F], [0x91, 0x0C, 0x00]]), [.cue(.b, down: true), .cue(.b, down: false)])
        XCTAssertEqual(events([[0x90, 0x58, 0x7F], [0x91, 0x5C, 0x7F], [0x90, 0x54, 0x7F]]), [.sync(.a), .master(.b), .headphoneCue(.a)])
        XCTAssertEqual(
            events([[0x90, 0x36, 0x7F], [0xB0, 0x22, 0x41], [0xB0, 0x22, 0x3D], [0x90, 0x36, 0x00], [0xB1, 0x21, 0x42], [0xB1, 0x29, 0x3F]]),
            [.jogTouch(.a, down: true), .jogScratch(.a, ticks: 1), .jogScratch(.a, ticks: -3), .jogTouch(.a, down: false),
             .jogBend(.b, ticks: 2), .jogSearch(.b, ticks: -1)])
        XCTAssertEqual(
            events([[0x97, 0x00, 0x7F], [0x99, 0x07, 0x7F], [0x98, 0x02, 0x7F], [0x97, 0x62, 0x7F], [0x99, 0x20, 0x7F], [0x99, 0x25, 0x7F]]),
            [.hotCue(.a, 1), .hotCue(.b, 8), .clearHotCue(.a, 3), .beatLoop(.a, beats: 1), .jump(.b, beats: -1), .jump(.b, beats: 4)])
        XCTAssertEqual(
            events([[0x90, 0x10, 0x7F], [0x90, 0x10, 0x00], [0x90, 0x11, 0x7F], [0x91, 0x4D, 0x7F], [0x91, 0x51, 0x7F], [0x91, 0x53, 0x7F]]),
            [.loopIn(.a, down: true), .loopIn(.a, down: false), .loopOut(.a), .reloop(.b), .loopHalve(.b), .loopDouble(.b)])
        XCTAssertEqual(
            events([[0xB6, 0x40, 0x01], [0xB6, 0x40, 0x7E], [0x96, 0x41, 0x7F], [0x96, 0x46, 0x7F], [0x96, 0x47, 0x7F]]),
            [.browse(1), .browse(-2), .browsePush, .load(.a), .load(.b)])
    }

    func testFadersAndKnobsArriveAsTwoHalves() {
        // Coarse then fine; nothing is reported until both are in.
        XCTAssertEqual(events([[0xB0, 0x13, 0x7F]]), [])
        XCTAssertEqual(events([[0xB0, 0x13, 0x7F], [0xB0, 0x33, 0x7F]]), [.fader(.a, 1)])
        XCTAssertEqual(events([[0xB1, 0x13, 0x00], [0xB1, 0x33, 0x00]]), [.fader(.b, 0)])
        guard case .tempo(.a, let middle)? = events([[0xB0, 0x00, 0x40], [0xB0, 0x20, 0x00]]).first else { return XCTFail("no tempo event") }
        XCTAssertEqual(middle, 0.5, accuracy: 0.0001)
        guard case .crossfader(let left)? = events([[0xB6, 0x1F, 0x00], [0xB6, 0x3F, 0x10]]).first else { return XCTFail("no crossfader event") }
        XCTAssertEqual(left, 16.0 / 16383, accuracy: 0.00001)
        XCTAssertEqual(
            events([[0xB1, 0x0F, 0x7F], [0xB1, 0x2F, 0x7F], [0xB6, 0x18, 0x00], [0xB6, 0x38, 0x00], [0xB6, 0x0C, 0x7F], [0xB6, 0x2C, 0x7F]]),
            [.eq(.b, band: 0, 1), .filter(.b, 0), .headphoneMix(1)])
        XCTAssertEqual(events([[0xB0, 0x33, 0x20]]), [], "a fine half with no coarse half before it says nothing")
    }

    func testLights() {
        XCTAssertEqual(DDJFLX4.message(for: .play(.a), on: true), [0x90, 0x0B, 0x7F])
        XCTAssertEqual(DDJFLX4.message(for: .headphoneCue(.b), on: false), [0x91, 0x54, 0x00])
        XCTAssertEqual(DDJFLX4.message(for: .hotCue(.b, 3), on: true), [0x99, 0x02, 0x7F])
        XCTAssertEqual(DDJFLX4.message(for: .loaded(.b), on: true), [0x9F, 0x01, 0x7F])
        XCTAssertEqual(DDJFLX4.meter(.b, level: 0.5), [0xB1, 0x02, 64])
        XCTAssertTrue(DDJFLX4.isThisController("DDJ-FLX4"))
        XCTAssertFalse(DDJFLX4.isThisController("IAC Driver Bus 1"))
    }
}
