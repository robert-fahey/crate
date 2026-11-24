import Foundation

/// The library's side of sharing: what this Mac has to say for itself, and how
/// what another Mac says is folded in. No networking here.
extension LibraryStore {
    public var device: DeviceInfo { DeviceInfo(id: deviceID, name: deviceName) }

    // MARK: - What this Mac has

    public func syncManifest() throws -> SyncManifest {
        var seen = Set<String>()
        var tracks: [TrackStamp] = []
        for row in try db.query("""
            SELECT content_id, details_at, cues_at, bpm, bpm_source, musical_key, key_source, analyzed,
                   beatgrids.edit_at AS edit_at, beatgrids.version AS version, length(beatgrids.beats) AS beat_bytes,
                   (SELECT 1 FROM waveforms WHERE waveforms.track_id = tracks.id) AS has_wave
            FROM tracks LEFT JOIN beatgrids ON beatgrids.track_id = tracks.id
            WHERE content_id IS NOT NULL ORDER BY tracks.id
            """) {
            guard let key = row.string("content_id"), seen.insert(key).inserted else { continue }
            func rank(_ value: String, _ source: String) -> Int {
                guard row.double(value) != nil || row.string(value) != nil else { return -1 }
                return row.string(source).flatMap(ValueSource.init(rawValue:))?.rank ?? 0
            }
            let hasGrid = (row.int("beat_bytes") ?? 0) > 0
            tracks.append(TrackStamp(
                key: key, detailsAt: row.double("details_at") ?? 0, cuesAt: row.double("cues_at") ?? 0,
                gridEditAt: hasGrid ? row.double("edit_at") ?? 0 : 0, gridVersion: hasGrid ? Int(row.int("version") ?? 1) : 0,
                bpmRank: rank("bpm", "bpm_source"), keyRank: rank("musical_key", "key_source"),
                analysed: row.int("analyzed") == 1 && row.int("has_wave") == 1))
        }
        let crates = try db.query("SELECT uid, rev, changed_at FROM crates WHERE uid IS NOT NULL").map {
            CrateStamp(uid: $0.string("uid") ?? "", rev: $0.string("rev") ?? "", changedAt: $0.double("changed_at") ?? 0)
        }
        let lives = try db.query("SELECT kind, key, at, alive FROM lives").map {
            Life(kind: $0.string("kind") ?? "", key: $0.string("key") ?? "", at: $0.double("at") ?? 0, alive: $0.int("alive") == 1)
        }
        return SyncManifest(device: device, tracks: tracks, crates: crates, lives: lives, holdings: try holdings())
    }

    /// The tracks whose files this Mac could hand over now: on its own disk, or on a drive that is connected.
    public func holdings() throws -> [String] {
        var mounted: [String: Bool] = [:]
        var held = Set<String>()
        for row in try db.query(
            "SELECT content_id, volume_uuid FROM tracks WHERE source = 'local' AND content_id IS NOT NULL AND path IS NOT NULL") {
            guard let key = row.string("content_id") else { continue }
            if let volume = row.string("volume_uuid") {
                if mounted[volume] == nil { mounted[volume] = Volumes.mountPoint(uuid: volume) != nil }
                guard mounted[volume] == true else { continue }
            }
            held.insert(key)
        }
        return held.sorted()
    }

