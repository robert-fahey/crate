import Foundation

/// How one track of a crate goes into the next: a transition worked out ahead of time and kept
/// with the crate, so the mix can be played back the same way and changed by hand.
public struct MixStep: Equatable, Sendable, Identifiable {
    /// Who last set it.
    public enum Author: String, Sendable {
        /// Crate's own suggestion from the two tracks' shapes.
        case crate
        case agent
        /// Set or changed by hand in the mix editor.
        case you
    }

    /// The outgoing and incoming tracks.
    public var from: Int64
    public var to: Int64
    public var style: Transition.Style
    /// How long the two overlap, for the styles that overlap.
    public var beats: Double
    /// Where in the outgoing track the mix starts, in seconds.
    public var outAt: Double
    /// Where in the incoming track it comes in from, in seconds.
    public var inAt: Double
    /// Why, in a few words: "bass swap over the outro", "cut on the breakdown".
    public var note: String
    public var author: Author

    public var id: String { "\(from)>\(to)" }

    public init(
        from: Int64, to: Int64, style: Transition.Style = .bassSwap, beats: Double = 32, outAt: Double, inAt: Double, note: String = "",
        author: Author = .you
    ) {
        self.from = from
        self.to = to
        self.style = style
        self.beats = max(1, beats)
        self.outAt = max(0, outAt)
        self.inAt = max(0, inAt)
        self.note = note
        self.author = author
    }

    /// The same transition as a request to the decks, once `from` is playing.
    public var request: MixRequest {
        var request = MixRequest(trackID: to)
        request.style = style
        request.beats = beats
        request.start = .time(outAt)
        request.incomingSeconds = inAt
        return request
    }
}

/// One side of a transition, as far as planning it goes.
public struct MixSide: Sendable {
    public var track: Track
    public var grid: BeatGrid?
    public var structure: TrackStructure?

    public init(track: Track, grid: BeatGrid? = nil, detail: WaveDetail? = nil) {
        self.track = track
        self.grid = grid
        if let grid, let detail { structure = TrackStructure.analyse(detail: detail, grid: grid, duration: track.duration) }
    }

    /// A track as the library has it.
    public init(track: Track, store: LibraryStore) {
        self.init(track: track, grid: try? store.beatGrid(id: track.id), detail: try? store.waveDetail(id: track.id))
    }

    var bpm: Double? { grid?.bpm ?? track.bpm }
}

/// Crate's own way of joining two tracks, used where nobody has said otherwise.
public enum MixPlanner {
    /// The lengths a mix can be, in beats.
    public static let lengths: [Double] = [8, 16, 32, 64]
    /// Tempos further apart than this are not blended: one track would have to be pulled too far.
    public static let widestBlend = 0.08

    /// How far apart two tempos are, allowing for one having been read at half or double speed.
    public static func tempoGap(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else { return 1 }
        return [b, b * 2, b / 2].map { abs($0 / a - 1) }.min() ?? 1
    }

    public static func suggest(from: MixSide, to: MixSide) -> MixStep {
        let length = from.track.duration
        // Leave where the outgoing track thins out; failing that, 48 beats from its end.
        var outAt = from.structure?.mixOut?.time
        if outAt == nil, let grid = from.grid {
            outAt = grid.time(atBeat: grid.boundary(atOrAfter: max(0, length - 48 * 60 / max(60, grid.bpm)), every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat))
        }
        // Come in from the first phrase with sound; failing that, the first bar line.
        var inAt = to.structure?.mixIn?.time
        if inAt == nil, let grid = to.grid {
            inAt = max(0, grid.time(atBeat: grid.boundary(atOrAfter: 0, every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)))
        }

        var step = MixStep(from: from.track.id, to: to.track.id, outAt: outAt ?? max(0, length - 20), inAt: inAt ?? 0, author: .crate)
        guard let outGrid = from.grid, to.grid != nil else {
            step.style = .cut
            step.note = "No beat grid on one of these, so a cut"
            return step
        }
        if let a = from.bpm, let b = to.bpm, tempoGap(a, b) > widestBlend {
            step.style = .echoOut
            step.note = String(format: "Tempos are %.0f%% apart, so the first track echoes out", tempoGap(a, b) * 100)
            return step
        }
        // As long a blend as the outgoing track has left, up to 32 beats.
        let room = outGrid.beatPosition(at: length) - 1 - outGrid.beatPosition(at: step.outAt)
        step.beats = lengths.last { $0 <= min(32, room) } ?? 8
        step.style = .bassSwap
        step.note = from.structure?.mixOut.map { $0.label.hasPrefix("outro") ? "Bass swap over the outro" : "Bass swap" } ?? "Bass swap"
        return step
    }

