import Foundation

/// Downloads tracks from TIDAL with tiddl and brings the files into the library.
///
/// A track tiddl has already downloaded is not downloaded again: its file is found and used.
public final class TrackGrabber: @unchecked Sendable {
    /// One track to get.
    public struct Request: Sendable {
        public var hit: Tiddl.Hit
        /// A streaming track in the library that the file stands in for. The file takes its place
        /// in every crate, takes its notes, and the streaming track is removed.
        public var replacing: Int64?

        public init(_ hit: Tiddl.Hit, replacing: Int64? = nil) {
            self.hit = hit
            self.replacing = replacing
        }
    }

    public enum Result: Equatable, Sendable {
        /// Downloaded now.
        case downloaded(Track)
        /// The file was already there.
        case alreadyHad(Track)
        case failed(String)

        public var track: Track? {
            switch self {
            case .downloaded(let track), .alreadyHad(let track): return track
            case .failed: return nil
            }
        }
    }

    public struct Outcome: Sendable {
        public var hit: Tiddl.Hit
        public var result: Result
    }

    public struct Options: Sendable {
        /// Where the files go. tiddl makes folders by artist and album under it.
        public var folder: String
        public var quality: Tiddl.Quality
        /// A crate to add each track to, in the order asked for.
        public var crateID: Int64?

        public init(folder: String, quality: Tiddl.Quality = .high, crateID: Int64? = nil) {
            self.folder = folder
            self.quality = quality
            self.crateID = crateID
        }
    }

    /// tiddl's own default, and where the Cursor skill that uses tiddl puts files.
    public static var defaultFolder: String { NSHomeDirectory() + "/Music/tiddl" }

    private let store: LibraryStore
    private let scanner: LibraryScanner

    public init(store: LibraryStore, scanner: LibraryScanner) {
        self.store = store
        self.scanner = scanner
    }