    public func trackRecords(keys: [String]) throws -> [TrackRecord] {
        try keys.compactMap { key in
            guard let row = try db.query(
                """
                SELECT id, source, path, title, artist, album, duration, format, size, added_at, notes, bpm, bpm_source,
                       musical_key, key_source, details_at, cues_at
                FROM tracks WHERE content_id = ? ORDER BY id LIMIT 1
                """, [.text(key)]).first, let id = row.int("id")
            else { return nil }
            var cues: [String: Double] = [:], cueNames: [String: String] = [:], cueLoops: [String: Double] = [:]
            for cue in try self.cuePoints(id: id) {
                cues[String(cue.slot)] = cue.position
                if !cue.name.isEmpty { cueNames[String(cue.slot)] = cue.name }
                if let end = cue.loopEnd { cueLoops[String(cue.slot)] = end }
            }
            return TrackRecord(
                key: key, source: row.string("source") ?? "local", title: row.string("title") ?? "",
                artist: row.string("artist") ?? "", album: row.string("album") ?? "", duration: row.double("duration") ?? 0,
                format: row.string("format") ?? "", size: row.int("size") ?? 0, addedAt: row.double("added_at") ?? 0,
                notes: row.string("notes") ?? "", bpm: row.double("bpm"), bpmSource: row.string("bpm_source"),
                musicalKey: row.string("musical_key"), keySource: row.string("key_source"),
                detailsAt: row.double("details_at") ?? 0, cues: cues, cueNames: cueNames, cueLoops: cueLoops,
                cuesAt: row.double("cues_at") ?? 0,
                grid: try gridRecord(id: id), fileName: row.string("path").map { ($0 as NSString).lastPathComponent })
        }
    }

    private func gridRecord(id: Int64) throws -> GridRecord? {
        guard let row = try db.query(
            "SELECT beats, markers, downbeat, phrase, steady, edited, version, edit_at FROM beatgrids WHERE track_id = ?", [.int(id)]).first,
              let beats = row.data("beats"), !beats.isEmpty
        else { return nil }
        return GridRecord(
            beats: beats, markers: row.data("markers") ?? Data(), downbeat: Int(row.int("downbeat") ?? 0),
            phrase: Int(row.int("phrase") ?? 0), steady: row.int("steady") == 1, edited: row.int("edited") == 1,
            version: Int(row.int("version") ?? 1), editAt: row.double("edit_at") ?? 0)
    }

    public func crateRecords(uids: [String]) throws -> [CrateRecord] {
        try uids.compactMap { try crateRecord(uid: $0) }
    }

    func crateRecord(uid: String) throws -> CrateRecord? {
        guard let row = try db.query(
            "SELECT id, name, rev, changed_at, origin, editor FROM crates WHERE uid = ?", [.text(uid)]).first,
              let id = row.int("id")
        else { return nil }
        // Tracks not yet fingerprinted cannot be named to another Mac; they stay in this Mac's copy only.
        let keys = try db.query(
            """
            SELECT tracks.content_id AS key FROM crate_tracks JOIN tracks ON tracks.id = crate_tracks.track_id
            WHERE crate_tracks.crate_id = ? AND tracks.content_id IS NOT NULL ORDER BY crate_tracks.position
            """, [.int(id)]).compactMap { $0.string("key") }
        return CrateRecord(
            uid: uid, name: row.string("name") ?? "", rev: row.string("rev") ?? "", changedAt: row.double("changed_at") ?? 0,
            origin: row.string("origin") ?? "", editor: row.string("editor") ?? "", tracks: keys)
    }

    public func analysisRecords(keys: [String]) throws -> [AnalysisRecord] {
        try keys.compactMap { key in
            guard let row = try db.query(
                """
                SELECT tracks.waveform AS waveform, waveforms.rate AS rate, waveforms.bands AS bands
                FROM tracks LEFT JOIN waveforms ON waveforms.track_id = tracks.id
                WHERE content_id = ? AND analyzed = 1 ORDER BY tracks.id LIMIT 1
                """, [.text(key)]).first
            else { return nil }
            return AnalysisRecord(key: key, waveform: row.data("waveform"), detailRate: row.double("rate"), detailBands: row.data("bands"))
        }
    }

    // MARK: - Reading another Mac's manifest

