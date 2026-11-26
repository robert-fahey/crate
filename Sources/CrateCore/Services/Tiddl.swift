import Foundation

/// tiddl, a command-line tool that saves tracks from TIDAL as files, signed in with the user's own
/// TIDAL account. Crate does not include it: it uses the copy the user has installed.
///
/// Downloads go through tiddl's command line. Searching, and working out where a track's file
/// will be, go through tiddl's own Python code, because its command line shows too little of a
/// search to tell one version of a song from another. That part was written against tiddl 3.4.
public struct Tiddl: Sendable {
    /// A track on TIDAL.
    public struct Hit: Equatable, Identifiable, Sendable {
        /// TIDAL's number for the track.
        public var id: String
        public var title: String
        /// "Extended Mix", "2009 Remaster", or empty.
        public var version: String
        public var artist: String
        public var album: String
        public var duration: Double
        public var bpm: Double?
        /// TIDAL's name for the best quality it has: "LOSSLESS", "HI_RES_LOSSLESS", "HIGH", "LOW".
        public var quality: String
        /// False for a track TIDAL lists but will not play.
        public var isAvailable: Bool
        /// Where tiddl puts the file, under the download folder and without its extension.
        /// Known only for a track looked up by its id.
        public var path: String?
        /// Why the track could not be looked up.
        public var problem: String?

        public init(
            id: String, title: String, version: String = "", artist: String = "", album: String = "", duration: Double = 0,
            bpm: Double? = nil, quality: String = "LOSSLESS", isAvailable: Bool = true, path: String? = nil, problem: String? = nil
        ) {
            self.id = id
            self.title = title
            self.version = version
            self.artist = artist
            self.album = album
            self.duration = duration
            self.bpm = bpm
            self.quality = quality
            self.isAvailable = isAvailable
            self.path = path
            self.problem = problem
        }

        /// The title as a DJ needs it: with the version, which is what tells an edit from an extended mix.
        public var fullTitle: String { version.isEmpty ? title : "\(title) (\(version))" }
        public var uri: String { "tidal:track:\(id)" }
        /// "Artist – Title (Version)".
        public var name: String { artist.isEmpty ? fullTitle : "\(artist) – \(fullTitle)" }
        public var isLossless: Bool { quality == "LOSSLESS" || quality == "HI_RES_LOSSLESS" }
    }

    /// What to ask tiddl for. TIDAL gives the best it has up to this.
    public enum Quality: String, CaseIterable, Sendable {
        case normal, high, max

        public var displayName: String {
            switch self {
            case .normal: return "AAC, 320 kbps"
            case .high: return "FLAC, CD quality"
            case .max: return "FLAC, up to 24-bit 192 kHz"
            }
        }
    }

    /// What a line of text asks for.
    public enum Reference: Equatable, Sendable {
        case track(String)
        case album(String)
        case playlist(String)
        /// Words to search for.
        case search(String)
        /// A TIDAL link to something that is not a track or a set of tracks.
        case unsupported(String)
    }

    public var executable: String
    /// The Python that runs tiddl, which is the one that can load its code.
    public var python: String
    /// Folders in which tiddl looks for the programs it uses itself (ffmpeg).
    public var searchPath: String
    /// The Python program that answers searches and lookups. Replaced in tests.
    var helper = Tiddl.helperSource
    /// Added to the environment of everything run. `TIDDL_PATH` moves tiddl's own folder.
    var environment: [String: String] = [:]

    public init(executable: String, python: String, searchPath: String = Tiddl.defaultSearchPath) {
        self.executable = executable
        self.python = python
        self.searchPath = searchPath
    }

    // MARK: Finding it

    /// Where command-line tools a person installs usually are, for an app that Finder started with none of them in its path.
    public static var defaultSearchPath: String {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    /// The installed tiddl, if there is one: in the usual places, or wherever the user's shell finds it.
    public static func find() async -> Tiddl? {
        var searchPath = defaultSearchPath
        var candidates = searchPath.split(separator: ":").map { "\($0)/tiddl" }
        // A login shell knows of anything else the user has set up.
        if let shell = try? await ProcessRunner.run(
            executable: "/bin/zsh", arguments: ["-lc", "print -r -- \"CRATE-PATH=$PATH\"; print -r -- \"CRATE-TIDDL=$(command -v tiddl)\""],
            timeout: 10)
        {
            for line in shell.output.split(separator: "\n") {
                if line.hasPrefix("CRATE-PATH=") { searchPath = line.dropFirst(11) + ":" + searchPath }
                if line.hasPrefix("CRATE-TIDDL=/") { candidates.insert(String(line.dropFirst(12)), at: 0) }
            }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let python = interpreter(ofScript: candidate) else { continue }
            return Tiddl(executable: candidate, python: python, searchPath: searchPath)
        }
        return nil
    }

    /// The Python a script installed by pip, pipx or uv runs under, read from its first lines.
    static func interpreter(ofScript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 2048), as: UTF8.self)
        return interpreter(inScriptHead: head).flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static func interpreter(inScriptHead head: String) -> String? {
        let lines = head.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.hasPrefix("#!") else { return nil }
        let command = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if command.hasPrefix("/"), !command.hasSuffix("/sh"), !command.contains("/env ") { return command }
        // A path too long or too odd for a "#!" line is run through sh: '''exec' "/path/to/python" "$0" "$@"
        for line in lines.dropFirst().prefix(3) where line.contains("exec") {
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            if quoted.count > 1, quoted[1].hasPrefix("/") { return String(quoted[1]) }
        }
        return nil
    }

