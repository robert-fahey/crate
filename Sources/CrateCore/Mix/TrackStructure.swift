import Foundation

/// A track's shape, phrase by phrase: enough for choosing where to mix in and out.
///
/// A phrase here is 32 beats (eight bars) from the grid's phrase anchor. Levels
/// are relative to the loudest phrase of the same track, 0...10.
public struct TrackStructure: Equatable, Sendable {
    public struct Phrase: Equatable, Sendable {
        public var index: Int
        public var startBeat: Double
        public var time: Double
        public var bar: Int
        public var energy: Int
        public var bass: Int
        public var mids: Int
        public var highs: Int
        public var label: String
    }

    public var phrases: [Phrase]
    public var bpm: Double
    public var duration: Double
    public var isSteady: Bool
    /// Where the track can be started from when mixing it in: the first phrase with sound.
    public var mixIn: Phrase?
    /// The latest phrase from which a 32-beat mix still finishes before the music runs out.
    public var mixOut: Phrase?

    public static func analyse(detail: WaveDetail, grid: BeatGrid, duration: Double) -> TrackStructure {
        let length = Double(BeatGrid.beatsPerPhrase)
        // Phrase boundaries that fall inside the track, starting from the first one at or after its start.
        var beat = grid.boundary(atOrAfter: 0, every: BeatGrid.beatsPerPhrase, anchoredAt: grid.phrase)
        var raw: [(beat: Double, time: Double, levels: (low: Float, mid: Float, high: Float))] = []
        while grid.time(atBeat: beat) < duration - 1 {
            let from = grid.time(atBeat: beat), to = min(duration, grid.time(atBeat: beat + length))
            let columns = Int(from * detail.columnsPerSecond)..<max(Int(from * detail.columnsPerSecond) + 1, Int(to * detail.columnsPerSecond))
            raw.append((beat, from, detail.mean(in: columns)))
            beat += length
        }
        let top = (
            low: raw.map(\.levels.low).max() ?? 0, mid: raw.map(\.levels.mid).max() ?? 0, high: raw.map(\.levels.high).max() ?? 0)
        func scaled(_ value: Float, _ most: Float) -> Int { most > 0 ? Int((value / most * 10).rounded()) : 0 }
        var phrases = raw.enumerated().map { index, item in
            let bass = scaled(item.levels.low, top.low), mids = scaled(item.levels.mid, top.mid), highs = scaled(item.levels.high, top.high)
            return Phrase(
                index: index, startBeat: item.beat, time: max(0, item.time),
                bar: Int(((item.beat - Double(grid.downbeat)) / Double(BeatGrid.beatsPerBar)).rounded()) + 1,
                energy: max(bass, mids, highs), bass: bass, mids: mids, highs: highs, label: "")
        }
        // Name the parts by where the bass is.
        let withBass = phrases.indices.filter { phrases[$0].bass >= 5 }
        for index in phrases.indices {
            if phrases[index].energy <= 1 {
                phrases[index].label = "silence"
            } else if let first = withBass.first, index < first {
                phrases[index].label = "intro, no bass"
            } else if let last = withBass.last, index > last {
                phrases[index].label = "outro, no bass"
            } else if phrases[index].bass < 4 {
                phrases[index].label = "breakdown"
            } else {
                phrases[index].label = "full"
            }
        }
        let sounding = phrases.filter { $0.energy >= 2 }
        let lastBeat = grid.beatPosition(at: sounding.last.map { min(duration, grid.time(atBeat: $0.startBeat + length)) } ?? duration)
        return TrackStructure(
            phrases: phrases, bpm: grid.bpm, duration: duration, isSteady: grid.isSteady,
            mixIn: sounding.first,
            mixOut: sounding.last { lastBeat - $0.startBeat >= 40 } ?? sounding.first)
    }

    public var json: JSON {
        func describe(_ phrase: Phrase) -> JSON {
            [
                "at": .string(TrackFormat.duration(phrase.time)), "seconds": .number((phrase.time * 10).rounded() / 10),
                "bar": .number(Double(phrase.bar)), "part": .string(phrase.label),
                "energy": .number(Double(phrase.energy)), "bass": .number(Double(phrase.bass)),
                "mids": .number(Double(phrase.mids)), "highs": .number(Double(phrase.highs)),
            ]
        }
        var result: [String: JSON] = [
            "bpm": .number((bpm * 10).rounded() / 10),
            "length": .string(TrackFormat.duration(duration)),
            "tempo": .string(isSteady ? "steady" : "played by a drummer, drifts a little"),
            "phrases_of_8_bars": .array(phrases.map(describe)),
            "note": "Levels are 0 to 10 against this track's loudest phrase. Bar and phrase positions are estimates.",
        ]
        if let mixIn { result["suggested_mix_in"] = describe(mixIn) }
        if let mixOut { result["suggested_mix_out"] = describe(mixOut) }
        return .object(result)
    }
}