    /// A step with its times put on bar lines and its length made to fit, where the tracks have grids.
    public static func tidied(_ step: MixStep, from: MixSide, to: MixSide) -> MixStep {
        var step = step
        step.outAt = min(step.outAt, max(0, from.track.duration - 1))
        step.inAt = min(step.inAt, max(0, to.track.duration - 1))
        if let grid = from.grid {
            let bar = (grid.beatPosition(at: step.outAt) - Double(grid.downbeat)) / Double(BeatGrid.beatsPerBar)
            step.outAt = max(0, grid.time(atBeat: Double(grid.downbeat) + bar.rounded() * Double(BeatGrid.beatsPerBar)))
            if step.style.overlaps {
                let room = grid.beatPosition(at: from.track.duration) - 1 - grid.beatPosition(at: step.outAt)
                if step.beats > room { step.beats = lengths.last { $0 <= room } ?? max(4, (room / 4).rounded(.down) * 4) }
            }
        }
        if let grid = to.grid {
            let bar = (grid.beatPosition(at: step.inAt) - Double(grid.downbeat)) / Double(BeatGrid.beatsPerBar)
            step.inAt = max(0, grid.time(atBeat: Double(grid.downbeat) + bar.rounded() * Double(BeatGrid.beatsPerBar)))
        }
        return step
    }

    /// How long a crate lasts played as a mix: each track from where it comes in to where it is left.
    public static func length(of tracks: [Track], steps: [MixStep]) -> Double {
        var total = 0.0
        for (index, track) in tracks.enumerated() {
            let cameIn = index > 0 ? steps.first { $0.from == tracks[index - 1].id && $0.to == track.id }?.inAt ?? 0 : 0
            let left = index + 1 < tracks.count ? steps.first { $0.from == track.id && $0.to == tracks[index + 1].id }?.outAt ?? track.duration : track.duration
            total += max(0, left - cameIn)
        }
        return total
    }
}

extension LibraryStore {
    /// The transitions kept for a crate, whichever tracks they join.
    public func mixSteps(crate id: Int64) throws -> [MixStep] {
        try db.query(
            "SELECT from_track, to_track, style, beats, out_at, in_at, note, author FROM mix_steps WHERE crate_id = ?", [.int(id)]
        ).compactMap { row in
            guard let from = row.int("from_track"), let to = row.int("to_track") else { return nil }
            return MixStep(
                from: from, to: to, style: Transition.Style(rawValue: row.string("style") ?? "") ?? .bassSwap, beats: row.double("beats") ?? 32,
                outAt: row.double("out_at") ?? 0, inAt: row.double("in_at") ?? 0, note: row.string("note") ?? "",
                author: MixStep.Author(rawValue: row.string("author") ?? "") ?? .you)
        }
    }

    public func mixStep(crate id: Int64, from: Int64, to: Int64) throws -> MixStep? {
        try mixSteps(crate: id).first { $0.from == from && $0.to == to }
    }

    public func setMixSteps(crate id: Int64, _ steps: [MixStep]) throws {
        try db.transaction {
            for step in steps {
                try db.execute(
                    """
                    INSERT OR REPLACE INTO mix_steps (crate_id, from_track, to_track, style, beats, out_at, in_at, note, author)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(id), .int(step.from), .int(step.to), .text(step.style.rawValue), .double(step.beats), .double(step.outAt),
                        .double(step.inAt), .text(step.note), .text(step.author.rawValue),
                    ])
            }
        }
        changed()
    }

    /// Forgets transitions: the pairs given, or every one the crate has.
    public func removeMixSteps(crate id: Int64, pairs: [(from: Int64, to: Int64)]? = nil) throws {
        if let pairs {
            for pair in pairs {
                try db.execute("DELETE FROM mix_steps WHERE crate_id = ? AND from_track = ? AND to_track = ?", [.int(id), .int(pair.from), .int(pair.to)])
            }
        } else {
            try db.execute("DELETE FROM mix_steps WHERE crate_id = ?", [.int(id)])
        }
        changed()
    }

    /// A crate's tracks in order.
    public func tracks(inCrate id: Int64) throws -> [Track] {
        var query = TrackQuery()
        query.crateID = id
        return try tracks(query)
    }
}