    /// tiddl's own folder, where it keeps the user's sign-in.
    public var folder: String { environment["TIDDL_PATH"] ?? ProcessInfo.processInfo.environment["TIDDL_PATH"] ?? NSHomeDirectory() + "/.tiddl" }

    /// Whether tiddl has been signed in to TIDAL (`tiddl auth login`).
    public var isSignedIn: Bool {
        guard let data = FileManager.default.contents(atPath: folder + "/auth.json"),
              let auth = try? JSONDecoder().decode(JSON.self, from: data)
        else { return false }
        return !(auth["token"]?.stringValue ?? "").isEmpty
    }

    // MARK: Reading what was typed

    /// What a line names: a TIDAL link, a track's address, or words to search for.
    /// Nil for a line with nothing in it.
    public static func reference(_ line: String) -> Reference? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("tidal:track:") {
            let id = String(text.dropFirst(12))
            return isNumber(id) ? .track(id) : .unsupported(text)
        }
        let lowered = text.lowercased()
        let looksLikeLink = lowered.contains("tidal.com/") || lowered.hasPrefix("tidal://")
        let shorthand = ["track/", "album/", "playlist/"].contains { lowered.hasPrefix($0) } && !text.contains(" ")
        guard looksLikeLink || shorthand else { return .search(query(from: text)) }

