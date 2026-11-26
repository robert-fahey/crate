import XCTest
@testable import CrateCore

final class MeterTests: XCTestCase {
    func testFullScaleLightsEverythingButTheRed() {
        XCTAssertEqual(MeterScale.count, 20)
        XCTAssertEqual(MeterScale.thresholds, MeterScale.thresholds.sorted(), "the lights are in order")
        XCTAssertEqual(MeterScale.lights(for: 0), 0)
        XCTAssertEqual(MeterScale.lights(for: 0.003), 0, "under the bottom light")
        XCTAssertEqual(MeterScale.lights(for: 0.0041), 1)
        XCTAssertEqual(MeterScale.lights(for: 0.51), MeterScale.firstAmber + 1, "-6 dB is the first amber light")
        XCTAssertEqual(MeterScale.lights(for: 1), MeterScale.firstRed, "full scale: all the green and amber, no red")
        // An MP3 of a loud master decodes a little over full scale; that is not worth a red light.
        XCTAssertEqual(MeterScale.lights(for: 1.08), MeterScale.firstRed)
        XCTAssertEqual(MeterScale.lights(for: 1.13), MeterScale.firstRed + 1)
        XCTAssertEqual(MeterScale.lights(for: 4), MeterScale.count)
    }

    func testTheLevelFallsByTheClockHoweverUnevenlyItIsRead() {
        var even = MeterBallistics(), uneven = MeterBallistics()
        even.feed(1, after: 0.05)
        uneven.feed(1, after: 0.05)
        XCTAssertEqual(even.level, 1, "a peak shows at once")
        for _ in 0..<20 { even.feed(0, after: 0.05) }
        // The same second, read late, early, and in a lump as when the window is busy.
        for step in [0.02, 0.11, 0.05, 0.4, 0.07, 0.3, 0.05] { uneven.feed(0, after: step) }
        let expected = Float(pow(10, -MeterBallistics.fall / 20))
        XCTAssertEqual(even.level, expected, accuracy: 0.002, "12 dB down after a second")
        XCTAssertEqual(uneven.level, expected, accuracy: 0.002)
        XCTAssertEqual(even.lights.lit, uneven.lights.lit)
    }

    func testSteadySoundGivesASteadyMeter() {
        // The same level at every reading, read unevenly: not one light moves, at any level.
        for level in stride(from: Float(0.01), through: 1.4, by: 0.013) {
            var meter = MeterBallistics()
            var seen: Set<MeterLights> = []
            for reading in 0..<100 {
                meter.feed(level, after: reading % 3 == 0 ? 0.13 : 0.04)
                seen.insert(meter.lights)
            }
            XCTAssertEqual(seen.count, 1, "level \(level)")
            XCTAssertEqual(seen.first?.lit, MeterScale.lights(for: level))
            XCTAssertEqual(seen.first?.held, 0)
        }
    }

    func testTheLoudestPeakStaysLitThenFalls() {
        var meter = MeterBallistics()
        meter.feed(0.9, after: 0.05)
        XCTAssertEqual(meter.lights.held, 0, "nothing is held above the level itself")
        for _ in 0..<20 { meter.feed(0.05, after: 0.05) }
        XCTAssertEqual(meter.held, 0.9, "still held after a second")
        XCTAssertEqual(meter.lights.held, MeterScale.lights(for: 0.9))
        XCTAssertLessThan(meter.lights.lit, meter.lights.held)
        for _ in 0..<40 { meter.feed(0.05, after: 0.05) }
        XCTAssertEqual(meter.held, meter.level, accuracy: 0.001, "after its time the held peak comes down to the level")
        XCTAssertEqual(meter.lights.held, 0)
        meter.feed(0.95, after: 0.05)
        XCTAssertEqual(meter.held, 0.95, "a louder peak takes over at once")
    }

    func testOverStaysOnForAMomentAndTheMeterComesToRest() {
        var meter = MeterBallistics()
        meter.feed(1.05, after: 0.05)
        XCTAssertFalse(meter.isOver, "a hair over full scale is not over")
        meter.feed(1.3, after: 0.05)
        XCTAssertTrue(meter.isOver)
        XCTAssertTrue(meter.lights.isOver)
        for _ in 0..<20 { meter.feed(0.5, after: 0.05) }
        XCTAssertTrue(meter.isOver, "still on a second later")
        for _ in 0..<15 { meter.feed(0.5, after: 0.05) }
        XCTAssertFalse(meter.isOver)
        XCTAssertFalse(meter.isAtRest)
        for _ in 0..<200 { meter.feed(0, after: 0.05) }
        XCTAssertTrue(meter.isAtRest)
        XCTAssertEqual(meter.lights, MeterLights())
        meter.feed(.nan, after: 0.05)
        XCTAssertEqual(meter.level, 0, "nonsense in is silence, not a stuck meter")
    }

