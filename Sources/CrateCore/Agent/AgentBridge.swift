import Foundation

/// How to start the agent sidecar.
public struct AgentLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// Finds the sidecar. In order: an explicit override, the single-file
    /// binary inside the app bundle, then the same binary in a source checkout.
    public static func locate(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentLaunch? {
        var candidates: [String] = []
        if let override = environment["CRATE_AGENT_BIN"] { candidates.append(override) }
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("agent/crate-agent").path)
        }
        // `swift run` from the repository: .build/<config>/Crate -> ../../../agent/build/crate-agent
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var folder = executable.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(folder.appendingPathComponent("agent/build/crate-agent").path)
            folder = folder.deletingLastPathComponent()
        }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return AgentLaunch(executable: found)
    }
}

public struct AgentModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
}

public enum AgentEvent: Equatable, Sendable {
    case ready(sdk: String, offline: Bool)
    case authStatus(loggedIn: Bool, email: String?)
    case loginURL(String)
    case models([AgentModel])
    case sessionStarted(agentID: String, resumed: Bool)
    /// The saved conversation was stuck (cut off mid-turn), so a new one took its place for this message.
    case sessionReplaced(agentID: String)
    case textDelta(String)
    case thinkingDelta(String)
    case toolStarted(callID: String, name: String, server: String?, args: JSON)
    case toolFinished(callID: String, name: String, ok: Bool)
    case turnEnded(status: String, error: String?)
    case error(code: String, message: String)
    /// The sidecar process ended. `expected` is true after `stop()`.
    case exited(expected: Bool)
}

public struct AgentSessionConfig: Sendable {
    public var model: String
    public var workingDirectory: String
    public var libraryFolders: [String]
    public var mcpServers: JSON
    public var resumeID: String?
    /// Built-in Cursor tools the agent may use. No shell, edit, write or delete:
    /// commands go through the confirm-gated run_command tool instead.
    public var builtinTools: [String] = AgentSessionConfig.defaultBuiltinTools

    public static let defaultBuiltinTools = ["read", "glob", "ls", "grep", "webSearch", "webFetch", "mcp"]

    /// The model Crate's agent is written and tested for: Claude Opus 4.6.
    public static let preferredModel = "claude-opus-4-6"
    /// Cursor's "Auto" entry, used when the preferred model is not offered.
    public static let automaticModel = "default"

    /// The model to run: the user's saved choice while Cursor still offers it,
    /// otherwise the preferred model, then Cursor's automatic choice.
    public static func resolveModel(saved: String?, available: [String]) -> String {
        if let saved, !saved.isEmpty, available.contains(saved) { return saved }
        if available.contains(preferredModel) || available.isEmpty { return preferredModel }
        if available.contains(automaticModel) { return automaticModel }
        return available[0]
    }

    public init(model: String, workingDirectory: String, libraryFolders: [String], mcpServers: JSON = [:], resumeID: String? = nil) {
        self.model = model
        self.workingDirectory = workingDirectory
        self.libraryFolders = libraryFolders
        self.mcpServers = mcpServers
        self.resumeID = resumeID
    }
}

/// Owns the sidecar process and speaks its JSON-lines protocol. Tool calls
/// from the agent are answered from the `ToolRegistry`; everything else is
/// reported through `onEvent`.
public final class AgentBridge: @unchecked Sendable {
    private let launch: AgentLaunch
    private let registry: ToolRegistry
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopping = false
    private var counter = 0
    private let lock = NSLock()

    /// Called on a background queue.
    public var onEvent: (@Sendable (AgentEvent) -> Void)?
    /// Lines the sidecar writes to stderr, for diagnostics.
    public var onLog: (@Sendable (String) -> Void)?

    public init(launch: AgentLaunch, registry: ToolRegistry) {
        self.launch = launch
        self.registry = registry
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launch.environment { environment[key] = value }
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.receive(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.onLog?(String(decoding: chunk, as: UTF8.self))
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let expected = self.stopping
            self.process = nil
            self.input = nil
            self.lock.unlock()
            self.onEvent?(.exited(expected: expected))
        }

        try process.run()
        lock.lock()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.stopping = false
        lock.unlock()
    }