    /// The file tiddl would have made for a track, if it is there. tiddl saves FLAC when TIDAL
    /// gives it lossless sound and M4A otherwise.
    static func file(for hit: Tiddl.Hit, in folder: String) -> String? {
        guard let path = hit.path, !path.isEmpty else { return nil }
        let base = (folder as NSString).appendingPathComponent(path)
        return [".flac", ".m4a"].map { base + $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Gets each track in turn.
    /// - Parameter progress: called before each track with its place in the list, and after it with what happened.
    public func grab(
        _ requests: [Request], with tiddl: Tiddl, options: Options,
        progress: (@Sendable (Int, Outcome?) async -> Void)? = nil
    ) async -> [Outcome] {
        let folder = URL(fileURLWithPath: (options.folder as NSString).expandingTildeInPath).standardizedFileURL.path
        var outcomes: [Outcome] = []
        func failAll(_ message: String) async -> [Outcome] {
            for (index, request) in requests.enumerated() {
                await progress?(index, Outcome(hit: request.hit, result: .failed(message)))
            }
            return requests.map { Outcome(hit: $0.hit, result: .failed(message)) }
        }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            return await failAll("The folder \(folder) could not be made: \(error.localizedDescription)")
        }

        // Looked up by id, a track comes with where its file goes, which is how the file is found afterwards.
        let looked: (hits: [Tiddl.Hit], template: String)
        do {
            looked = try await tiddl.tracks(ids: requests.map(\.hit.id), quality: options.quality)
        } catch {
            return await failAll(error.localizedDescription)
        }
        let known = Dictionary(looked.hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (index, request) in requests.enumerated() {
            await progress?(index, nil)
            let hit = known[request.hit.id] ?? request.hit
            let result = await grab(hit, with: tiddl, folder: folder, options: options, template: looked.template)
            if let track = result.track {
                if let crate = options.crateID, request.replacing == nil { _ = try? store.addToCrate(id: crate, trackIDs: [track.id]) }
                if let old = request.replacing { stand(track, inFor: old, crate: options.crateID) }
            }
            let outcome = Outcome(hit: hit, result: result)
            outcomes.append(outcome)
            await progress?(index, outcome)
        }
        return outcomes
    }

    private func grab(_ hit: Tiddl.Hit, with tiddl: Tiddl, folder: String, options: Options, template: String) async -> Result {
        if let problem = hit.problem { return .failed(problem) }
        guard hit.isAvailable else { return .failed("TIDAL does not let this track be downloaded.") }
        guard hit.path != nil else { return .failed("tiddl did not say where it would put the file.") }
        do {
            if let file = Self.file(for: hit, in: folder) {
                guard let track = try await scanner.add(file: file, root: folder) else {
                    return .failed("The file is there but could not be read: \(file)")
                }
                return .alreadyHad(track)
            }
            let output = try await tiddl.download(ids: [hit.id], to: folder, quality: options.quality, template: template)
            guard let file = Self.file(for: hit, in: folder) else {
                return .failed(Tiddl.problem(inOutput: output) ?? "tiddl finished without making the file.")
            }
            guard let track = try await scanner.add(file: file, root: folder) else {
                return .failed("The download is not a file Crate can read: \(file)")
            }
            return .downloaded(track)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The file takes a streaming track's place: in its crates, with its notes.
    private func stand(_ track: Track, inFor old: Int64, crate: Int64?) {
        guard let was = try? store.track(id: old), was.id != track.id else { return }
        _ = try? store.replaceInCrates(track: was.id, with: track.id)
        if let crate { _ = try? store.addToCrate(id: crate, trackIDs: [track.id]) }
        if !was.notes.isEmpty, track.notes.isEmpty {
            var patch = TrackPatch()
            patch.notes = was.notes
            try? store.update(id: track.id, patch)
        }
        // Only a streaming track gives way. A file of the user's own is never removed for a download.
        if was.source != .local { try? store.deleteTracks(ids: [was.id]) }
    }
}

// MARK: - Agent tools

public enum GrabTools {
    /// - Parameters:
    ///   - tiddl: finds the installed tiddl, or nil when there is none.
    ///   - options: where downloads go and at what quality, as set in Settings.
    ///   - approve: asks the user before anything is downloaded. Returning false means nothing is.
    public static func register(
        into registry: ToolRegistry, context: LibraryToolContext, grabber: TrackGrabber,
        tiddl: @escaping @Sendable () async -> Tiddl?, options: @escaping @Sendable () async -> TrackGrabber.Options,
        approve: @escaping @Sendable (CommandRequest) async -> Bool,
        imported: @escaping @Sendable () async -> Void = {}
    ) {
        @Sendable func installed() async throws -> Tiddl {
            guard let found = await tiddl() else {
                throw ToolError("tiddl is not installed on this Mac, so tracks cannot be downloaded. The user can install it with: uv tool install tiddl (or pipx install tiddl), then sign in with: tiddl auth login")
            }
            return found
        }
        @Sendable func json(_ hit: Tiddl.Hit) -> JSON {
            var object: [String: JSON] = [
                "uri": .string(hit.uri), "title": .string(hit.fullTitle), "artist": .string(hit.artist),
                "duration": .string(TrackFormat.duration(hit.duration)),
            ]
            if !hit.album.isEmpty { object["album"] = .string(hit.album) }
            if let bpm = hit.bpm { object["bpm"] = .number(bpm) }
            if !hit.isLossless { object["quality"] = .string("lossy only") }
            if !hit.isAvailable { object["unavailable"] = true }
            return .object(object)
        }

        registry.register(AgentTool(
            name: "tiddl_search",
            description: """
                Search TIDAL for tracks that can be downloaded with tiddl_grab. Results are in TIDAL's order, best \
                match first, and usually include several versions of one song: read the title (the version is in \
                brackets), the album and the duration to pick the one meant. A DJ usually wants the extended or \
                original mix, not a radio edit, a live recording or a remaster of the wrong cut.
                """,
            properties: ["query": Schema.string("Artist and title. Leave out dashes and track numbers.")],
            required: ["query"], readOnly: true
        ) { args in
            let found = try await installed().search(Tiddl.query(from: try args.requiredString("query")))
            return .array(found.map(json))
        })

        registry.register(AgentTool(
            name: "tiddl_grab",
            description: """
                Download tracks from TIDAL as files (FLAC where TIDAL has it) with the user's tiddl, and add them \
                to the library as local tracks that can be loaded on the decks. The user is asked to approve the \
                download first. Each item of `tracks` is a `uri` from tiddl_search or tidal_search \
                ("tidal:track:123"), a TIDAL track link, or, when you have not searched, artist and title as text, \
                which takes TIDAL's top match. Prefer searching first: the top match is often the wrong version. \
                A track already downloaded is not downloaded again. Check each result's title and duration \
                against what was asked for, and tell the user about any that look like the wrong version.
                """,
            properties: [
                "tracks": [
                    "type": "array", "items": ["type": "string"],
                    "description": "What to download, in order: track URIs, TIDAL track links, or artist-and-title text.",
                ],
                "crate": Schema.string("A crate to add the downloaded tracks to. It must exist already."),
            ],
            required: ["tracks"]
        ) { args in
            let wanted = (args["tracks"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !wanted.isEmpty else { throw ToolError("Give at least one track to download.") }
            guard wanted.count <= 50 else { throw ToolError("That is \(wanted.count) tracks. Download at most 50 at a time.") }
            let crate = args.optionalString("crate") == nil ? nil : try context.crate(args)
            let tiddl = try await installed()
            var chosen = await options()
            chosen.crateID = crate?.id

            // Settle what each item is before asking, so the user approves named tracks, not search words.
            var requests: [TrackGrabber.Request] = []
            var notFound: [JSON] = []
            for item in wanted {
                switch Tiddl.reference(item) {
                case .track(let id):
                    let streaming = try context.store.track(uri: "tidal:track:\(id)")
                    requests.append(.init(Tiddl.Hit(id: id, title: streaming?.title ?? item, artist: streaming?.artist ?? ""), replacing: streaming?.id))
                case .search(let query):
                    let found = try await tiddl.search(query)
                    if let top = Tiddl.best(of: found, for: query) {
                        requests.append(.init(top))
                    } else if found.isEmpty {
                        notFound.append(["asked_for": .string(item), "problem": "TIDAL has nothing matching this."])
                    } else {
                        // TIDAL answers with something even for words it does not know.
                        notFound.append([
                            "asked_for": .string(item),
                            "problem": "Nothing on TIDAL looks like this, so nothing was downloaded for it. Its nearest matches are listed: if one is right, ask for it by its uri.",
                            "nearest": .array(found.prefix(3).map(json)),
                        ])
                    }
                default:
                    notFound.append(["asked_for": .string(item), "problem": "Only single tracks can be downloaded: give a track URI, a track link, or artist and title."])
                }
            }
            guard !requests.isEmpty else { return ["downloaded": [], "problems": .array(notFound)] }

            let looked = try await tiddl.tracks(ids: requests.map(\.hit.id), quality: chosen.quality)
            let known = Dictionary(looked.hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            requests = requests.map { .init(known[$0.hit.id] ?? $0.hit, replacing: $0.replacing) }
            let names = requests.map(\.hit.name)
            let command = Tiddl.commandLine(Tiddl.downloadArguments(
                ids: requests.map(\.hit.id), folder: chosen.folder, quality: chosen.quality, template: looked.template))
            let reason = "Download \(names.count == 1 ? "1 track" : "\(names.count) tracks") from TIDAL: " + names.joined(separator: "; ")
            guard await approve(CommandRequest(command: command, workingDirectory: chosen.folder, reason: reason, isDownload: true)) else {
                throw ToolError("The user declined the download. Do not retry it; ask what they would prefer.")
            }

            let outcomes = await grabber.grab(requests, with: tiddl, options: chosen)
            var done: [JSON] = [], problems = notFound
            for outcome in outcomes {
                switch outcome.result {
                case .downloaded(let track), .alreadyHad(let track):
                    var object = TrackFormat.json(track).objectValue ?? [:]
                    if case .alreadyHad = outcome.result { object["already_downloaded"] = true }
                    done.append(.object(object))
                case .failed(let message):
                    problems.append(["asked_for": .string(outcome.hit.name), "problem": .string(message)])
                }
            }
            // New files have no waveform, beat grid or key yet.
            if !done.isEmpty { await imported() }
            var response: [String: JSON] = ["downloaded": .array(done), "folder": .string(chosen.folder)]
            if !problems.isEmpty { response["problems"] = .array(problems) }
            if let crate { response["added_to_crate"] = .string(crate.name) }
            return .object(response)
        })
    }
}
