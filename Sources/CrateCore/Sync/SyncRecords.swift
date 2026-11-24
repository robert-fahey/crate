import Foundation

// What two Macs say to each other to bring their libraries into line.
//
// Each sends a *manifest*: every shared thing it has, with a note of when it last
// changed. Each looks at the other's manifest and asks for the full *records* of
// whatever the other has newer. Nothing is pushed; both sides pull. A side that
// changes sends its manifest again.

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A track as it appears in a manifest: who it is and how fresh each part of it is.
public struct TrackStamp: Codable, Equatable, Sendable {
    public var key: String
    public var detailsAt: Double
    public var cuesAt: Double
    /// When a hand last had a say in the beat grid; 0 if never.
    public var gridEditAt: Double
    /// The beat tracker that made the grid; 0 when there is no grid.
    public var gridVersion: Int
    /// How far the BPM and key can be trusted (see `ValueSource.rank`); -1 when there is none.
    public var bpmRank: Int
    public var keyRank: Int
    /// Waveforms are there to be copied.
    public var analysed: Bool
}

public struct CrateStamp: Codable, Equatable, Sendable {
    public var uid: String
    /// Changes with every edit.
    public var rev: String
    public var changedAt: Double
}

/// Whether a track or crate that was once removed is gone or back, and since when.
public struct Life: Codable, Equatable, Sendable {
    public var kind: String
    public var key: String
    public var at: Double
    public var alive: Bool
}

public struct SyncManifest: Codable, Equatable, Sendable {
    public var device: DeviceInfo
    public var tracks: [TrackStamp]
    public var crates: [CrateStamp]
    public var lives: [Life]
    /// The tracks whose files this Mac can hand over right now.
    public var holdings: [String]
}

public struct GridRecord: Codable, Equatable, Sendable {
    public var beats: Data
    public var markers: Data
    public var downbeat: Int
    public var phrase: Int
    public var steady: Bool
    public var edited: Bool
    public var version: Int
    public var editAt: Double
}

public struct TrackRecord: Codable, Equatable, Sendable {
    public var key: String
    public var source: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var format: String
    public var size: Int64
    public var addedAt: Double
    public var notes: String
    public var bpm: Double?
    public var bpmSource: String?
    public var musicalKey: String?
    public var keySource: String?
    public var detailsAt: Double
    /// Slot number (as text, for JSON) to seconds.
    public var cues: [String: Double]
    public var cuesAt: Double
    public var grid: GridRecord?
    /// What the file is called on the Mac that sent this, to name a copy of it by.
    public var fileName: String?
}

public struct CrateRecord: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var rev: String
    public var changedAt: Double
    /// The Mac the crate was made on, and the one that last changed it.
    public var origin: String
    public var editor: String
    /// Track keys, in order.
    public var tracks: [String]
}

/// A track's waveforms, so a Mac that receives the track need not analyse it again.
public struct AnalysisRecord: Codable, Equatable, Sendable {
    public var key: String
    public var waveform: Data?
    public var detailRate: Double?
    public var detailBands: Data?
}

/// What one Mac asks another for after reading its manifest.
public struct SyncWants: Codable, Equatable, Sendable {
    public var tracks: [String] = []
    public var crates: [String] = []
    public var analysis: [String] = []

    public init() {}
    public var isEmpty: Bool { tracks.isEmpty && crates.isEmpty && analysis.isEmpty }
}

/// The rules for which side wins. Pure, so they can be read and tested on their own.
public enum SyncRules {
    /// What to do about a crate both Macs have.
    public enum CrateVerdict: Equatable, Sendable {
        /// Both have the same version.
        case same
        /// Only this Mac has changed it: nothing to fetch; the other Mac will take ours.
        case keepOurs
        /// Only the other Mac has changed it.
        case takeTheirs
        /// Both have changed it since they last agreed: both versions are kept.
        case keepBoth(theirsWins: Bool)
    }

    /// - Parameter agreed: the version the two Macs last had in common, if they ever did.
    public static func crate(ours: CrateStamp, theirs: CrateStamp, agreed: String?) -> CrateVerdict {
        if ours.rev == theirs.rev { return .same }
        if let agreed {
            if theirs.rev == agreed { return .keepOurs }
            if ours.rev == agreed { return .takeTheirs }
        }
        // The later change keeps the name; a dead heat is settled the same way on both Macs.
        let theirsWins = theirs.changedAt != ours.changedAt ? theirs.changedAt > ours.changedAt : theirs.rev > ours.rev
        return .keepBoth(theirsWins: theirsWins)
    }

    /// Whether a beat grid from another Mac replaces the one here.
    public static func gridWins(theirEditAt: Double, theirVersion: Int, ourEditAt: Double?, ourVersion: Int?) -> Bool {
        guard theirVersion > 0 else { return false }
        guard let ourEditAt, let ourVersion, ourVersion > 0 else { return true }
        // A hand's later say wins. With no difference there, the better tracker's grid does.
        if theirEditAt != ourEditAt { return theirEditAt > ourEditAt }
        return theirVersion > ourVersion
    }

    /// The identity and name of the copy kept when a crate was changed on two Macs.
    public static func copy(of losing: CrateRecord) -> (uid: String, name: String) {
        let by = losing.editor.isEmpty ? losing.origin : losing.editor
        return ("\(losing.uid)~\(losing.rev.prefix(8))", by.isEmpty ? "\(losing.name) (copy)" : "\(losing.name) (\(by))")
    }
}
