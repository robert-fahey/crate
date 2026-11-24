import Foundation

/// A track found on Spotify or TIDAL that is not in the library yet.
public struct StreamingTrack: Equatable, Sendable {
    public var source: TrackSource
    public var uri: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var bpm: Double?
    public var key: String?

    public init(
        source: TrackSource, uri: String, title: String, artist: String, album: String = "", duration: Double,
        bpm: Double? = nil, key: String? = nil
    ) {
        self.source = source
        self.uri = uri
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.bpm = bpm
        self.key = key
    }
}

/// Remembers recent service search results, so a URI the agent picks from a
/// search can be added to the library without searching again.
public final class StreamingCatalog: @unchecked Sendable {
    private var byURI: [String: StreamingTrack] = [:]
    private let lock = NSLock()

    public init() {}

    public func remember(_ tracks: [StreamingTrack]) {
        lock.lock()
        defer { lock.unlock() }
        for track in tracks { byURI[track.uri] = track }
    }

    public func track(uri: String) -> StreamingTrack? {
        lock.lock()
        defer { lock.unlock() }
        return byURI[uri]
    }
}

/// Shared context for tools that work on the library.
public struct LibraryToolContext: Sendable {
    public let store: LibraryStore
    public let scanner: LibraryScanner
    public let catalog: StreamingCatalog

    public init(store: LibraryStore, scanner: LibraryScanner, catalog: StreamingCatalog) {
        self.store = store
        self.scanner = scanner
        self.catalog = catalog
    }

    /// Turns the agent's track references into library ids. A service URI that
    /// is not in the library yet is added from the last search results.
    public func resolve(_ refs: JSON?) throws -> [Int64] {
        guard let items = refs?.arrayValue, !items.isEmpty else {
            throw ToolError("Give at least one track: a library id or a URI from a search result.")
        }
        var ids: [Int64] = []
        for item in items {
            if let id = item.intValue {
                guard try store.track(id: Int64(id)) != nil else { throw ToolError("There is no track with id \(id).") }
                ids.append(Int64(id))
            } else if let uri = item.stringValue {
                if let existing = try store.track(uri: uri) {
                    ids.append(existing.id)
                } else if let found = catalog.track(uri: uri) {
                    ids.append(try store.upsertStreaming(
                        source: found.source, uri: found.uri, title: found.title, artist: found.artist,
                        album: found.album, duration: found.duration, bpm: found.bpm, key: found.key))
                } else {
                    throw ToolError("I don't know the track \(uri). Search for it first, then use the URI from the results.")
                }
            } else {
                throw ToolError("Track references must be library ids (numbers) or URIs (text).")
            }
        }
        return ids
    }