    /// Takes in what needs no asking (removals, and which files the other Mac holds) and
    /// returns what to ask it for.
    public func absorb(_ manifest: SyncManifest) throws -> SyncWants {
        let peer = manifest.device.id
        var wants = SyncWants()
        var didChange = false
        try db.transaction {
            try db.execute(
                "INSERT INTO peers (device_id, name, last_seen) VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen",
                [.text(peer), .text(manifest.device.name), .double(clock())])
            if try setHoldings(manifest.holdings, peer: peer) { didChange = true }
            for life in manifest.lives where try absorb(life, peer: peer, theirs: manifest) { didChange = true }

            for stamp in manifest.tracks {
                if try isBuried(kind: "track", key: stamp.key) { continue }
                guard let row = try db.query(
                    """
                    SELECT tracks.id AS id, path, details_at, cues_at, bpm, bpm_source, musical_key, key_source, analyzed,
                           beatgrids.edit_at AS edit_at, beatgrids.version AS version, length(beatgrids.beats) AS beat_bytes,
                           (SELECT 1 FROM waveforms WHERE waveforms.track_id = tracks.id) AS has_wave
                    FROM tracks LEFT JOIN beatgrids ON beatgrids.track_id = tracks.id
                    WHERE content_id = ? ORDER BY tracks.id LIMIT 1
                    """, [.text(stamp.key)]).first
                else {
                    wants.tracks.append(stamp.key)
                    continue
                }
                let hasGrid = (row.int("beat_bytes") ?? 0) > 0
                let bpmRank = row.double("bpm") == nil ? -1 : row.string("bpm_source").flatMap(ValueSource.init(rawValue:))?.rank ?? 0
                let keyRank = row.string("musical_key") == nil ? -1 : row.string("key_source").flatMap(ValueSource.init(rawValue:))?.rank ?? 0
                if stamp.detailsAt > (row.double("details_at") ?? 0) || stamp.cuesAt > (row.double("cues_at") ?? 0)
                    || stamp.bpmRank > bpmRank || stamp.keyRank > keyRank
                    || SyncRules.gridWins(
                        theirEditAt: stamp.gridEditAt, theirVersion: stamp.gridVersion,
                        ourEditAt: hasGrid ? row.double("edit_at") : nil, ourVersion: hasGrid ? Int(row.int("version") ?? 1) : nil) {
                    wants.tracks.append(stamp.key)
                }
                // Waveforms are only worth copying for a file that is here to be played.
                if stamp.analysed, row.string("path") != nil, !(row.int("analyzed") == 1 && row.int("has_wave") == 1) {
                    wants.analysis.append(stamp.key)
                }
            }

            for theirs in manifest.crates {
                guard let ours = try crateStamp(uid: theirs.uid) else {
                    // A crate deleted here stays deleted unless the other Mac has changed it since.
                    if let buried = try life(kind: "crate", key: theirs.uid), !buried.alive, buried.at >= theirs.changedAt { continue }
                    wants.crates.append(theirs.uid)
                    continue
                }
                switch SyncRules.crate(ours: ours, theirs: theirs, agreed: try agreedRevision(uid: theirs.uid, peer: peer)) {
                case .same: try setAgreed(uid: theirs.uid, rev: theirs.rev, peer: peer)
                case .keepOurs: break
                case .takeTheirs, .keepBoth: wants.crates.append(theirs.uid)
                }
            }
        }
        if didChange { changed() }
        return wants
    }

    private func setHoldings(_ keys: [String], peer: String) throws -> Bool {
        let before = Set(try db.query("SELECT content_id FROM peer_holdings WHERE device_id = ?", [.text(peer)]).compactMap { $0.string("content_id") })
        let after = Set(keys)
        guard before != after else { return false }
        for key in before.subtracting(after) {
            try db.execute("DELETE FROM peer_holdings WHERE device_id = ? AND content_id = ?", [.text(peer), .text(key)])
        }
        for key in after.subtracting(before) {
            try db.execute("INSERT OR IGNORE INTO peer_holdings (device_id, content_id) VALUES (?, ?)", [.text(peer), .text(key)])
        }
        return true
    }

    /// Which other Macs can hand over a track's file, by device id.
    public func holders(of contentID: String) throws -> [String] {
        try db.query("SELECT device_id FROM peer_holdings WHERE content_id = ?", [.text(contentID)]).compactMap { $0.string("device_id") }
    }