    /// Ends the sidecar. Closing its stdin is the shutdown signal.
    public func stop() {
        lock.lock()
        stopping = true
        let input = self.input
        let process = self.process
        lock.unlock()
        try? input?.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    // MARK: Outgoing

    private func nextID() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "h\(counter)"
    }

    @discardableResult
    private func send(_ type: String, _ fields: [String: JSON] = [:], withID: Bool = true) -> String {
        let id = nextID()
        var object = fields
        object["type"] = .string(type)
        if withID { object["id"] = .string(id) }
        let line = JSON.object(object).encoded() + "\n"
        lock.lock()
        let input = self.input
        lock.unlock()
        do {
            try input?.write(contentsOf: Data(line.utf8))
        } catch {
            onEvent?(.error(code: "write_failed", message: "The agent process is not accepting input."))
        }
        return id
    }

    public func requestAuthStatus() { send("auth.status") }
    public func login() { send("auth.login") }
    public func logout() { send("auth.logout") }
    public func requestModels() { send("models.list") }

    public func startSession(_ config: AgentSessionConfig) {
        var fields: [String: JSON] = [
            "model": .string(config.model),
            "cwd": .string(config.workingDirectory),
            "dirs": .array(config.libraryFolders.map(JSON.string)),
            "tools": registry.specs(),
            "mcpServers": config.mcpServers,
            "builtinTools": .array(config.builtinTools.map(JSON.string)),
        ]
        if let resumeID = config.resumeID { fields["resumeId"] = .string(resumeID) }
        send("session.start", fields)
    }

    public func chat(_ text: String) { send("chat.send", ["text": .string(text)]) }
    public func cancel() { send("chat.cancel", withID: false) }

    // MARK: Incoming

    private func receive(_ chunk: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let message = try? JSONDecoder().decode(JSON.self, from: line) else {
                onLog?("Unreadable line from the agent process: \(String(decoding: line.prefix(200), as: UTF8.self))")
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        func text(_ key: String) -> String { message[key]?.stringValue ?? "" }
        switch text("type") {
        case "ready":
            onEvent?(.ready(sdk: text("sdk"), offline: message["fake"]?.boolValue ?? false))
        case "auth.status.result":
            onEvent?(.authStatus(loggedIn: message["loggedIn"]?.boolValue ?? false, email: message["email"]?.stringValue))
        case "auth.login.url":
            onEvent?(.loginURL(text("url")))
        case "models.list.result":
            let models = (message["models"]?.arrayValue ?? []).compactMap { item -> AgentModel? in
                guard let id = item["id"]?.stringValue else { return nil }
                return AgentModel(id: id, name: item["name"]?.stringValue ?? id)
            }
            onEvent?(.models(models))
        case "session.replaced":
            onEvent?(.sessionReplaced(agentID: text("agentId")))
        case "session.started":
            onEvent?(.sessionStarted(agentID: text("agentId"), resumed: message["resumed"]?.boolValue ?? false))
        case "text.delta":
            onEvent?(.textDelta(text("text")))
        case "thinking.delta":
            onEvent?(.thinkingDelta(text("text")))
        case "tool.started":
            onEvent?(.toolStarted(
                callID: text("callId"), name: text("name"), server: message["server"]?.stringValue,
                args: message["args"] ?? .null))
        case "tool.finished":
            onEvent?(.toolFinished(callID: text("callId"), name: text("name"), ok: message["ok"]?.boolValue ?? true))
        case "tool.call":
            let callID = text("callId"), name = text("name"), args = message["args"] ?? .object([:])
            Task { [weak self] in
                guard let self else { return }
                let result = await self.registry.call(name: name, args: args)
                self.send("tool.result", ["callId": .string(callID), "ok": .bool(result.ok), "content": result.content], withID: false)
            }
        case "turn.ended":
            onEvent?(.turnEnded(status: text("status"), error: message["error"]?.stringValue))
        case "error":
            onEvent?(.error(code: text("code"), message: text("message")))
        default:
            break
        }
    }
}

public enum AgentInstructions {
    /// Written to AGENTS.md in the agent's working folder, which the Cursor SDK loads as project rules.
    /// A starting point for the "Mixing style" setting, which the DJ edits.
    public static let defaultMixingStyle = """
        - Bold, simple moves over fiddly ones.
        - One bass line at a time: swap the bass rather than letting two fight.
        - Keep effects on the beat, and cut echo tails dead when the new track drops.
        - In the spirit of Larry Levan and Ron Hardy: bass kills, tape stops and hard cuts are welcome when they suit the records.
        - Keep the energy up; do not open a set with a long, flat blend.
        """