    public func crate(_ args: JSON) throws -> Crate {
        let name = try args.requiredString("crate")
        guard let crate = try store.crate(named: name) else {
            let names = try store.crates().map(\.name)
            throw ToolError(
                "There is no crate called \"\(name)\". Existing crates: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
        }
        return crate
    }
}

extension LibraryStore: @unchecked Sendable {}
extension LibraryScanner: @unchecked Sendable {}

public enum TrackFormat {
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// What the agent sees for a track. Kept small: search results can be long.
    public static func json(_ track: Track) -> JSON {
        var object: [String: JSON] = [
            "id": .number(Double(track.id)),
            "title": .string(track.title),
            "artist": .string(track.artist),
            "duration": .string(duration(track.duration)),
            "source": .string(track.source.rawValue),
        ]
        if !track.album.isEmpty { object["album"] = .string(track.album) }
        if let bpm = track.bpm {
            object["bpm"] = .number((bpm * 10).rounded() / 10)
            if track.bpmSource == .estimated { object["bpm_is_estimate"] = true }
        }
        if let key = track.key {
            object["key"] = .string(key)
            if track.keySource == .estimated { object["key_is_estimate"] = true }
        }
        if !track.notes.isEmpty { object["notes"] = .string(track.notes) }
        if !track.isOnThisMac {
            object["on_this_mac"] = false
            object["note"] = "The file is on another of the user's Macs. Loading it on a deck copies it here, if that Mac is connected."
        } else if track.source == .local, Volumes.resolvedPath(for: track) == nil {
            object["unavailable"] = "file not reachable (drive unplugged or file moved)"
        }
        return .object(object)
    }
}

public enum LibraryTools {
    public static func register(into registry: ToolRegistry, context: LibraryToolContext) {
        let store = context.store

        registry.register(AgentTool(
            name: "library_search",
            description: """
                Search the user's music library (local files plus saved Spotify and TIDAL tracks). All filters are \
                optional and combine. Returns matching tracks with id, title, artist, BPM and Camelot key.
                """,
            properties: [
                "query": Schema.string("Words to find in title, artist, album, notes or file name. Every word must match."),
                "bpm_min": Schema.number("Lowest BPM, inclusive."),
                "bpm_max": Schema.number("Highest BPM, inclusive."),
                "key": Schema.string("Exact key: Camelot (8A) or note name (Am)."),
                "compatible_with_key": Schema.string(
                    "Return tracks that mix harmonically with this key: same key, one step either way on the Camelot wheel, and the relative major/minor."),
                "source": Schema.choice("Only tracks from one source.", TrackSource.allCases.map(\.rawValue)),
                "crate": Schema.string("Only tracks in the crate with this name."),
                "needs_tagging": Schema.boolean("Only tracks missing an artist, BPM or key."),
                "sort": Schema.choice("Sort order. Default: artist.", ["title", "artist", "album", "bpm", "key", "duration", "added"]),
                "limit": Schema.integer("Maximum tracks to return. Default 50, maximum 200."),
            ],
            readOnly: true
        ) { args in
            var query = TrackQuery()
            query.text = args.optionalString("query")
            query.bpmMin = try args.optionalDouble("bpm_min")
            query.bpmMax = try args.optionalDouble("bpm_max")
            if let key = args.optionalString("key") {
                guard let camelot = CamelotKey(parsing: key) else { throw ToolError("\"\(key)\" is not a key I can read.") }
                query.keys = [camelot.description]
            }
            if let key = args.optionalString("compatible_with_key") {
                guard let camelot = CamelotKey(parsing: key) else { throw ToolError("\"\(key)\" is not a key I can read.") }
                query.keys = camelot.compatible.map(\.description)
            }
            if let source = args.optionalString("source") {
                guard let value = TrackSource(rawValue: source) else { throw ToolError("Unknown source \"\(source)\".") }
                query.source = value
            }
            if args.optionalString("crate") != nil { query.crateID = try context.crate(args).id }
            query.needsTagging = args["needs_tagging"]?.boolValue ?? false
            if let sort = args.optionalString("sort") {
                guard let value = TrackSort(rawValue: sort) else { throw ToolError("Unknown sort \"\(sort)\".") }
                query.sort = value
                if value == .added { query.ascending = false }
            }
            let limit = max(1, min(200, try args.optionalInt("limit") ?? 50))
            let all = try store.tracks(query)
            var result: [String: JSON] = [
                "matching": .number(Double(all.count)),
                "tracks": .array(all.prefix(limit).map(TrackFormat.json)),
            ]
            if all.count > limit { result["note"] = .string("Showing the first \(limit). Narrow the search or raise limit.") }
            return .object(result)
        })

        registry.register(AgentTool(
            name: "library_stats",
            description: "Overview of the library: track counts by source, how many have BPM and key, the library folders and the crates.",
            readOnly: true
        ) { _ in
            let stats = try store.stats()
            return [
                "tracks": .number(Double(stats.tracks)),
                "local": .number(Double(stats.local)),
                "spotify": .number(Double(stats.spotify)),
                "tidal": .number(Double(stats.tidal)),
                "with_bpm": .number(Double(stats.withBPM)),
                "with_key": .number(Double(stats.withKey)),
                "needs_tagging": .number(Double(stats.needsTagging)),
                "total_hours": .number((stats.totalDuration / 360).rounded() / 10),
                "folders": .array(try store.folders().map { .string($0.path) }),
                "crates": .array(try store.crates().map { ["name": .string($0.name), "tracks": .number(Double($0.trackCount))] }),
            ]
        })

        registry.register(AgentTool(
            name: "track_update",
            description: """
                Correct a track's details in Crate's database: title, artist, album, BPM, key or notes. The audio \
                file itself is never modified. Use this to fill in missing artists parsed from file names, or to fix a \
                wrong BPM or key.
                """,
            properties: [
                "id": Schema.integer("Library track id."),
                "title": Schema.string("New title."),
                "artist": Schema.string("New artist."),
                "album": Schema.string("New album."),
                "bpm": Schema.number("New BPM, 30 to 300."),
                "key": Schema.string("New key: Camelot (8A) or note name (Am, F# major)."),
                "notes": Schema.string("Free-text notes, replacing any existing notes."),
            ],
            required: ["id"]
        ) { args in
            guard let id = args["id"]?.intValue else { throw ToolError("\"id\" must be a library track id.") }
            var patch = TrackPatch()
            patch.title = args.optionalString("title")
            patch.artist = args.optionalString("artist")
            patch.album = args.optionalString("album")
            patch.notes = args["notes"]?.stringValue
            if let bpm = try args.optionalDouble("bpm") {
                guard (30...300).contains(bpm) else { throw ToolError("BPM must be between 30 and 300.") }
                patch.bpm = .some(bpm)
            }
            if let key = args.optionalString("key") { patch.key = .some(key) }
            try store.update(id: Int64(id), patch)
            guard let track = try store.track(id: Int64(id)) else { throw ToolError("There is no track with id \(id).") }
            return TrackFormat.json(track)
        })

        registry.register(AgentTool(
            name: "library_add_folder",
            description: """
                Add a folder to the library and scan it for music. Files under a minute long are skipped as samples. \
                Use this after find_audio_files has shown a folder holds full tracks. Ask the user before adding a \
                folder they did not mention.
                """,
            properties: ["path": Schema.string("Absolute path of the folder. ~ is expanded.")],
            required: ["path"]
        ) { args in
            let summary = try await context.scanner.scan(folder: try args.requiredString("path"))
            return [
                "result": .string(summary.description),
                "audio_files_found": .number(Double(summary.found)),
                "added": .number(Double(summary.added)),
            ]
        })

        registry.register(AgentTool(
            name: "analyze_tracks",
            description: """
                Estimate BPM and key for local tracks and build their waveforms. Estimates are approximate and never \
                replace values that came from tags or that the user set. With no ids, analyses every local track \
                not yet analysed (up to 40 per call).
                """,
            properties: ["track_ids": ["type": "array", "items": ["type": "integer"], "description": "Library track ids."]]
        ) { args in
            let tracks: [Track]
            if let ids = args["track_ids"]?.arrayValue, !ids.isEmpty {
                tracks = try store.tracks(ids: ids.compactMap { $0.intValue.map(Int64.init) })
            } else {
                tracks = Array(try store.unanalyzedLocalTracks().prefix(40))
            }
            var done: [JSON] = []
            var unreachable = 0
            for track in tracks where track.source == .local {
                if try AudioAnalyzer.analyze(track: track, store: store) == nil {
                    unreachable += 1
                } else if let updated = try store.track(id: track.id) {
                    done.append(TrackFormat.json(updated))
                }
            }
            var result: [String: JSON] = [
                "analysed": .array(done),
                "remaining_unanalysed": .number(Double(try store.unanalyzedLocalTracks().count)),
            ]
            if unreachable > 0 { result["unreachable_files"] = .number(Double(unreachable)) }
            return .object(result)
        })

        registry.register(AgentTool(
            name: "find_audio_files",
            description: """
                Find audio files anywhere on this Mac using Spotlight, including folders that are not in the \
                library. Returns paths grouped by folder, and whether each is already in the library. External \
                drives are only covered if Spotlight indexes them.
                """,
            properties: [
                "name_contains": Schema.string("Text that must appear in the file name."),
                "folder": Schema.string("Only look under this folder."),
                "min_minutes": Schema.number("Only files at least this long. Use 1 or more to leave out samples."),
                "limit": Schema.integer("Maximum files to return. Default 100, maximum 500."),
            ],
            readOnly: true
        ) { args in
            let limit = max(1, min(500, try args.optionalInt("limit") ?? 100))
            let found = try await Spotlight.audioFiles(
                nameContains: args.optionalString("name_contains"), folder: args.optionalString("folder"),
                minimumSeconds: try args.optionalDouble("min_minutes").map { $0 * 60 })
            var folders: [String: [JSON]] = [:]
            for path in found.prefix(limit) {
                let location = Volumes.location(forPath: path)
                let uri = ScannedFile.uri(path: path, volumeUUID: location?.uuid, relativePath: location?.relativePath)
                let inLibrary = (try? store.track(uri: uri)) != nil
                let folder = (path as NSString).deletingLastPathComponent
                var entry: [String: JSON] = ["file": .string((path as NSString).lastPathComponent)]
                if inLibrary { entry["in_library"] = true }
                folders[folder, default: []].append(.object(entry))
            }
            var result: [String: JSON] = [
                "found": .number(Double(found.count)),
                "folders": .object(folders.mapValues(JSON.array)),
            ]
            if found.count > limit { result["note"] = .string("Showing the first \(limit) of \(found.count).") }
            return .object(result)
        })

        // MARK: Crates

        registry.register(AgentTool(
            name: "crate_list", description: "List the crates and how many tracks each holds.", readOnly: true
        ) { _ in
            .array(try store.crates().map { ["name": .string($0.name), "tracks": .number(Double($0.trackCount))] })
        })

        registry.register(AgentTool(
            name: "crate_get", description: "List the tracks in a crate, in order.",
            properties: ["crate": Schema.string("Crate name.")], required: ["crate"], readOnly: true
        ) { args in
            let crate = try context.crate(args)
            var query = TrackQuery()
            query.crateID = crate.id
            return ["crate": .string(crate.name), "tracks": .array(try store.tracks(query).map(TrackFormat.json))]
        })

        registry.register(AgentTool(
            name: "crate_create",
            description: "Create a crate, optionally with tracks already in it. Fails if the name is taken.",
            properties: [
                "name": Schema.string("Name for the new crate."),
                "tracks": Schema.trackRefs("Tracks to put in it, in order."),
            ],
            required: ["name"]
        ) { args in
            // Resolve first so a bad reference does not leave an empty crate behind.
            let ids = args["tracks"]?.arrayValue?.isEmpty == false ? try context.resolve(args["tracks"]) : []
            let crate = try store.createCrate(name: try args.requiredString("name"))
            let added = try store.addToCrate(id: crate.id, trackIDs: ids)
            return ["crate": .string(crate.name), "tracks_added": .number(Double(added))]
        })

        registry.register(AgentTool(
            name: "crate_add_tracks",
            description: "Add tracks to the end of a crate. Tracks already in the crate are left where they are.",
            properties: ["crate": Schema.string("Crate name."), "tracks": Schema.trackRefs("Tracks to add, in order.")],
            required: ["crate", "tracks"]
        ) { args in
            let crate = try context.crate(args)
            let ids = try context.resolve(args["tracks"])
            let added = try store.addToCrate(id: crate.id, trackIDs: ids)
            return [
                "crate": .string(crate.name), "added": .number(Double(added)),
                "already_there": .number(Double(ids.count - added)),
            ]
        })

        registry.register(AgentTool(
            name: "crate_remove_tracks",
            description: "Take tracks out of a crate. The tracks stay in the library.",
            properties: ["crate": Schema.string("Crate name."), "tracks": Schema.trackRefs("Tracks to remove.")],
            required: ["crate", "tracks"]
        ) { args in
            let crate = try context.crate(args)
            let removed = try store.removeFromCrate(id: crate.id, trackIDs: try context.resolve(args["tracks"]))
            return ["crate": .string(crate.name), "removed": .number(Double(removed))]
        })

        registry.register(AgentTool(
            name: "crate_reorder",
            description: """
                Reorder a crate. The listed tracks move to the front in the order given; any not listed follow in \
                their current order. Useful for arranging a set by BPM or key.
                """,
            properties: ["crate": Schema.string("Crate name."), "tracks": Schema.trackRefs("Tracks in their new order.")],
            required: ["crate", "tracks"]
        ) { args in
            let crate = try context.crate(args)
            try store.reorderCrate(id: crate.id, trackIDs: try context.resolve(args["tracks"]))
            var query = TrackQuery()
            query.crateID = crate.id
            return ["crate": .string(crate.name), "tracks": .array(try store.tracks(query).map(TrackFormat.json))]
        })
    }
}