    func testAChannelsLevelIsBeforeItsFaderAndMissesNothing() throws {
        let engine = try DeckEngine(offline: true)
        let deck = engine.deck(.a)
        // Quiet, except for one loud tenth of a second in the middle.
        var samples = Probe.sine(500, seconds: 5, amplitude: 0.1)
        let loud = Probe.sine(500, seconds: 0.1, amplitude: 0.8)
        samples.replaceSubrange(Int(2 * Probe.rate)..<Int(2 * Probe.rate) + loud.count, with: loud)
        deck.load(TrackAudio(left: samples, sampleRate: Probe.rate))
        deck.play()
        var settings = engine.settings
        settings.fader[0] = 0.25
        engine.settings = settings
        // The start is a jolt to the EQ's filters and really is louder for a moment; measure after it.
        _ = try engine.render(seconds: 0.5)
        _ = deck.takeLevel()
        _ = try engine.render(seconds: 0.5)
        XCTAssertEqual(deck.takeLevel(), 0.1, accuracy: 0.005, "the fader does not come into it")
        XCTAssertEqual(deck.takeLevel(), 0, "reading starts the next measurement")
        // The loud part went by many renders ago; it is still what was loudest since the last reading.
        _ = try engine.render(seconds: 2)
        XCTAssertGreaterThan(deck.takeLevel(), 0.75)
        XCTAssertEqual(deck.state().peak, 0.025, accuracy: 0.005, "the last render alone, after the fader, knows nothing of it")
        settings.trim[0] = 2
        engine.settings = settings
        _ = try engine.render(seconds: 0.5)
        _ = deck.takeLevel()
        _ = try engine.render(seconds: 0.5)
        XCTAssertEqual(deck.takeLevel(), 0.2, accuracy: 0.01, "trim does")
        deck.pause()
        _ = try engine.render(seconds: 0.5)
        _ = deck.takeLevel()
        _ = try engine.render(seconds: 0.5)
        XCTAssertEqual(deck.takeLevel(), 0, accuracy: 1e-6, "a stopped deck is silent")
    }

    func testAVolumeTurnedDownBeforePlayingIsDownFromTheFirstSample() throws {
        // Set while nothing has been rendered yet, as before the first track is loaded, and played at once.
        let engine = try DeckEngine(offline: true)
        var settings = engine.settings
        settings.master = 0
        engine.settings = settings
        let deck = engine.deck(.a)
        deck.load(TrackAudio(left: Probe.sine(440, seconds: 3, amplitude: 0.8), sampleRate: Probe.rate))
        deck.play()
        let first = try engine.render(seconds: 0.5)
        XCTAssertEqual(first.left.map(abs).max() ?? 9, 0, accuracy: 1e-6, "not one sample gets out on the way down")

        // Stopped, turned up, and played: at the new level from the first sample too.
        deck.pause()
        _ = try engine.render(seconds: 0.2)
        settings.master = 0.5
        engine.settings = settings
        deck.play()
        let second = try engine.render(seconds: 0.5)
        XCTAssertEqual(Probe.rms(second.left[4410...]), Float(0.4 / 2.0.squareRoot()), accuracy: 0.01)

        // While it plays a change still glides: no step in the sound bigger than the tone's own.
        settings.master = 1
        engine.settings = settings
        let third = try engine.render(seconds: 0.2).left
        let steps = zip(third, third.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(steps.max() ?? 9, 0.06, "the tone itself moves 0.05 a sample at full level")
    }

    func testTheMasterIsMeasuredLeftAndRightBeforeTheLimiter() throws {
        let engine = try DeckEngine(offline: true)
        let a = engine.deck(.a), b = engine.deck(.b)
        let tone = Probe.sine(440, seconds: 8, amplitude: 0.75)
        // Deck A on both sides, deck B on the right only: the right is over full scale, the left is not.
        a.load(TrackAudio(left: tone, sampleRate: Probe.rate))
        b.load(TrackAudio(left: [Float](repeating: 0, count: tone.count), right: tone, sampleRate: Probe.rate))
        a.play()
        b.play()
        // The mix is handed over for measuring on another thread, a moment after it is rendered.
        func settle() { Thread.sleep(forTimeInterval: 0.15) }
        _ = try engine.render(seconds: 1)
        settle()
        _ = engine.takeMasterPeaks()
        let played = try engine.render(seconds: 1)
        settle()
        let peaks = engine.takeMasterPeaks()
        XCTAssertEqual(peaks.left, 0.75, accuracy: 0.02)
        XCTAssertEqual(peaks.right, 1.5, accuracy: 0.04, "the two decks together, as they went into the limiter")
        XCTAssertLessThan(played.right.map(abs).max() ?? 9, 1.01, "what came out of it is held to full scale")
        let again = engine.takeMasterPeaks()
        XCTAssertEqual(again.left, peaks.left, accuracy: 0.02, "asked again before more has come: the latest again, not silence")

        // Fed to the meter as the mixer does it, twenty times a second: steady, and over on the right only.
        var left = MeterBallistics(), right = MeterBallistics()
        var seen: Set<Int> = []
        for _ in 0..<60 {
            _ = try engine.render(seconds: 0.05)
            let peaks = engine.takeMasterPeaks()
            left.feed(peaks.left, after: 0.05)
            right.feed(peaks.right, after: 0.05)
            seen.insert(left.lights.lit)
            seen.insert(right.lights.lit + 100)
        }
        XCTAssertEqual(seen, [MeterScale.lights(for: 0.75), MeterScale.lights(for: 1.5) + 100], "a steady tone holds every light still")
        XCTAssertFalse(left.isOver)
        XCTAssertTrue(right.isOver)

        // With no more of the mix coming, it is silence.
        settle()
        _ = engine.takeMasterPeaks()
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(engine.takeMasterPeak(), 0)
    }
}
