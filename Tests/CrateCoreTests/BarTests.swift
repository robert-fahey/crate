import XCTest
@testable import CrateCore

/// Made-up records with a known first beat of the bar.
private struct Record {
    static let rate = 11025.0
    static let bpm = 120.0
    static let period = 60 / bpm

    var samples: [Float]
    var grid: BeatGrid

    /// - Parameters:
    ///   - start: the grid beat the music starts on; the beats before it are silence.
    ///   - one: the grid beat that is a beat 1; every fourth beat from it is too.
    ///   - kickOn: beats of the bar with a kick, 1...4.
    ///   - snareOn: beats of the bar with a snare.
    ///   - bassFromBar: the bar of music the bass comes in on, and every `sectionBars` it drops out or comes back.
    init(start: Int, one: Int? = nil, kickOn: Set<Int> = [1, 3], snareOn: Set<Int> = [2, 4], bars: Int = 48, sectionBars: Int? = nil, drums: Bool = true) {
        let one = one ?? start
        let beats = start + bars * 4 + 8
        let seconds = 0.25 + Double(beats) * Self.period
        var samples = [Float](repeating: 0, count: Int(seconds * Self.rate))
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        }
        func add(at time: Double, length: Double, _ value: (Double) -> Float) {
            let from = Int((time * Self.rate).rounded())
            for offset in 0..<Int(length * Self.rate) where from + offset >= 0 && from + offset < samples.count {
                samples[from + offset] += value(Double(offset) / Self.rate)
            }
        }
        for beat in start..<(start + bars * 4) {
            let time = 0.25 + Double(beat) * Self.period
            let inBar = ((beat - one) % 4 + 4) % 4 + 1
            let bar = (beat - one) >= 0 ? (beat - one) / 4 : -1
            if drums {
                if kickOn.contains(inBar) {
                    add(at: time, length: 0.15) { t in Float(sin(2 * .pi * 60 * t) * exp(-t * 25)) * 0.7 + noise() * Float(exp(-t * 900)) * 0.3 }
                }
                if snareOn.contains(inBar) {
                    add(at: time, length: 0.12) { t in noise() * Float(exp(-t * 30)) * 0.5 + Float(sin(2 * .pi * 190 * t) * exp(-t * 40)) * 0.2 }
                }
                // A hat on every beat and between: the same for all four, so it says nothing.
                for step in 0..<2 {
                    add(at: time + Double(step) * Self.period / 2, length: 0.02) { t in noise() * Float(exp(-t * 300)) * 0.12 }
                }
            }
            // A held note, so there is something there when the drums are not.
            let sounding = sectionBars.map { bar >= 0 && (bar / $0) % 2 == 1 } ?? true
            add(at: time, length: Self.period) { t in Float(sin(2 * .pi * 220 * t)) * (sounding ? 0.25 : 0.03) }
            if sectionBars != nil, sounding {
                add(at: time, length: Self.period) { t in Float(sin(2 * .pi * 82 * t)) * 0.3 }
            }
        }
        self.samples = samples
        grid = BeatGrid(bpm: Self.bpm, firstBeat: 0.25, duration: seconds)
    }

    var found: (downbeat: Int, phrase: Int) { BarFinder.find(grid: grid, samples: samples, sampleRate: Self.rate) }
}

final class BarFinderTests: XCTestCase {
    func testABarStartsOnTheKickNotTheSnare() {
        // Kick on 1 and 3, snare on 2 and 4, wherever in the grid the music happens to start.
        for start in 0..<8 {
            XCTAssertEqual(Record(start: start).found.downbeat, start % 4, "music starting on grid beat \(start)")
        }
    }

    func testFourOnTheFloorGoesByTheClap() {
        for start in [0, 1, 2, 3, 6] {
            let record = Record(start: start, kickOn: [1, 2, 3, 4], snareOn: [2, 4])
            XCTAssertEqual(record.found.downbeat, start % 4, "music starting on grid beat \(start)")
        }
    }

