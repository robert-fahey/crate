import Foundation

/// The library database: tracks, crates, folders and settings.
public final class LibraryStore {
    public let db: SQLiteDB
    /// The time, for stamping changes. Tests set it to tell "earlier" from "later" without waiting.
    public var clock: () -> Double = { Date().timeIntervalSince1970 }

    /// - Parameter path: database file, or ":memory:" for tests.
    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try migrate()
    }

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("Crate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("library.sqlite")
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        if version < 1 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE tracks (
                        id INTEGER PRIMARY KEY,
                        source TEXT NOT NULL,
                        uri TEXT NOT NULL UNIQUE,
                        path TEXT,
                        volume_uuid TEXT,
                        rel_path TEXT,
                        title TEXT NOT NULL DEFAULT '',
                        artist TEXT NOT NULL DEFAULT '',
                        album TEXT NOT NULL DEFAULT '',
                        duration REAL NOT NULL DEFAULT 0,
                        bpm REAL,
                        bpm_source TEXT,
                        musical_key TEXT,
                        key_source TEXT,
                        key_order INTEGER,
                        format TEXT NOT NULL DEFAULT '',
                        size INTEGER NOT NULL DEFAULT 0,
                        mtime REAL NOT NULL DEFAULT 0,
                        added_at REAL NOT NULL,
                        notes TEXT NOT NULL DEFAULT '',
                        analyzed INTEGER NOT NULL DEFAULT 0,
                        waveform BLOB
                    )
                    """)
                try db.execute("CREATE INDEX tracks_bpm ON tracks(bpm)")
                try db.execute("CREATE INDEX tracks_key ON tracks(musical_key)")
                try db.execute("CREATE VIRTUAL TABLE tracks_fts USING fts5(title, artist, album, notes, filename)")
                try db.execute("""
                    CREATE TABLE crates (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                        created_at REAL NOT NULL
                    )
                    """)
                try db.execute("""
                    CREATE TABLE crate_tracks (
                        crate_id INTEGER NOT NULL REFERENCES crates(id) ON DELETE CASCADE,
                        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (crate_id, track_id)
                    )
                    """)
                try db.execute("""
                    CREATE TABLE folders (
                        id INTEGER PRIMARY KEY,
                        path TEXT NOT NULL UNIQUE,
                        volume_uuid TEXT,
                        rel_path TEXT
                    )
                    """)
                try db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try db.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            // The detailed, three-band waveform. Kept out of `tracks` so listing tracks stays light.
            try db.transaction {
                try db.execute("""
                    CREATE TABLE waveforms (
                        track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                        rate REAL NOT NULL,
                        bands BLOB NOT NULL
                    )
                    """)
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            // Beat grids and cue points, for the decks.
            try db.transaction {
                try db.execute("""
                    CREATE TABLE beatgrids (
                        track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                        beats BLOB NOT NULL,
                        downbeat INTEGER NOT NULL DEFAULT 0,
                        phrase INTEGER NOT NULL DEFAULT 0,
                        steady INTEGER NOT NULL DEFAULT 0,
                        edited INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try db.execute("""
                    CREATE TABLE cues (
                        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                        slot INTEGER NOT NULL,
                        position REAL NOT NULL,
                        PRIMARY KEY (track_id, slot)
                    )
                    """)
                try db.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            // Which beats of a grid are pinned markers.
            try db.transaction {
                try db.execute("ALTER TABLE beatgrids ADD COLUMN markers BLOB")
                try db.execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            // Which version of the beat tracker made each grid, so better tracking can redo the old ones.
            try db.transaction {
                try db.execute("ALTER TABLE beatgrids ADD COLUMN version INTEGER NOT NULL DEFAULT 1")
                try db.execute("PRAGMA user_version = 5")
            }
        }
        if version < 6 {
            // Sharing the library between Macs: an identity for each track and crate that holds
            // on every Mac, and a note of when each shared thing last changed.
            let now = Date().timeIntervalSince1970
            try db.transaction {
                try db.execute("ALTER TABLE tracks ADD COLUMN content_id TEXT")
                try db.execute("ALTER TABLE tracks ADD COLUMN details_at REAL NOT NULL DEFAULT 0")
                try db.execute("ALTER TABLE tracks ADD COLUMN cues_at REAL NOT NULL DEFAULT 0")
                try db.execute("CREATE INDEX tracks_content ON tracks(content_id)")
                try db.execute("UPDATE tracks SET content_id = uri WHERE source != 'local'")
                // What is here now is how its owner has it: it should win over a copy another Mac has only just scanned.
                try db.execute("UPDATE tracks SET details_at = ?", [.double(now)])
                try db.execute("UPDATE tracks SET cues_at = ? WHERE id IN (SELECT track_id FROM cues)", [.double(now)])
                try db.execute("ALTER TABLE beatgrids ADD COLUMN edit_at REAL NOT NULL DEFAULT 0")
                try db.execute("UPDATE beatgrids SET edit_at = ? WHERE edited = 1", [.double(now)])
                try db.execute("ALTER TABLE crates ADD COLUMN uid TEXT")
                try db.execute("ALTER TABLE crates ADD COLUMN rev TEXT")
                try db.execute("ALTER TABLE crates ADD COLUMN changed_at REAL NOT NULL DEFAULT 0")
                try db.execute("ALTER TABLE crates ADD COLUMN origin TEXT NOT NULL DEFAULT ''")
                try db.execute("ALTER TABLE crates ADD COLUMN editor TEXT NOT NULL DEFAULT ''")
                try db.execute("ALTER TABLE crates ADD COLUMN keep_here INTEGER NOT NULL DEFAULT 0")
                for row in try db.query("SELECT id, created_at FROM crates") {
                    try db.execute(
                        "UPDATE crates SET uid = ?, rev = ?, changed_at = ? WHERE id = ?",
                        [.text(UUID().uuidString), .text(UUID().uuidString), .double(row.double("created_at") ?? now), .int(row.int("id") ?? 0)])
                }
                // Removed tracks and deleted crates, remembered so that the removal reaches the other Macs
                // (and so that bringing one back later counts as the newer decision).
                try db.execute("""
                    CREATE TABLE lives (
                        kind TEXT NOT NULL, key TEXT NOT NULL, at REAL NOT NULL, alive INTEGER NOT NULL,
                        PRIMARY KEY (kind, key)
                    )
                    """)
                try db.execute("""
                    CREATE TABLE peers (
                        device_id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', address TEXT NOT NULL DEFAULT '',
                        last_seen REAL NOT NULL DEFAULT 0
                    )
                    """)
                // Which other Mac can hand over which file.
                try db.execute("""
                    CREATE TABLE peer_holdings (
                        device_id TEXT NOT NULL, content_id TEXT NOT NULL, PRIMARY KEY (device_id, content_id)
                    )
                    """)
                // The version of each crate that this Mac and each other Mac last agreed on: what tells
                // "changed on one Mac" from "changed on both".
                try db.execute("""
                    CREATE TABLE peer_crates (
                        device_id TEXT NOT NULL, crate_uid TEXT NOT NULL, rev TEXT NOT NULL,
                        PRIMARY KEY (device_id, crate_uid)
                    )
                    """)
                try db.execute("PRAGMA user_version = 6")
            }
        }
        if version < 7 {
            // Cue points with names, and cues that are saved loops.
            try db.transaction {
                try db.execute("ALTER TABLE cues ADD COLUMN name TEXT NOT NULL DEFAULT ''")
                try db.execute("ALTER TABLE cues ADD COLUMN loop_end REAL")
                try db.execute("PRAGMA user_version = 7")
            }
        }
        if version < 8 {
            // A crate's mix: how each track goes into the one after it.
            try db.transaction {
                try db.execute("""
                    CREATE TABLE mix_steps (
                        crate_id INTEGER NOT NULL REFERENCES crates(id) ON DELETE CASCADE,
                        from_track INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                        to_track INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                        style TEXT NOT NULL,
                        beats REAL NOT NULL,
                        out_at REAL NOT NULL,
                        in_at REAL NOT NULL,
                        note TEXT NOT NULL DEFAULT '',
                        author TEXT NOT NULL DEFAULT '',
                        PRIMARY KEY (crate_id, from_track, to_track)
                    )
                    """)
                try db.execute("PRAGMA user_version = 8")
            }
        }
    }

    func changed() {
        NotificationCenter.default.post(name: .libraryDidChange, object: self)
    }

    // MARK: - This Mac

    /// This Mac's identity among the user's Macs, made once.
    public var deviceID: String {
        if let id = setting("sync.device_id") { return id }
        let id = UUID().uuidString
        setSetting("sync.device_id", id)
        return id
    }

    /// The name other Macs show for this one.
    public var deviceName: String {
        get { setting("sync.device_name") ?? Host.current().localizedName ?? "Mac" }
        set { setSetting("sync.device_name", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: - Reading tracks

    private static let trackColumns = """
        id, source, uri, path, volume_uuid, rel_path, title, artist, album, duration, bpm, bpm_source,
        musical_key, key_source, format, added_at, notes, analyzed, content_id
        """

    private func track(from row: SQLRow) -> Track {
        Track(
            id: row.int("id") ?? 0,
            source: TrackSource(rawValue: row.string("source") ?? "") ?? .local,
            uri: row.string("uri") ?? "",
            path: row.string("path"),
            volumeUUID: row.string("volume_uuid"),
            relativePath: row.string("rel_path"),
            title: row.string("title") ?? "",
            artist: row.string("artist") ?? "",
            album: row.string("album") ?? "",
            duration: row.double("duration") ?? 0,
            bpm: row.double("bpm"),
            bpmSource: row.string("bpm_source").flatMap(ValueSource.init(rawValue:)),
            key: row.string("musical_key"),
            keySource: row.string("key_source").flatMap(ValueSource.init(rawValue:)),
            format: row.string("format") ?? "",
            addedAt: Date(timeIntervalSince1970: row.double("added_at") ?? 0),
            notes: row.string("notes") ?? "",
            analyzed: (row.int("analyzed") ?? 0) != 0,
            contentID: row.string("content_id")
        )
    }

    public func track(id: Int64) throws -> Track? {
        try db.query("SELECT \(Self.trackColumns) FROM tracks WHERE id = ?", [.int(id)]).first.map(track(from:))
    }

    public func track(uri: String) throws -> Track? {
        try db.query("SELECT \(Self.trackColumns) FROM tracks WHERE uri = ?", [.text(uri)]).first.map(track(from:))
    }

    /// The track with this content, whichever Mac's file it was first known from.
    public func track(contentID: String) throws -> Track? {
        try db.query("SELECT \(Self.trackColumns) FROM tracks WHERE content_id = ? ORDER BY id LIMIT 1", [.text(contentID)])
            .first.map(track(from:))
    }

    public func tracks(ids: [Int64]) throws -> [Track] {
        try ids.compactMap { try track(id: $0) }
    }

    /// Turns what someone typed into an FTS5 query: every word must appear, as a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    public func tracks(_ query: TrackQuery = TrackQuery()) throws -> [Track] {
        var conditions: [String] = []
        var params: [SQLValue] = []
        var from = "tracks"

        if let crateID = query.crateID {
            from = "tracks JOIN crate_tracks ON crate_tracks.track_id = tracks.id AND crate_tracks.crate_id = ?"
            params.append(.int(crateID))
        }
        if let text = query.text, let fts = Self.ftsQuery(text) {
            conditions.append("tracks.id IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?)")
            params.append(.text(fts))
        }
        if let bpmMin = query.bpmMin {
            conditions.append("bpm >= ?")
            params.append(.double(bpmMin))
        }
        if let bpmMax = query.bpmMax {
            conditions.append("bpm <= ?")
            params.append(.double(bpmMax))
        }
        if !query.keys.isEmpty {
            conditions.append("musical_key IN (\(query.keys.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: query.keys.map(SQLValue.text))
        }
        if let source = query.source {
            conditions.append("source = ?")
            params.append(.text(source.rawValue))
        }
        if query.needsTagging {
            conditions.append("(artist = '' OR bpm IS NULL OR musical_key IS NULL)")
        }

        var sql = "SELECT \(Self.trackColumns.replacingOccurrences(of: "id,", with: "tracks.id AS id,", options: .anchored)) FROM \(from)"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }

        // In a crate the saved order is the default; an explicit sort overrides it.
        let direction = query.ascending ? "ASC" : "DESC"
        if query.crateID != nil, query.sort == .artist, query.ascending {
            sql += " ORDER BY crate_tracks.position"
        } else {
            // Rows with no value for the sort column always go last.
            sql += " ORDER BY \(query.sort.column) IS NULL, \(query.sort.column) \(direction), title COLLATE NOCASE"
        }
        if let limit = query.limit {
            sql += " LIMIT ?"
            params.append(.int(Int64(limit)))
        }
        return try db.query(sql, params).map(track(from:))
    }

    public func stats() throws -> LibraryStats {
        var stats = LibraryStats()
        if let row = try db.query("""
            SELECT COUNT(*) AS n,
                   SUM(source = 'local') AS local, SUM(source = 'spotify') AS spotify, SUM(source = 'tidal') AS tidal,
                   SUM(bpm IS NOT NULL) AS with_bpm, SUM(musical_key IS NOT NULL) AS with_key,
                   SUM(artist = '' OR bpm IS NULL OR musical_key IS NULL) AS needs,
                   SUM(duration) AS total
            FROM tracks
            """).first
        {
            stats.tracks = Int(row.int("n") ?? 0)
            stats.local = Int(row.int("local") ?? 0)
            stats.spotify = Int(row.int("spotify") ?? 0)
            stats.tidal = Int(row.int("tidal") ?? 0)
            stats.withBPM = Int(row.int("with_bpm") ?? 0)
            stats.withKey = Int(row.int("with_key") ?? 0)
            stats.needsTagging = Int(row.int("needs") ?? 0)
            stats.totalDuration = row.double("total") ?? 0
        }
        stats.crates = Int(try db.query("SELECT COUNT(*) AS n FROM crates").first?.int("n") ?? 0)
        return stats
    }

    // MARK: - Writing tracks

    /// Stores a key in Camelot form when it can be read, and its sort position.
    static func normalizedKey(_ raw: String?) -> (key: String?, order: Int64?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, nil) }
        guard let camelot = CamelotKey(parsing: raw) else { return (nil, nil) }
        return (camelot.description, Int64(camelot.number * 2 + (camelot.isMajor ? 1 : 0)))
    }

    func reindex(id: Int64) throws {
        guard let track = try track(id: id) else { return }
        let filename = track.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
        try db.execute("DELETE FROM tracks_fts WHERE rowid = ?", [.int(id)])
        try db.execute(
            "INSERT INTO tracks_fts (rowid, title, artist, album, notes, filename) VALUES (?, ?, ?, ?, ?, ?)",
            [.int(id), .text(track.title), .text(track.artist), .text(track.album), .text(track.notes), .text(filename)])
    }

    /// Inserts a scanned file, or refreshes it if it is already known.
    /// Values the user typed are kept; tag values replace estimates.
    @discardableResult
    public func upsertLocal(_ file: ScannedFile, notify: Bool = true) throws -> Int64 {
        let key = Self.normalizedKey(file.key)
        let id: Int64 = try db.transaction {
            if let existing = try track(uri: file.uri) {
                try db.execute(
                    "UPDATE tracks SET path = ?, duration = ?, format = ?, size = ?, mtime = ? WHERE id = ?",
                    [.text(file.path), .double(file.duration), .text(file.format), .int(file.size),
                     .double(file.modified), .int(existing.id)])
                // Tags only fill gaps or replace estimates; they never undo an edit.
                var patch = TrackPatch()
                if existing.title.isEmpty { patch.title = file.title }
                if existing.artist.isEmpty, !file.artist.isEmpty { patch.artist = file.artist }
                if existing.album.isEmpty, !file.album.isEmpty { patch.album = file.album }
                try apply(patch, to: existing.id, source: .tag)
                if let bpm = file.bpm { try setBPM(bpm, source: .tag, id: existing.id) }
                if let value = key.key { try setKey(value, source: .tag, id: existing.id) }
                // A file that has changed is, to the other Macs, a different file.
                if let content = file.contentID, content != existing.contentID {
                    try db.execute("UPDATE tracks SET content_id = ? WHERE id = ?", [.text(content), .int(existing.id)])
                    try cratesNowNameable(track: existing.id)
                }
                try reindex(id: existing.id)
                return existing.id
            }
            let content = file.contentID
            if let wanted = content, let twin = try track(contentID: wanted) {
                // The same music is already in the library. If its file is not here (it is known
                // from another Mac, or it has been moved), this file is that track.
                if twin.source == .local, Volumes.resolvedPath(for: twin) == nil {
                    try db.execute(
                        """
                        UPDATE tracks SET uri = ?, path = ?, volume_uuid = ?, rel_path = ?, duration = ?, format = ?,
                                          size = ?, mtime = ? WHERE id = ?
                        """,
                        [.text(file.uri), .text(file.path), .optional(file.volumeUUID), .optional(file.relativePath),
                         .double(file.duration), .text(file.format), .int(file.size), .double(file.modified), .int(twin.id)])
                    try reindex(id: twin.id)
                    return twin.id
                }
                // Otherwise it is a second copy of a file the library already has. It is listed too;
                // to the other Macs the two are one track.
            }
            try db.execute("""
                INSERT INTO tracks (source, uri, path, volume_uuid, rel_path, title, artist, album, duration,
                                    bpm, bpm_source, musical_key, key_source, key_order, format, size, mtime, added_at,
                                    content_id)
                VALUES ('local', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(file.uri), .text(file.path), .optional(file.volumeUUID), .optional(file.relativePath),
                    .text(file.title), .text(file.artist), .text(file.album), .double(file.duration),
                    .optional(file.bpm), file.bpm == nil ? .null : .text(ValueSource.tag.rawValue),
                    .optional(key.key), key.key == nil ? .null : .text(ValueSource.tag.rawValue), .optional(key.order),
                    .text(file.format), .int(file.size), .double(file.modified), .double(clock()), .optional(content),
                ])
            let id = db.lastInsertRowID
            try reindex(id: id)
            // Adding a file again after removing its track is the newer decision.
            if let content { try revive(kind: "track", key: content) }
            return id
        }
        if notify { changed() }
        return id
    }

    /// Adds a Spotify or TIDAL track, or returns the existing row for that URI.
    @discardableResult
    public func upsertStreaming(
        source: TrackSource, uri: String, title: String, artist: String, album: String, duration: Double,
        bpm: Double? = nil, key: String? = nil
    ) throws -> Int64 {
        precondition(source != .local)
        let normalized = Self.normalizedKey(key)
        let id: Int64 = try db.transaction {
            if let existing = try track(uri: uri) { return existing.id }
            try db.execute("""
                INSERT INTO tracks (source, uri, title, artist, album, duration, bpm, bpm_source, musical_key,
                                    key_source, key_order, format, added_at, analyzed, content_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'stream', ?, 1, ?)
                """, [
                    .text(source.rawValue), .text(uri), .text(title), .text(artist), .text(album), .double(duration),
                    .optional(bpm), bpm == nil ? .null : .text(ValueSource.service.rawValue),
                    .optional(normalized.key), normalized.key == nil ? .null : .text(ValueSource.service.rawValue),
                    .optional(normalized.order), .double(clock()), .text(uri),
                ])
            let id = db.lastInsertRowID
            try reindex(id: id)
            try revive(kind: "track", key: uri)
            return id
        }
        changed()
        return id
    }

    /// File size and modified time recorded for a path, so the scanner can skip unchanged files.
    public func fileStamp(uri: String) throws -> (size: Int64, modified: Double)? {
        guard let row = try db.query("SELECT size, mtime FROM tracks WHERE uri = ?", [.text(uri)]).first else {
            return nil
        }
        return (row.int("size") ?? 0, row.double("mtime") ?? 0)
    }

    func setBPM(_ bpm: Double?, source: ValueSource, id: Int64) throws {
        guard let bpm else {
            try db.execute("UPDATE tracks SET bpm = NULL, bpm_source = NULL WHERE id = ?", [.int(id)])
            return
        }
        if let current = try track(id: id), current.bpm != nil, let currentSource = current.bpmSource,
           currentSource.rank > source.rank
        {
            return
        }
        try db.execute(
            "UPDATE tracks SET bpm = ?, bpm_source = ? WHERE id = ?", [.double(bpm), .text(source.rawValue), .int(id)])
    }

    func setKey(_ key: String?, source: ValueSource, id: Int64) throws {
        let normalized = Self.normalizedKey(key)
        guard let value = normalized.key else {
            if key == nil {
                try db.execute(
                    "UPDATE tracks SET musical_key = NULL, key_source = NULL, key_order = NULL WHERE id = ?", [.int(id)])
            }
            return
        }
        if let current = try track(id: id), current.key != nil, let currentSource = current.keySource,
           currentSource.rank > source.rank
        {
            return
        }
        try db.execute(
            "UPDATE tracks SET musical_key = ?, key_source = ?, key_order = ? WHERE id = ?",
            [.text(value), .text(source.rawValue), .optional(normalized.order), .int(id)])
    }

    private func apply(_ patch: TrackPatch, to id: Int64, source: ValueSource) throws {
        var sets: [String] = []
        var params: [SQLValue] = []
        if let title = patch.title { sets.append("title = ?"); params.append(.text(title)) }
        if let artist = patch.artist { sets.append("artist = ?"); params.append(.text(artist)) }
        if let album = patch.album { sets.append("album = ?"); params.append(.text(album)) }
        if let notes = patch.notes { sets.append("notes = ?"); params.append(.text(notes)) }
        if !sets.isEmpty {
            params.append(.int(id))
            try db.execute("UPDATE tracks SET \(sets.joined(separator: ", ")) WHERE id = ?", params)
        }
        if let bpm = patch.bpm { try setBPM(bpm, source: source, id: id) }
        if let key = patch.key { try setKey(key, source: source, id: id) }
    }

    public enum UpdateError: Error, LocalizedError {
        case noSuchTrack(Int64)
        case unreadableKey(String)

        public var errorDescription: String? {
            switch self {
            case .noSuchTrack(let id): return "There is no track with id \(id)."
            case .unreadableKey(let key):
                return "\"\(key)\" is not a key I can read. Use Camelot (8A) or a note name (Am, F# major)."
            }
        }
    }

    /// An edit made by the user or by the agent on their behalf. Only the database changes, never the file.
    public func update(id: Int64, _ patch: TrackPatch) throws {
        guard try track(id: id) != nil else { throw UpdateError.noSuchTrack(id) }
        if case .some(.some(let key)) = patch.key, CamelotKey(parsing: key) == nil {
            throw UpdateError.unreadableKey(key)
        }
        try db.transaction {
            try apply(patch, to: id, source: .manual)
            try db.execute("UPDATE tracks SET details_at = ? WHERE id = ?", [.double(clock()), .int(id)])
            try reindex(id: id)
        }
        changed()
    }

    /// Saves analysis results. Estimates never replace tag or manual values.
    public func setAnalysis(id: Int64, bpm: Double?, key: String?, waveform: Data?, detail: WaveDetail? = nil) throws {
        try db.transaction {
            if let bpm { try setBPM(bpm, source: .estimated, id: id) }
            if let key { try setKey(key, source: .estimated, id: id) }
            try db.execute(
                "UPDATE tracks SET analyzed = 1, waveform = COALESCE(?, waveform) WHERE id = ?",
                [waveform.map(SQLValue.blob) ?? .null, .int(id)])
            if let detail {
                try db.execute(
                    "INSERT OR REPLACE INTO waveforms (track_id, rate, bands) VALUES (?, ?, ?)",
                    [.int(id), .double(detail.columnsPerSecond), .blob(detail.data)])
            }
        }
        changed()
    }

    // MARK: - Beat grids and cues

    /// The track's beat grid, or nil if it has none (not analysed yet, or no beat was found).
    public func beatGrid(id: Int64) throws -> BeatGrid? {
        guard let row = try db.query(
                  "SELECT beats, downbeat, phrase, steady, markers FROM beatgrids WHERE track_id = ?", [.int(id)]).first,
              let beats = row.data("beats"),
              let grid = BeatGrid(
                  data: beats, downbeat: Int(row.int("downbeat") ?? 0), phrase: Int(row.int("phrase") ?? 0),
                  isSteady: row.int("steady") == 1, markerData: row.data("markers")),
              grid.isUsable
        else { return nil }
        // A grid saved before markers existed gets them now, placed as analysis would.
        return grid.markers.isEmpty ? grid.withMarkers(tolerance: BeatTracker.markerTolerance) : grid
    }

    /// Saves a beat grid. A grid from analysis (`edited` false) never replaces one adjusted
    /// by hand. Passing nil records that analysis found no beat, so it is not tried again.
    /// `discardingEdits` lets an analysed grid replace a hand-edited one, for "revert to analysed".
    public func setBeatGrid(id: Int64, _ grid: BeatGrid?, edited: Bool, discardingEdits: Bool = false) throws {
        try db.transaction {
            if !edited, !discardingEdits,
               try db.query("SELECT 1 AS found FROM beatgrids WHERE track_id = ? AND edited = 1", [.int(id)]).first != nil {
                return
            }
            // When a hand last had a say: an edit, or throwing the edits away. Analysis leaves it alone,
            // so on another Mac a grid someone corrected always beats one a machine made later.
            let handAt = edited || discardingEdits
                ? clock()
                : (try db.query("SELECT edit_at FROM beatgrids WHERE track_id = ?", [.int(id)]).first?.double("edit_at") ?? 0)
            try db.execute(
                """
                INSERT OR REPLACE INTO beatgrids (track_id, beats, downbeat, phrase, steady, edited, markers, version, edit_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.int(id), .blob(grid?.data ?? Data()), .int(Int64(grid?.downbeat ?? 0)), .int(Int64(grid?.phrase ?? 0)),
                 .int(grid?.isSteady == true ? 1 : 0), .int(edited ? 1 : 0), .blob(grid?.markerData ?? Data()),
                 .int(Int64(BeatTracker.version)), .double(handAt)])
        }
        changed()
    }

    /// True when a track's grid was made by an earlier, weaker beat tracker and has not been corrected by hand.
    public func beatGridIsOutdated(id: Int64) throws -> Bool {
        try db.query(
            "SELECT 1 AS found FROM beatgrids WHERE track_id = ? AND edited = 0 AND version < ?",
            [.int(id), .int(Int64(BeatTracker.version))]).first != nil
    }

    /// Cue points by slot number, in seconds.
    public func cues(id: Int64) throws -> [Int: Double] {
        var cues: [Int: Double] = [:]
        for row in try db.query("SELECT slot, position FROM cues WHERE track_id = ?", [.int(id)]) {
            if let slot = row.int("slot"), let position = row.double("position") { cues[Int(slot)] = position }
        }
        return cues
    }

    /// Cue points in slot order, with their names and, for saved loops, where the loop ends.
    public func cuePoints(id: Int64) throws -> [CuePoint] {
        try db.query("SELECT slot, position, name, loop_end FROM cues WHERE track_id = ? ORDER BY slot", [.int(id)]).compactMap { row in
            guard let slot = row.int("slot"), let position = row.double("position") else { return nil }
            return CuePoint(slot: Int(slot), position: position, name: row.string("name") ?? "", loopEnd: row.double("loop_end"))
        }
    }

    /// Replaces a track's cue points with these, all at once.
    public func setCuePoints(id: Int64, _ cues: [CuePoint]) throws {
        try db.transaction {
            try db.execute("DELETE FROM cues WHERE track_id = ?", [.int(id)])
            for cue in cues where CuePoint.slots.contains(cue.slot) {
                try db.execute(
                    "INSERT OR REPLACE INTO cues (track_id, slot, position, name, loop_end) VALUES (?, ?, ?, ?, ?)",
                    [.int(id), .int(Int64(cue.slot)), .double(max(0, cue.position)), .text(cue.name), .optional(cue.loopEnd)])
            }
            try db.execute("UPDATE tracks SET cues_at = ? WHERE id = ?", [.double(clock()), .int(id)])
        }
        changed()
    }

    /// Sets one cue point, name and loop included, leaving the others as they are.
    public func setCuePoint(id: Int64, _ cue: CuePoint) throws {
        try db.execute(
            "INSERT OR REPLACE INTO cues (track_id, slot, position, name, loop_end) VALUES (?, ?, ?, ?, ?)",
            [.int(id), .int(Int64(cue.slot)), .double(max(0, cue.position)), .text(cue.name), .optional(cue.loopEnd)])
        try db.execute("UPDATE tracks SET cues_at = ? WHERE id = ?", [.double(clock()), .int(id)])
        changed()
    }

    /// Sets a cue point, or removes it when `position` is nil. A cue that is moved keeps its name; a loop moves whole.
    public func setCue(id: Int64, slot: Int, position: Double?) throws {
        if let position {
            try db.execute(
                """
                INSERT INTO cues (track_id, slot, position) VALUES (?, ?, ?)
                ON CONFLICT(track_id, slot) DO UPDATE SET loop_end = loop_end + (excluded.position - position), position = excluded.position
                """,
                [.int(id), .int(Int64(slot)), .double(position)])
        } else {
            try db.execute("DELETE FROM cues WHERE track_id = ? AND slot = ?", [.int(id), .int(Int64(slot))])
        }
        try db.execute("UPDATE tracks SET cues_at = ? WHERE id = ?", [.double(clock()), .int(id)])
        changed()
    }

    public func waveDetail(id: Int64) throws -> WaveDetail? {
        guard let row = try db.query("SELECT rate, bands FROM waveforms WHERE track_id = ?", [.int(id)]).first,
              let bands = row.data("bands"), let rate = row.double("rate")
        else { return nil }
        return WaveDetail(columnsPerSecond: rate, data: bands)
    }

    public func waveform(id: Int64) throws -> Data? {
        try db.query("SELECT waveform FROM tracks WHERE id = ?", [.int(id)]).first?.data("waveform")
    }

    public func unanalyzedLocalTracks() throws -> [Track] {
        try db.query(
            """
            SELECT \(Self.trackColumns) FROM tracks WHERE source = 'local'
                AND path IS NOT NULL
                AND (analyzed = 0 OR id NOT IN (SELECT track_id FROM waveforms)
                     OR id NOT IN (SELECT track_id FROM beatgrids)
                     OR id IN (SELECT track_id FROM beatgrids WHERE edited = 0 AND version < \(BeatTracker.version)))
                ORDER BY added_at DESC
            """
        ).map(track(from:))
    }

    /// Removes tracks from the library, on every Mac once they hear of it. Never touches a music file.
    public func deleteTracks(ids: [Int64]) throws {
        try db.transaction {
            for id in ids {
                if let content = try track(id: id)?.contentID,
                   try db.query("SELECT COUNT(*) AS n FROM tracks WHERE content_id = ?", [.text(content)]).first?.int("n") == 1 {
                    try bury(kind: "track", key: content)
                }
                try db.execute("DELETE FROM tracks_fts WHERE rowid = ?", [.int(id)])
                try db.execute("DELETE FROM tracks WHERE id = ?", [.int(id)])
            }
        }
        changed()
    }

    // MARK: - Removed and brought back

    /// Records that a track or crate was removed, so the removal reaches the other Macs.
    func bury(kind: String, key: String, at: Double? = nil) throws {
        try db.execute(
            "INSERT OR REPLACE INTO lives (kind, key, at, alive) VALUES (?, ?, ?, 0)", [.text(kind), .text(key), .double(at ?? clock())])
    }

    /// Records that something once removed is back, which is news the other Macs need too.
    func revive(kind: String, key: String, at: Double? = nil) throws {
        guard try db.query("SELECT 1 AS found FROM lives WHERE kind = ? AND key = ?", [.text(kind), .text(key)]).first != nil
        else { return }
        try db.execute(
            "INSERT OR REPLACE INTO lives (kind, key, at, alive) VALUES (?, ?, ?, 1)", [.text(kind), .text(key), .double(at ?? clock())])
    }

    // MARK: - Fingerprints

    /// Local tracks not yet fingerprinted, for the background pass after an upgrade.
    public func tracksNeedingContentID() throws -> [Track] {
        try db.query("SELECT \(Self.trackColumns) FROM tracks WHERE source = 'local' AND content_id IS NULL AND path IS NOT NULL")
            .map(track(from:))
    }

    /// Records a file's fingerprint.
    public func setContentID(id: Int64, _ content: String) throws {
        try db.transaction {
            try db.execute("UPDATE tracks SET content_id = ? WHERE id = ?", [.text(content), .int(id)])
            try revive(kind: "track", key: content)
            try cratesNowNameable(track: id)
        }
    }

    /// A track that has just got its fingerprint can now be named to the other Macs, so the
    /// crates it is in have more to say than they did: they count as changed, though not as
    /// edited (when they were last edited stays as it was).
    private func cratesNowNameable(track id: Int64) throws {
        for row in try db.query("SELECT crate_id FROM crate_tracks WHERE track_id = ?", [.int(id)]) {
            guard let crate = row.int("crate_id") else { continue }
            try db.execute("UPDATE crates SET rev = ? WHERE id = ?", [.text(UUID().uuidString), .int(crate)])
        }
    }

    // MARK: - Crates

    public enum CrateError: Error, LocalizedError {
        case nameTaken(String)
        case noSuchCrate(String)

        public var errorDescription: String? {
            switch self {
            case .nameTaken(let name): return "A crate called \"\(name)\" already exists."
            case .noSuchCrate(let name): return "There is no crate called \"\(name)\"."
            }
        }
    }

    public func crates() throws -> [Crate] {
        try db.query("""
            SELECT crates.id AS id, name, uid, keep_here, COUNT(crate_tracks.track_id) AS n
            FROM crates LEFT JOIN crate_tracks ON crate_tracks.crate_id = crates.id
            GROUP BY crates.id ORDER BY name COLLATE NOCASE
            """).map {
                Crate(
                    id: $0.int("id") ?? 0, name: $0.string("name") ?? "", trackCount: Int($0.int("n") ?? 0),
                    uid: $0.string("uid") ?? "", keepHere: $0.int("keep_here") == 1)
            }
    }

    /// Marks a crate as changed here and now, which is what sends the change to the other Macs.
    func touchCrate(id: Int64) throws {
        try db.execute(
            "UPDATE crates SET rev = ?, changed_at = ?, editor = ? WHERE id = ?",
            [.text(UUID().uuidString), .double(clock()), .text(deviceName), .int(id)])
    }

    /// Whether a crate's tracks are copied to this Mac ahead of time.
    public func setKeepHere(crateID: Int64, _ keep: Bool) throws {
        try db.execute("UPDATE crates SET keep_here = ? WHERE id = ?", [.int(keep ? 1 : 0), .int(crateID)])
        changed()
    }

    public func crate(named name: String) throws -> Crate? {
        try crates().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func crate(id: Int64) throws -> Crate? {
        try crates().first { $0.id == id }
    }

    @discardableResult
    public func createCrate(name: String) throws -> Crate {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if try crate(named: trimmed) != nil { throw CrateError.nameTaken(trimmed) }
        let uid = UUID().uuidString, name = deviceName
        try db.execute(
            "INSERT INTO crates (name, created_at, uid, rev, changed_at, origin, editor) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(trimmed), .double(clock()), .text(uid), .text(UUID().uuidString), .double(clock()), .text(name), .text(name)])
        let crate = Crate(id: db.lastInsertRowID, name: trimmed, trackCount: 0, uid: uid)
        changed()
        return crate
    }

    public func renameCrate(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try crate(named: trimmed), existing.id != id { throw CrateError.nameTaken(trimmed) }
        try db.execute("UPDATE crates SET name = ? WHERE id = ?", [.text(trimmed), .int(id)])
        try touchCrate(id: id)
        changed()
    }

    public func deleteCrate(id: Int64) throws {
        if let uid = try crate(id: id)?.uid, !uid.isEmpty { try bury(kind: "crate", key: uid) }
        try db.execute("DELETE FROM crates WHERE id = ?", [.int(id)])
        changed()
    }

    /// Appends tracks to a crate, skipping any already in it. Returns how many were added.
    @discardableResult
    public func addToCrate(id crateID: Int64, trackIDs: [Int64]) throws -> Int {
        let added: Int = try db.transaction {
            var position = try db.query(
                "SELECT COALESCE(MAX(position), -1) AS p FROM crate_tracks WHERE crate_id = ?", [.int(crateID)]
            ).first?.int("p") ?? -1
            var count = 0
            for trackID in trackIDs {
                guard try track(id: trackID) != nil else { continue }
                position += 1
                count += try db.execute(
                    "INSERT OR IGNORE INTO crate_tracks (crate_id, track_id, position) VALUES (?, ?, ?)",
                    [.int(crateID), .int(trackID), .int(position)])
            }
            if count > 0 { try touchCrate(id: crateID) }
            return count
        }
        changed()
        return added
    }

    @discardableResult
    public func removeFromCrate(id crateID: Int64, trackIDs: [Int64]) throws -> Int {
        let removed: Int = try db.transaction {
            var count = 0
            for trackID in trackIDs {
                count += try db.execute(
                    "DELETE FROM crate_tracks WHERE crate_id = ? AND track_id = ?", [.int(crateID), .int(trackID)])
            }
            if count > 0 { try touchCrate(id: crateID) }
            return count
        }
        changed()
        return removed
    }

    /// Puts the given tracks first, in the given order; tracks not mentioned keep their order after them.
    public func reorderCrate(id crateID: Int64, trackIDs: [Int64]) throws {
        try db.transaction {
            var query = TrackQuery()
            query.crateID = crateID
            let current = try tracks(query).map(\.id)
            let mentioned = trackIDs.filter(current.contains)
            let ordered = mentioned + current.filter { !mentioned.contains($0) }
            for (position, trackID) in ordered.enumerated() {
                try db.execute(
                    "UPDATE crate_tracks SET position = ? WHERE crate_id = ? AND track_id = ?",
                    [.int(Int64(position)), .int(crateID), .int(trackID)])
            }
            if ordered != current { try touchCrate(id: crateID) }
        }
        changed()
    }

    // MARK: - Folders

    public func folders() throws -> [LibraryFolder] {
        try db.query("SELECT id, path, volume_uuid, rel_path FROM folders ORDER BY path").map {
            LibraryFolder(
                id: $0.int("id") ?? 0, path: $0.string("path") ?? "", volumeUUID: $0.string("volume_uuid"),
                relativePath: $0.string("rel_path"))
        }
    }

    public func addFolder(path: String, volumeUUID: String? = nil, relativePath: String? = nil) throws {
        // A drive that remounts under another name is the same folder at a new path.
        if let volumeUUID, let relativePath,
           let existing = try db.query(
               "SELECT id FROM folders WHERE volume_uuid = ? AND rel_path = ?", [.text(volumeUUID), .text(relativePath)]
           ).first?.int("id")
        {
            try db.execute("UPDATE OR IGNORE folders SET path = ? WHERE id = ?", [.text(path), .int(existing)])
            return
        }
        try db.execute(
            "INSERT OR IGNORE INTO folders (path, volume_uuid, rel_path) VALUES (?, ?, ?)",
            [.text(path), .optional(volumeUUID), .optional(relativePath)])
        changed()
    }

    /// Removes a folder and the local tracks that were found in it. A track another Mac also
    /// has stays in the library, as one that is not on this Mac: taking a folder out of one
    /// Mac's library says nothing about the others.
    public func removeFolder(id: Int64) throws {
        guard let folder = try folders().first(where: { $0.id == id }) else { return }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let found = try db.query(
            "SELECT id, content_id FROM tracks WHERE source = 'local' AND substr(path, 1, ?) = ?",
            [.int(Int64(prefix.count)), .text(prefix)])
        try db.execute("DELETE FROM folders WHERE id = ?", [.int(id)])
        var gone: [Int64] = []
        for row in found {
            guard let track = row.int("id") else { continue }
            if let content = row.string("content_id"),
               try db.query("SELECT 1 AS found FROM peer_holdings WHERE content_id = ? LIMIT 1", [.text(content)]).first != nil {
                try detachFile(id: track, contentID: content)
            } else {
                gone.append(track)
            }
        }
        try deleteTracks(ids: gone)
    }

    /// Forgets where a track's file was on this Mac, keeping the track.
    func detachFile(id: Int64, contentID: String) throws {
        try db.execute(
            "UPDATE tracks SET uri = ?, path = NULL, volume_uuid = NULL, rel_path = NULL, size = 0, mtime = 0 WHERE id = ?",
            [.text("crate:\(contentID)"), .int(id)])
    }

    // MARK: - Settings

    public func setting(_ key: String) -> String? {
        try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?.string("value")
    }

    /// Removes every setting whose name starts with `prefix`.
    public func removeSettings(prefix: String) {
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        _ = try? db.execute("DELETE FROM settings WHERE key LIKE ? ESCAPE '\\'", [.text(escaped + "%")])
    }

    public func setSetting(_ key: String, _ value: String?) {
        if let value {
            _ = try? db.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)])
        } else {
            _ = try? db.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }
}
