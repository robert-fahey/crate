import Foundation

public enum TrackSource: String, CaseIterable, Sendable {
    case local, spotify, tidal

    public var displayName: String {
        switch self {
        case .local: return "Local"
        case .spotify: return "Spotify"
        case .tidal: return "TIDAL"
        }
    }
}

/// Where a BPM or key value came from. Analysis never overwrites a tag or a
/// value the user typed.
public enum ValueSource: String, Sendable {
    case tag, estimated, manual, service

    /// Higher wins when two sources disagree.
    var rank: Int {
        switch self {
        case .estimated: return 0
        case .service: return 1
        case .tag: return 2
        case .manual: return 3
        }
    }
}

public struct Track: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var source: TrackSource
    /// Unique identity. Local: "file:<volume uuid or ->:<path>". Streaming: "spotify:track:…" / "tidal:track:…".
    public var uri: String
    /// Local only: absolute path when last seen.
    public var path: String?
    /// Local only: set for files on removable volumes, with the path relative to the volume root.
    public var volumeUUID: String?
    public var relativePath: String?
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var bpm: Double?
    public var bpmSource: ValueSource?
    public var key: String?
    public var keySource: ValueSource?
    public var format: String
    public var addedAt: Date
    public var notes: String
    public var analyzed: Bool
    /// What the track is on every Mac: a fingerprint of the file's content, or the streaming address.
    /// Nil until the file has been fingerprinted; such a track is not shared yet.
    public var contentID: String? = nil

    public var camelot: CamelotKey? { key.flatMap(CamelotKey.init(parsing:)) }
    /// False for a track known from another Mac whose file has not been copied here.
    public var isOnThisMac: Bool { source != .local || path != nil }
}

public struct Crate: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var trackCount: Int
    /// The crate's identity on every Mac.
    public var uid: String = ""
    /// Its tracks are copied to this Mac ahead of time. Each Mac decides for itself.
    public var keepHere: Bool = false
}

public struct LibraryFolder: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var path: String
    public var volumeUUID: String?
    public var relativePath: String?
}

public enum TrackSort: String, Sendable {
    case title, artist, album, bpm, key, duration, added

    var column: String {
        switch self {
        case .title: return "title COLLATE NOCASE"
        case .artist: return "artist COLLATE NOCASE"
        case .album: return "album COLLATE NOCASE"
        case .bpm: return "bpm"
        case .key: return "key_order"
        case .duration: return "duration"
        case .added: return "added_at"
        }
    }
}

public struct TrackQuery: Sendable {
    public var text: String?
    public var bpmMin: Double?
    public var bpmMax: Double?
    /// Camelot keys ("8A"). A track matches if its key is any of them.
    public var keys: [String] = []
    public var source: TrackSource?
    public var crateID: Int64?
    /// Only tracks missing an artist, BPM or key.
    public var needsTagging = false
    public var sort: TrackSort = .artist
    public var ascending = true
    public var limit: Int?

    public init() {}
}

/// Fields that can be edited on a track. `nil` leaves the field alone.
public struct TrackPatch: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var notes: String?
    /// `.some(nil)` clears the value.
    public var bpm: Double??
    public var key: String??

    public init() {}
}

public struct LibraryStats: Equatable, Sendable {
    public var tracks = 0
    public var local = 0
    public var spotify = 0
    public var tidal = 0
    public var crates = 0
    public var withBPM = 0
    public var withKey = 0
    public var needsTagging = 0
    public var totalDuration = 0.0

    public init() {}
}

/// What the scanner hands the store for one audio file.
public struct ScannedFile: Sendable {
    public var path: String
    public var volumeUUID: String?
    public var relativePath: String?
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var bpm: Double?
    public var key: String?
    public var format: String
    public var size: Int64
    public var modified: Double
    public var contentID: String?

    public init(
        path: String, volumeUUID: String? = nil, relativePath: String? = nil, title: String, artist: String = "",
        album: String = "", duration: Double, bpm: Double? = nil, key: String? = nil, format: String,
        size: Int64 = 0, modified: Double = 0, contentID: String? = nil
    ) {
        self.contentID = contentID
        self.path = path
        self.volumeUUID = volumeUUID
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.bpm = bpm
        self.key = key
        self.format = format
        self.size = size
        self.modified = modified
    }

    public var uri: String { ScannedFile.uri(path: path, volumeUUID: volumeUUID, relativePath: relativePath) }

    public static func uri(path: String, volumeUUID: String?, relativePath: String?) -> String {
        if let volumeUUID, let relativePath { return "file:\(volumeUUID):\(relativePath)" }
        return "file:-:\(path)"
    }
}

public extension Notification.Name {
    /// Posted (on any thread) after the library changes.
    static let libraryDidChange = Notification.Name("CrateLibraryDidChange")
}