    public static func text(mixingStyle: String) -> String {
        let style = mixingStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        return style.isEmpty ? base : base + "\n\n## How this DJ likes to mix\n\n" + style + "\n"
    }

    static let base = """
        # Crate

        You are the assistant inside Crate, a Mac app for DJs to dig through, organise, play and mix music on two \
        decks. You are not working on a code project. The person you are talking to is the DJ using the app.

        ## What you can do

        Use the `custom-user-tools` MCP tools for everything music-related:

        - **Library**: `library_search`, `library_stats`, `track_update`, `analyze_tracks`, `library_add_folder`.
        - **Finding files on this Mac**: `find_audio_files` (Spotlight), plus your file tools (`glob`, `ls`, `read`) \
        for looking inside folders.
        - **Crates** (the DJ's playlists): `crate_list`, `crate_get`, `crate_create`, `crate_add_tracks`, \
        `crate_remove_tracks`, `crate_reorder`.
        - **Playback**: `player_play`, `player_queue_add`, `player_pause`, `player_resume`, `player_next`, \
        `player_seek`, `player_status`.
        - **Decks and mixing**: `deck_status`, `deck_load`, `deck_control`, `track_structure`, `mix_transition`, \
        `mix_cancel`, `automix_start`, `automix_stop`, `mix_record`.
        - **Streaming services**: `spotify_search`, `tidal_search`. Results carry a `uri`; pass that URI to crate or \
        player tools to use the track. Local files play inside Crate; Spotify and TIDAL tracks play through their own apps.
        - **Commands**: `run_command` runs a shell command only after the user approves it in the app.

        ## Mixing

        - There are two decks, A and B. You are too slow to ride a fader in time, so you never mix by hand: you \
        choose the next track, where the mix starts and its style, and `mix_transition` carries it out on the beat.
        - Before mixing, look at `deck_status`. To place a mix well, look at `track_structure` for the playing \
        track (to pick where to leave it) and for the next one (to pick where to start it).
        - Choose tracks that sit together: tempos within about 6% of each other, and compatible keys when the two \
        will overlap for long. A 32-beat `bass_swap` starting on a phrase boundary is the safe default. Use `cut`, \
        `echo_out` or `tape_stop` when tempos are far apart or the moment calls for something bolder.
        - Start mixes where the outgoing track thins out (an outro or breakdown) and bring the new track in from \
        a phrase start, usually its intro.
        - Most of this library is disco played by live drummers. Beat grids, bar lines and phrase positions are \
        Crate's estimates and can be off; if the DJ says a mix sounded out of time, believe them.
        - `player_play` cuts straight to a track. Use it only when the DJ wants something played now, not mixed.
        - For "DJ this crate" or "play me a set", order the tracks sensibly (tempo and key flow, energy building) \
        and call `automix_start`. You will then be asked for each mix shortly before it is due.

        ## How to behave

        - Act on clear requests straight away ("make a crate of everything from 118 to 124 BPM") and say briefly \
        what you did. Ask first only when a request is ambiguous or would add folders the user did not mention.
        - Keys are in Camelot notation (8A, 9B). Harmonically compatible means the same key, one step either way on \
        the wheel, or the relative major/minor; `library_search` has `compatible_with_key` for this.
        - BPM and key values marked as estimates come from Crate's own analysis and can be wrong, including being \
        half or double the real tempo. Say so when it matters.
        - `track_update` edits Crate's database only. You cannot and must not modify, move, rename or delete audio files.
        - Many local files have no tags; artist and title are guessed from file names. Fixing those guesses with \
        `track_update` is useful work when the user asks you to tidy the library.
        - If a tool reports a file as unavailable, the drive it lives on is probably unplugged. Tell the user.
        - Keep replies short. List tracks as "Artist – Title (BPM, key)". Do not use tables.
        """
}