    /// Every track some other Mac holds, with the names of the Macs that hold it.
    public func heldElsewhere() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for row in try db.query("""
            SELECT content_id, COALESCE(NULLIF(peers.name, ''), 'another Mac') AS name
            FROM peer_holdings LEFT JOIN peers ON peers.device_id = peer_holdings.device_id
            """) {
            if let key = row.string("content_id"), let name = row.string("name") { result[key, default: []].append(name) }
        }
        return result
    }

    public func peers() throws -> [(device: DeviceInfo, lastSeen: Double)] {
        try db.query("SELECT device_id, name, last_seen FROM peers ORDER BY name").map {
            (DeviceInfo(id: $0.string("device_id") ?? "", name: $0.string("name") ?? ""), $0.double("last_seen") ?? 0)
        }
    }

    /// Forgets another Mac: what it held and what was agreed with it.
    public func forgetPeer(id: String) throws {
        try db.transaction {
            for table in ["peers", "peer_holdings", "peer_crates"] {
                try db.execute("DELETE FROM \(table) WHERE device_id = ?", [.text(id)])
            }
        }
        changed()
    }

    // MARK: Removed and brought back

    func life(kind: String, key: String) throws -> Life? {
        try db.query("SELECT at, alive FROM lives WHERE kind = ? AND key = ?", [.text(kind), .text(key)]).first.map {
            Life(kind: kind, key: key, at: $0.double("at") ?? 0, alive: $0.int("alive") == 1)
        }
    }

    func isBuried(kind: String, key: String) throws -> Bool {
        try life(kind: kind, key: key).map { !$0.alive } ?? false
    }

    /// Returns true if anything in the library changed.
    private func absorb(_ theirs: Life, peer: String, theirs manifest: SyncManifest) throws -> Bool {
        if let ours = try life(kind: theirs.kind, key: theirs.key), ours.at >= theirs.at { return false }
        guard !theirs.alive else {
            try db.execute(
                "INSERT OR REPLACE INTO lives (kind, key, at, alive) VALUES (?, ?, ?, 1)",
                [.text(theirs.kind), .text(theirs.key), .double(theirs.at)])
            return false
        }
        if theirs.kind == "crate", let ours = try crateStamp(uid: theirs.key) {
            // Deleted there, changed here since the two last agreed: the change is kept, and that is the newer decision.
            let agreed = try agreedRevision(uid: theirs.key, peer: peer)
            if agreed.map({ $0 != ours.rev }) ?? (ours.changedAt > theirs.at) {
                try db.execute(
                    "INSERT OR REPLACE INTO lives (kind, key, at, alive) VALUES ('crate', ?, ?, 1)", [.text(theirs.key), .double(clock())])
                return false
            }
            try db.execute("DELETE FROM crates WHERE uid = ?", [.text(theirs.key)])
        }
        var removed = theirs.kind == "crate"
        if theirs.kind == "track" {
            for row in try db.query("SELECT id FROM tracks WHERE content_id = ?", [.text(theirs.key)]) {
                guard let id = row.int("id") else { continue }
                try db.execute("DELETE FROM tracks_fts WHERE rowid = ?", [.int(id)])
                try db.execute("DELETE FROM tracks WHERE id = ?", [.int(id)])
                removed = true
            }
        }
        try bury(kind: theirs.kind, key: theirs.key, at: theirs.at)
        return removed
    }

    // MARK: Crates

    func crateStamp(uid: String) throws -> CrateStamp? {
        try db.query("SELECT rev, changed_at FROM crates WHERE uid = ?", [.text(uid)]).first.map {
            CrateStamp(uid: uid, rev: $0.string("rev") ?? "", changedAt: $0.double("changed_at") ?? 0)
        }
    }

    func agreedRevision(uid: String, peer: String) throws -> String? {
        try db.query("SELECT rev FROM peer_crates WHERE device_id = ? AND crate_uid = ?", [.text(peer), .text(uid)]).first?.string("rev")
    }

    func setAgreed(uid: String, rev: String, peer: String) throws {
        try db.execute(
            "INSERT OR REPLACE INTO peer_crates (device_id, crate_uid, rev) VALUES (?, ?, ?)", [.text(peer), .text(uid), .text(rev)])
    }

    // MARK: - Taking in records

    public func apply(tracks records: [TrackRecord]) throws {
        guard !records.isEmpty else { return }
        try db.transaction {
            for record in records where try !isBuried(kind: "track", key: record.key) { try apply(record) }
        }
        changed()
    }

    private func apply(_ record: TrackRecord) throws {
        let key = Self.normalizedKey(record.musicalKey)
        guard let row = try db.query(
            "SELECT id, details_at, cues_at, bpm, bpm_source, musical_key, key_source FROM tracks WHERE content_id = ? ORDER BY id LIMIT 1",
            [.text(record.key)]).first, let id = row.int("id")
        else {
            // A track this Mac has never seen. Its file stays where it is until it is wanted.
            let isLocal = record.source == TrackSource.local.rawValue
            try db.execute("""
                INSERT INTO tracks (source, uri, title, artist, album, duration, bpm, bpm_source, musical_key, key_source,
                                    key_order, format, size, added_at, notes, analyzed, content_id, details_at, cues_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(record.source), .text(isLocal ? "crate:\(record.key)" : record.key), .text(record.title),
                    .text(record.artist), .text(record.album), .double(record.duration), .optional(record.bpm),
                    .optional(record.bpm == nil ? nil : record.bpmSource), .optional(key.key),
                    .optional(key.key == nil ? nil : record.keySource), .optional(key.order), .text(record.format),
                    .int(isLocal ? 0 : record.size), .double(record.addedAt), .text(record.notes), .int(isLocal ? 0 : 1),
                    .text(record.key), .double(record.detailsAt), .double(record.cuesAt),
                ])
            let id = db.lastInsertRowID
            try setCues(record, id: id)
            if let grid = record.grid { try write(grid, id: id) }
            try reindex(id: id)
            return
        }
        if record.detailsAt > (row.double("details_at") ?? 0) {
            try db.execute(
                """
                UPDATE tracks SET title = ?, artist = ?, album = ?, notes = ?, bpm = ?, bpm_source = ?, musical_key = ?,
                                  key_source = ?, key_order = ?, details_at = ? WHERE id = ?
                """,
                [.text(record.title), .text(record.artist), .text(record.album), .text(record.notes), .optional(record.bpm),
                 .optional(record.bpm == nil ? nil : record.bpmSource), .optional(key.key),
                 .optional(key.key == nil ? nil : record.keySource), .optional(key.order), .double(record.detailsAt), .int(id)])
        } else {
            // Not a newer edit, but perhaps a better-founded tempo or key: a tag where this Mac only has a guess.
            func rank(_ source: String?) -> Int { source.flatMap(ValueSource.init(rawValue:))?.rank ?? 0 }
            if let bpm = record.bpm, row.double("bpm") == nil || rank(record.bpmSource) > rank(row.string("bpm_source")) {
                try db.execute("UPDATE tracks SET bpm = ?, bpm_source = ? WHERE id = ?", [.double(bpm), .optional(record.bpmSource), .int(id)])
            }
            if let value = key.key, row.string("musical_key") == nil || rank(record.keySource) > rank(row.string("key_source")) {
                try db.execute(
                    "UPDATE tracks SET musical_key = ?, key_source = ?, key_order = ? WHERE id = ?",
                    [.text(value), .optional(record.keySource), .optional(key.order), .int(id)])
            }
        }
        if record.cuesAt > (row.double("cues_at") ?? 0) {
            try setCues(record, id: id)
            try db.execute("UPDATE tracks SET cues_at = ? WHERE id = ?", [.double(record.cuesAt), .int(id)])
        }
        if let grid = record.grid {
            let ours = try db.query("SELECT edit_at, version, length(beats) AS n FROM beatgrids WHERE track_id = ?", [.int(id)]).first
            let hasGrid = (ours?.int("n") ?? 0) > 0
            if SyncRules.gridWins(
                theirEditAt: grid.editAt, theirVersion: grid.version, ourEditAt: hasGrid ? ours?.double("edit_at") : nil,
                ourVersion: hasGrid ? Int(ours?.int("version") ?? 1) : nil) {
                try write(grid, id: id)
            }
        }
        try reindex(id: id)
    }

    private func setCues(_ record: TrackRecord, id: Int64) throws {
        try db.execute("DELETE FROM cues WHERE track_id = ?", [.int(id)])
        for (key, position) in record.cues {
            guard let slot = Int64(key) else { continue }
            try db.execute(
                "INSERT OR REPLACE INTO cues (track_id, slot, position, name, loop_end) VALUES (?, ?, ?, ?, ?)",
                [.int(id), .int(slot), .double(position), .text(record.cueNames?[key] ?? ""), .optional(record.cueLoops?[key])])
        }
    }

    private func write(_ grid: GridRecord, id: Int64) throws {
        try db.execute(
            """
            INSERT OR REPLACE INTO beatgrids (track_id, beats, downbeat, phrase, steady, edited, markers, version, edit_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.int(id), .blob(grid.beats), .int(Int64(grid.downbeat)), .int(Int64(grid.phrase)), .int(grid.steady ? 1 : 0),
             .int(grid.edited ? 1 : 0), .blob(grid.markers), .int(Int64(grid.version)), .double(grid.editAt)])
    }

    public func apply(analysis records: [AnalysisRecord]) throws {
        guard !records.isEmpty else { return }
        try db.transaction {
            for record in records {
                guard let id = try db.query("SELECT id FROM tracks WHERE content_id = ? ORDER BY id LIMIT 1", [.text(record.key)]).first?.int("id")
                else { continue }
                try db.execute(
                    "UPDATE tracks SET analyzed = 1, waveform = COALESCE(?, waveform) WHERE id = ?",
                    [record.waveform.map(SQLValue.blob) ?? .null, .int(id)])
                if let rate = record.detailRate, let bands = record.detailBands {
                    try db.execute(
                        "INSERT OR REPLACE INTO waveforms (track_id, rate, bands) VALUES (?, ?, ?)", [.int(id), .double(rate), .blob(bands)])
                }
            }
        }
        changed()
    }

    /// Takes in crates from another Mac. Tracks they name must have been taken in first.
    public func apply(crates records: [CrateRecord], from peer: String) throws {
        guard !records.isEmpty else { return }
        try db.transaction {
            for theirs in records {
                guard let ours = try crateRecord(uid: theirs.uid) else {
                    if let buried = try life(kind: "crate", key: theirs.uid), !buried.alive, buried.at >= theirs.changedAt { continue }
                    try save(theirs)
                    try setAgreed(uid: theirs.uid, rev: theirs.rev, peer: peer)
                    continue
                }
                let verdict = SyncRules.crate(
                    ours: CrateStamp(uid: ours.uid, rev: ours.rev, changedAt: ours.changedAt),
                    theirs: CrateStamp(uid: theirs.uid, rev: theirs.rev, changedAt: theirs.changedAt),
                    agreed: try agreedRevision(uid: theirs.uid, peer: peer))
                switch verdict {
                case .same:
                    try setAgreed(uid: theirs.uid, rev: theirs.rev, peer: peer)
                case .keepOurs:
                    break
                case .takeTheirs:
                    try save(theirs)
                    try setAgreed(uid: theirs.uid, rev: theirs.rev, peer: peer)
                case .keepBoth(let theirsWins):
                    // Both Macs end up with the same two crates: the later change under the crate's
                    // own name, the earlier as a copy named after the Mac that made it.
                    let losing = theirsWins ? ours : theirs
                    let copy = SyncRules.copy(of: losing)
                    if theirsWins { try save(theirs) }
                    if try crateStamp(uid: copy.uid) == nil, try !isBuried(kind: "crate", key: copy.uid) {
                        var kept = losing
                        kept.uid = copy.uid
                        kept.name = copy.name
                        try save(kept)
                    }
                    try setAgreed(uid: theirs.uid, rev: theirsWins ? theirs.rev : ours.rev, peer: peer)
                }
            }
        }
        changed()
    }

    /// Writes a crate as another Mac has it: its name, its version and its tracks in order.
    private func save(_ record: CrateRecord) throws {
        let name = try freeName(record.name, for: record.uid, origin: record.origin)
        if let id = try db.query("SELECT id FROM crates WHERE uid = ?", [.text(record.uid)]).first?.int("id") {
            try db.execute(
                "UPDATE crates SET name = ?, rev = ?, changed_at = ?, origin = ?, editor = ? WHERE id = ?",
                [.text(name), .text(record.rev), .double(record.changedAt), .text(record.origin), .text(record.editor), .int(id)])
            try setMembers(record.tracks, crateID: id)
        } else {
            try db.execute(
                "INSERT INTO crates (name, created_at, uid, rev, changed_at, origin, editor) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(name), .double(record.changedAt), .text(record.uid), .text(record.rev), .double(record.changedAt),
                 .text(record.origin), .text(record.editor)])
            try setMembers(record.tracks, crateID: db.lastInsertRowID)
        }
    }

    /// Crate names are unique on a Mac. Two crates made separately under one name are both
    /// kept: the one arriving takes the name of the Mac it came from as well.
    private func freeName(_ wanted: String, for uid: String, origin: String) throws -> String {
        func taken(_ name: String) throws -> Bool {
            try db.query("SELECT 1 AS found FROM crates WHERE name = ? COLLATE NOCASE AND uid != ?", [.text(name), .text(uid)]).first != nil
        }
        guard try taken(wanted) else { return wanted }
        var candidate = origin.isEmpty ? "\(wanted) (another Mac)" : "\(wanted) (\(origin))"
        var number = 2
        while try taken(candidate) {
            candidate = "\(wanted) \(number)"
            number += 1
        }
        return candidate
    }

    private func setMembers(_ keys: [String], crateID: Int64) throws {
        // Tracks only this Mac can name (not fingerprinted yet) keep their place at the end.
        let localOnly = try db.query(
            """
            SELECT tracks.id AS id FROM crate_tracks JOIN tracks ON tracks.id = crate_tracks.track_id
            WHERE crate_tracks.crate_id = ? AND tracks.content_id IS NULL ORDER BY crate_tracks.position
            """, [.int(crateID)]).compactMap { $0.int("id") }
        try db.execute("DELETE FROM crate_tracks WHERE crate_id = ?", [.int(crateID)])
        var position: Int64 = 0
        var ids: [Int64] = []
        for key in keys {
            if let id = try db.query("SELECT id FROM tracks WHERE content_id = ? ORDER BY id LIMIT 1", [.text(key)]).first?.int("id") { ids.append(id) }
        }
        for id in ids + localOnly {
            position += try db.execute(
                "INSERT OR IGNORE INTO crate_tracks (crate_id, track_id, position) VALUES (?, ?, ?)", [.int(crateID), .int(id), .int(position)]) > 0 ? 1 : 0
        }
    }

    // MARK: - Files arriving

    /// Records that a track known from another Mac now has its file here.
    public func attachFile(contentID: String, path: String) throws {
        guard let track = try track(contentID: contentID) else { return }
        let location = Volumes.location(forPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        try upsertLocal(ScannedFile(
            path: path, volumeUUID: location?.uuid, relativePath: location?.relativePath, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, format: (path as NSString).pathExtension.lowercased(),
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, contentID: contentID))
    }

    /// The tracks of crates marked "keep on this Mac" whose files are not here yet.
    public func tracksToKeepHere() throws -> [Track] {
        try db.query("""
            SELECT DISTINCT tracks.id AS id FROM crates
            JOIN crate_tracks ON crate_tracks.crate_id = crates.id JOIN tracks ON tracks.id = crate_tracks.track_id
            WHERE crates.keep_here = 1 AND tracks.source = 'local' AND tracks.path IS NULL AND tracks.content_id IS NOT NULL
            """).compactMap { try $0.int("id").flatMap { try track(id: $0) } }
    }
}