    func testTheBackbeatIsReadBarByBar() {
        let record = Record(start: 1)
        let measures = BarFinder.measures(beats: record.grid.beats, samples: record.samples, sampleRate: Record.rate)
        XCTAssertGreaterThan(BarFinder.backbeat(measures, from: 1), 0.2, "counted from the kick")
        XCTAssertEqual(BarFinder.backbeat(measures, from: 3), BarFinder.backbeat(measures, from: 1), accuracy: 0.05, "beat 3 is as good as beat 1 for this")
        XCTAssertLessThan(BarFinder.backbeat(measures, from: 0), -0.2, "counted from the snare")
        XCTAssertLessThan(BarFinder.backbeat(measures, from: 2), -0.2)
    }

    func testAPickUpDoesNotMoveTheBarWhenTheSectionsSayOtherwise() {
        // The music comes in two beats early, on beat 3, but its sections change on beat 1.
        let record = Record(start: 2, one: 4, sectionBars: 8)
        let measures = BarFinder.measures(beats: record.grid.beats, samples: record.samples, sampleRate: Record.rate)
        XCTAssertEqual(BarFinder.firstLoudBeat(measures), 2)
        let boundaries = BarFinder.boundaries(measures)
        // The music stops two beats into a bar, as it started: that end is the one change not on a beat 1,
        // and the biggest of them all. It counts as one change among the others, not as ten.
        let onOne = boundaries.filter { $0.beat % 4 == 0 }
        XCTAssertGreaterThanOrEqual(onOne.count, 5, "\(boundaries.map(\.beat))")
        XCTAssertLessThanOrEqual(boundaries.count - onOne.count, 1, "\(boundaries.map(\.beat))")
        XCTAssertLessThanOrEqual(boundaries.map(\.strength).max() ?? 9, BarFinder.strongestBoundary)
        XCTAssertEqual(record.found.downbeat, 0)
    }

    func testPhrasesStartWhereTheSectionsChange() {
        // Sections of eight bars from grid beat 5.
        let found = Record(start: 5, sectionBars: 8).found
        XCTAssertEqual(found.downbeat, 1)
        XCTAssertEqual(found.phrase, 5)
    }

    func testWithNoDrumsTheStartOfTheMusicDecides() {
        let record = Record(start: 3, drums: false)
        let measures = BarFinder.measures(beats: record.grid.beats, samples: record.samples, sampleRate: Record.rate)
        XCTAssertEqual(BarFinder.backbeat(measures, from: 0), 0, accuracy: 0.03, "no backbeat to go by")
        XCTAssertEqual(record.found.downbeat, 3)
    }

    func testTooLittleMusicOrNoneGivesTheFirstBeat() {
        let short = Record(start: 1, bars: 6)
        XCTAssertLessThanOrEqual(short.grid.count, 40)
        XCTAssertEqual(short.found.downbeat, 0, "under ten bars is too little to go on")
        let silence = [Float](repeating: 0, count: Int(60 * Record.rate))
        let found = BarFinder.find(grid: BeatGrid(bpm: 120, firstBeat: 0.25, duration: 60), samples: silence, sampleRate: Record.rate)
        XCTAssertEqual(found.downbeat, 0)
        XCTAssertEqual(found.phrase, 0)
    }

    func testTheWholeAnalysisPutsBeatOneOnTheKick() throws {
        // Through the beat tracker, as the app does it: the tracker carries the grid back to the start
        // of the file, so the music's first beat is wherever that count happens to leave it.
        let record = Record(start: 5, kickOn: [1, 2, 3, 4], snareOn: [2, 4])
        let grid = try XCTUnwrap(BeatTracker.track(samples: record.samples, sampleRate: Record.rate, bpm: Record.bpm))
        let first = 0.25 + 5 * Record.period
        let index = Int(grid.beatPosition(at: first).rounded())
        XCTAssertEqual(grid.time(atBeat: Double(index)), first, accuracy: 0.01, "a beat on the music's first kick")
        XCTAssertEqual(grid.beatInBar(index), 1, "and it is a beat 1")
        XCTAssertEqual(grid.beatInBar(index + 1), 2, "the clap is on 2")
    }
}