        let path = (URLComponents(string: text)?.path ?? text).split(separator: "?").first.map(String.init) ?? text
        let segments = path.split(separator: "/").map(String.init)
        func after(_ kind: String) -> String? {
            guard let index = segments.firstIndex(of: kind), index + 1 < segments.count else { return nil }
            return segments[index + 1]
        }
        // A link to a track on its album page names both; the track is what was meant.
        if let id = after("track"), isNumber(id) { return .track(id) }
        if let id = after("album"), isNumber(id) { return .album(id) }
        if let id = after("playlist"), !id.isEmpty { return .playlist(id) }
        return .unsupported(text)
    }

    private static func isNumber(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }

    /// A line of a tracklist as words to search for: without its number or time, and without the
    /// dash between artist and title, which TIDAL's search reads as part of a name.
    public static func query(from line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        let leading = [
            #"^\[?\(?\d{1,2}:\d{2}(:\d{2})?\)?\]?\s*[-–—.]?\s+"#,  // "[1:02:30] ", "12:45 - "
            #"^\d{1,3}[.)]\s+"#,  // "01. ", "3) "
            #"^\d{1,3}\s+[-–—]\s+(?=.*\s[-–—]\s)"#,  // "01 - Artist - Title", but not "808 State - Pacific"
        ]
        for pattern in leading {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+[-–—]\s+"#, with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The words of a name, for comparing: without case, accents or punctuation.
    static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let ignored: Set<String> = ["the", "and", "feat", "ft", "featuring", "vs"]
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !ignored.contains($0) })
    }

    /// How much of what was asked for is in a track's name: the share of the words asked for
    /// that are in its artist, title or version. TIDAL always answers with something, and for
    /// words it does not know the something has nothing to do with them.
    public static func resemblance(of hit: Hit, to query: String) -> Double {
        let asked = words(query)
        guard !asked.isEmpty else { return 0 }
        let named = words("\(hit.artist) \(hit.title) \(hit.version)")
        return Double(asked.intersection(named).count) / Double(asked.count)
    }

    /// The match to take when nobody is choosing: TIDAL's first that can be downloaded and that
    /// has at least half the words asked for. Nil when nothing looks like it.
    public static func best(of hits: [Hit], for query: String) -> Hit? {
        hits.first { $0.isAvailable && $0.problem == nil && resemblance(of: $0, to: query) >= 0.5 }
    }

    // MARK: Asking TIDAL

    /// Tracks matching some words, best first.
    public func search(_ query: String) async throws -> [Hit] {
        try await ask("search", [String(query.prefix(200))]).hits
    }

    /// Tracks by id, each with where its file goes. One that could not be looked up comes back with a `problem`.
    public func tracks(ids: [String], quality: Quality) async throws -> (hits: [Hit], template: String) {
        guard !ids.isEmpty else { return ([], "") }
        return try await ask("tracks", ids, quality: quality)
    }

    /// The tracks of an album or a playlist, in order.
    public func tracks(of reference: Reference) async throws -> [Hit] {
        switch reference {
        case .album(let id): return try await ask("album", [id]).hits
        case .playlist(let id): return try await ask("playlist", [id]).hits
        case .track(let id): return try await tracks(ids: [id], quality: .high).hits
        case .search(let query): return try await search(query)
        case .unsupported: throw ServiceError("That TIDAL link is not a track, an album or a playlist.")
        }
    }

    private func ask(_ request: String, _ arguments: [String], quality: Quality = .high) async throws -> (hits: [Hit], template: String) {
        let result = try await ProcessRunner.run(
            executable: python, arguments: ["-c", helper, request, quality.rawValue] + arguments,
            environment: environment.merging(["PATH": searchPath]) { given, _ in given }, timeout: 90)
        guard let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("CRATE-TIDDL ") }),
              let answer = try? JSONDecoder().decode(JSON.self, from: Data(line.dropFirst(12).utf8))
        else {
            if result.timedOut { throw ServiceError("TIDAL did not answer. Check the connection and try again.") }
            throw ServiceError("tiddl could not be asked: \(Self.lastLine(of: result.output) ?? "it gave no answer").")
        }
        if let problem = answer["problem"]?.stringValue { throw Self.error(for: problem) }
        return ((answer["tracks"]?.arrayValue ?? []).compactMap(Self.hit), answer["template"]?.stringValue ?? "")
    }

    static func hit(_ item: JSON) -> Hit? {
        guard let id = item["id"]?.stringValue else { return nil }
        let bpm = item["bpm"]?.doubleValue.flatMap { $0 >= 30 && $0 <= 300 ? $0 : nil }
        return Hit(
            id: id, title: item["title"]?.stringValue ?? "", version: item["version"]?.stringValue ?? "",
            artist: item["artist"]?.stringValue ?? "", album: item["album"]?.stringValue ?? "",
            duration: item["duration"]?.doubleValue ?? 0, bpm: bpm, quality: item["quality"]?.stringValue ?? "",
            isAvailable: item["available"]?.boolValue ?? true, path: item["path"]?.stringValue,
            problem: item["problem"]?.stringValue.map { Self.error(for: $0).message })
    }

    /// tiddl's and TIDAL's own words for what went wrong, put so that the user knows what to do.
    static func error(for problem: String) -> ServiceError {
        let lowered = problem.lowercased()
        if lowered.contains("tiddl auth login") || lowered.contains("token is missing") {
            return ServiceError("tiddl is not signed in to TIDAL. In Terminal, run “tiddl auth login”, then try again.")
        }
        if lowered.contains("no module named") {
            return ServiceError("This copy of tiddl is not one Crate can work with (\(problem)). Crate was written against tiddl 3.4.")
        }
        if lowered.contains("404") || lowered.contains("not found") { return ServiceError("TIDAL has no such track.") }
        if lowered.contains("401") || lowered.contains("unauthorized") {
            return ServiceError("TIDAL turned tiddl away. In Terminal, run “tiddl auth refresh”, or “tiddl auth logout” and “tiddl auth login”.")
        }
        return ServiceError("TIDAL said: \(problem)")
    }

    private static func lastLine(of output: String) -> String? {
        output.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { String($0.prefix(300)) }
    }

    // MARK: Downloading

    /// The command line that downloads tracks, for running and for showing to the user.
    /// - Parameter template: how tiddl names the files, as `tracks(ids:quality:)` reported it,
    ///   so that the files are where Crate was told they would be.
    public static func downloadArguments(ids: [String], folder: String, quality: Quality, template: String) -> [String] {
        // tiddl looks for files it already has in its "scan path", which is its own default folder unless told.
        var arguments = ["download", "-q", quality.rawValue, "-p", folder, "--scan-path", folder]
        if !template.isEmpty { arguments += ["-o", template] }
        return arguments + ["url"] + ids.map { "track/\($0)" }
    }

    /// A command line as it would be typed, for showing.
    public static func commandLine(_ arguments: [String]) -> String {
        (["tiddl"] + arguments).map { argument in
            argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=~".contains($0) }) && !argument.isEmpty
                ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Runs the download and returns what tiddl printed. Whether each file arrived is for the caller to look.
    @discardableResult
    public func download(ids: [String], to folder: String, quality: Quality, template: String) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: executable, arguments: Self.downloadArguments(ids: ids, folder: folder, quality: quality, template: template),
            // Wide, so that tiddl does not fold its lines; plain, so that they can be read.
            environment: environment.merging(["PATH": searchPath, "COLUMNS": "400", "NO_COLOR": "1", "TERM": "dumb"]) { given, _ in given },
            timeout: 120 + 240 * Double(ids.count))
        if result.timedOut { throw ServiceError("The download took too long and was stopped.") }
        return result.output
    }

    /// What tiddl said went wrong with a download, from what it printed: its lines that start "Error",
    /// "API Error" or "Can't stream".
    static func problem(inOutput output: String) -> String? {
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.contains("tiddl auth login") || line.contains("Token is missing") { return error(for: line).message }
            if line.hasPrefix("Can't stream") { return "TIDAL does not let this track be downloaded." }
            if line.contains("ffmpeg is not installed") { return "tiddl needs ffmpeg, which is not installed. In Terminal: brew install ffmpeg" }
            for prefix in ["API Error:", "Error:", "Error "] where line.hasPrefix(prefix) {
                return "tiddl said: " + String(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).prefix(240))
            }
        }
        return nil
    }

    // MARK: The helper

    /// Run by tiddl's own Python as `python -c <this> <request> <quality> <arguments…>`. It prints
    /// one line, "CRATE-TIDDL " and JSON, so that anything else tiddl prints is not mistaken for the answer.
    static let helperSource = #"""
        import json
        import sys


        def answer(value):
            sys.stdout.write("CRATE-TIDDL " + json.dumps(value) + "\n")
            sys.stdout.flush()


        try:
            from rich.console import Console
            from tiddl.cli.config import CONFIG
            from tiddl.cli.ctx import ContextObject
            from tiddl.core.utils.format import format_template

            mode, quality, arguments = sys.argv[1], sys.argv[2], sys.argv[3:]

            # tiddl's stock file name leaves the version out, so "Song" and "Song (Extended Mix)" from one
            # album would be one file. A template the user has set themselves is left alone.
            template = CONFIG.templates.track
            if template == "{album.artist}/{album.title}/{item.title}":
                template = "{album.artist}/{album.title}/{item.title_version}"

            api = ContextObject(
                api_omit_cache=not CONFIG.enable_cache, debug_path=None, console=Console(stderr=True)
            ).api

            def hit(track, album=None):
                names = [a.name for a in (track.artists or []) if a.type == "MAIN"] or [
                    a.name for a in (track.artists or [])
                ]
                if not names and track.artist:
                    names = [track.artist.name]
                found = {
                    "id": str(track.id),
                    "title": track.title,
                    "version": track.version or "",
                    "artist": ", ".join(names),
                    "album": track.album.title if track.album else "",
                    "duration": track.duration or 0,
                    "bpm": track.bpm or 0,
                    "quality": track.audioQuality or "",
                    "available": bool(track.allowStreaming),
                }
                if album is not None:
                    wanted = quality.upper()
                    if quality == "max" and "HIRES_LOSSLESS" not in track.mediaMetadata.tags:
                        wanted = "HIGH"
                    found["path"] = format_template(
                        template=template, item=track, album=album, quality=wanted, with_asterisk_ext=False
                    )
                return found

            def pages(fetch):
                offset = 0
                while True:
                    page = fetch(offset)
                    for entry in page.items:
                        if entry.type == "track":
                            yield entry.item
                    offset += page.limit
                    if offset >= page.totalNumberOfItems or not page.items:
                        break

            if mode == "search":
                found = api.get_search(query=arguments[0])
                answer({"template": template, "tracks": [hit(t) for t in found.tracks.items]})
            elif mode == "tracks":
                tracks = []
                for identifier in arguments:
                    try:
                        track = api.get_track(identifier)
                        tracks.append(hit(track, api.get_album(track.album.id)))
                    except Exception as problem:
                        tracks.append({"id": str(identifier), "problem": str(problem) or type(problem).__name__})
                answer({"template": template, "tracks": tracks})
            elif mode == "album":
                items = pages(lambda offset: api.get_album_items(arguments[0], offset=offset))
                answer({"template": template, "tracks": [hit(t) for t in items]})
            elif mode == "playlist":
                items = pages(lambda offset: api.get_playlist_items(arguments[0], offset=offset))
                answer({"template": template, "tracks": [hit(t) for t in items]})
            else:
                answer({"problem": "unknown request " + mode})
        except BaseException as problem:
            answer({"problem": str(problem) or type(problem).__name__})
        """#
}
