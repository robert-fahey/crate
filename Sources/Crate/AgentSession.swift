import AppKit
import CrateCore
import Foundation
import Observation

struct ToolActivity: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var server: String?
    var summary: String
    var state: State

    enum State: String, Codable { case running, done, failed }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant, notice }
    /// A reply is a sequence of text and tool steps, kept in the order they happened.
    enum Part: Identifiable, Equatable, Codable {
        case text(id: Int, String)
        case tool(ToolActivity)

        var id: String {
            switch self {
            case .text(let id, _): return "text-\(id)"
            case .tool(let tool): return "tool-\(tool.id)"
            }
        }
    }

    var id = UUID()
    var role: Role
    var parts: [Part] = []
    /// When it was said; shown between messages from different days.
    var date = Date()

    init(role: Role, text: String) {
        self.role = role
        if !text.isEmpty { parts = [.text(id: 0, text)] }
    }

    var text: String {
        parts.compactMap { if case .text(_, let text) = $0 { return text } else { return nil } }.joined(separator: "\n\n")
    }

    var tools: [ToolActivity] {
        parts.compactMap { if case .tool(let tool) = $0 { return tool } else { return nil } }
    }

    var isEmpty: Bool { parts.isEmpty }

    /// Adds streamed text to the current paragraph, or starts a new one after a tool step.
    mutating func append(text: String) {
        if case .text(let id, let existing)? = parts.last {
            parts[parts.count - 1] = .text(id: id, existing + text)
        } else {
            parts.append(.text(id: parts.count, text))
        }
    }

    mutating func updateTool(id: String, _ change: (inout ToolActivity) -> Void) {
        for index in parts.indices {
            if case .tool(var tool) = parts[index], tool.id == id {
                change(&tool)
                parts[index] = .tool(tool)
            }
        }
    }

    mutating func failRunningTools() {
        for tool in tools where tool.state == .running { updateTool(id: tool.id) { $0.state = .failed } }
    }
}

/// The conversation with the agent, and the lifecycle of the sidecar behind it.
@MainActor
@Observable
final class AgentSession {
    enum Phase: Equatable {
        case starting
        case signedOut
        case signingIn
        case connecting
        case ready
        case working
        /// The agent cannot run; the text says why and what to do.
        case unavailable(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var messages: [ChatMessage] = []
    /// How many messages of the conversation are kept between launches.
    static let historyLimit = 400
    private(set) var models: [AgentModel] = []
    private(set) var accountEmail: String?
    /// True when running against the offline stand-in rather than Cursor.
    private(set) var isOffline = false
    private(set) var sdkVersion = ""
    /// A command waiting for the user's decision.
    private(set) var pendingCommand: CommandRequest?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let registry: ToolRegistry
    @ObservationIgnored private var bridge: AgentBridge?
    @ObservationIgnored private var commandDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var commandWaiters: [(CommandRequest, CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var log = ""

    init(store: LibraryStore, registry: ToolRegistry) {
        self.store = store
        self.registry = registry
        loadHistory()
    }

    // MARK: History

    /// The conversation is kept with the library, so it is still there after a restart.
    private func loadHistory() {
        guard let saved = store.setting("agent.history")?.data(using: .utf8),
              var history = try? JSONDecoder().decode([ChatMessage].self, from: saved)
        else { return }
        // Anything still "running" when the app last closed never finished.
        for index in history.indices { history[index].failRunningTools() }
        messages = history.filter { !$0.isEmpty }
    }

    private func saveHistory() {
        let recent = messages.suffix(Self.historyLimit).filter { !$0.isEmpty }
        if let data = try? JSONEncoder().encode(Array(recent)), let text = String(data: data, encoding: .utf8) {
            store.setSetting("agent.history", text)
        }
    }

    /// What the user has asked before, oldest first, for recalling with the arrow keys.
    var pastRequests: [String] {
        var seen = Set<String>()
        return messages.reversed().filter { $0.role == .user }.map(\.text)
            .filter { seen.insert($0).inserted }.reversed()
    }

    /// Empties the history on screen. The agent's own memory of the conversation is separate; "New Conversation" resets that.
    func clearHistory() {
        guard phase != .working else { return }
        messages.removeAll()
        saveHistory()
    }

    var selectedModel: String {
        // Only an explicit choice is saved; otherwise this is Claude Opus 4.6 when offered.
        get { AgentSessionConfig.resolveModel(saved: store.setting("agent.model"), available: models.map(\.id)) }
        set {
            store.setSetting("agent.model", newValue)
            store.setSetting("agent.id", nil)  // a different model starts a fresh conversation
            if phase == .ready { startSession() }
        }
    }

    /// How the DJ likes mixes done, in their own words; part of the agent's instructions.
    var mixingStyle: String {
        get { store.setting("agent.mixingStyle") ?? AgentInstructions.defaultMixingStyle }
        set {
            store.setSetting("agent.mixingStyle", newValue)
            reloadSession()
        }
    }

    var mcpServersText: String {
        get { store.setting("agent.mcpServers") ?? "{}" }
        set { store.setSetting("agent.mcpServers", newValue) }
    }

    /// Parses the MCP server settings. Accepts either the bare map or a `.cursor/mcp.json`-style wrapper.
    static func parseMCPServers(_ text: String) throws -> JSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let parsed = try JSON.parse(trimmed)
        let servers = parsed["mcpServers"] ?? parsed
        guard let object = servers.objectValue else { throw ToolError("Expected a JSON object of servers.") }
        for (name, server) in object {
            guard server["command"]?.stringValue != nil || server["url"]?.stringValue != nil else {
                throw ToolError("Server \"\(name)\" needs either a \"command\" or a \"url\".")
            }
        }
        return servers
    }

    // MARK: Lifecycle

    func start() {
        guard bridge == nil else { return }
        guard let launch = AgentLaunch.locate() else {
            phase = .unavailable("The agent component is missing from this build. Rebuild the app with ./build.sh.")
            return
        }
        let bridge = AgentBridge(launch: launch, registry: registry)
        bridge.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        bridge.onLog = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.log = String((self.log + text).suffix(4000))
            }
        }
        do {
            try bridge.start()
            self.bridge = bridge
            phase = .starting
        } catch {
            phase = .unavailable("The agent could not be started: \(error.localizedDescription)")
        }
    }

    func stop() {
        bridge?.stop()
        bridge = nil
    }

    /// Called as the app quits. A reply left running would leave the saved conversation
    /// marked as busy, so stop it and give the agent a moment to record that.
    func quit() {
        guard phase == .working else { return stop() }
        cancel()
        Thread.sleep(forTimeInterval: 0.5)
        stop()
    }

    func signIn() {
        phase = .signingIn
        bridge?.login()
    }

    func signOut() {
        bridge?.logout()
        store.setSetting("agent.id", nil)
        messages.removeAll()
    }

    func newConversation() {
        guard phase == .ready else { return }
        store.setSetting("agent.id", nil)
        // The history stays on screen; a line marks where the agent's memory starts again.
        notice("New conversation: the agent no longer remembers what is above this line.")
        saveHistory()
        startSession()
    }

    /// Restarts the session so changed settings (library folders, MCP servers) take effect.
    func reloadSession() {
        if phase == .ready { startSession() }
    }

    private func workspace() throws -> String {
        let folder = try LibraryStore.defaultURL().deletingLastPathComponent().appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AgentInstructions.text(mixingStyle: mixingStyle)
            .write(to: folder.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        return folder.path
    }

    private func startSession() {
        guard let bridge else { return }
        do {
            let servers = (try? Self.parseMCPServers(mcpServersText)) ?? [:]
            let folders = ((try? store.folders()) ?? []).map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
            let model = selectedModel
            phase = .connecting
            bridge.startSession(AgentSessionConfig(
                model: model, workingDirectory: try workspace(), libraryFolders: folders, mcpServers: servers,
                resumeID: store.setting("agent.id")))
        } catch {
            phase = .unavailable("Could not prepare the agent's working folder: \(error.localizedDescription)")
        }
    }

    // MARK: Conversation

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, !trimmed.isEmpty, let bridge else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        saveHistory()  // so the request is kept even if the app quits before the reply
        messages.append(ChatMessage(role: .assistant, text: ""))
        phase = .working
        bridge.chat(trimmed)
    }

    func cancel() {
        guard phase == .working else { return }
        bridge?.cancel()
        resolveCommand(approved: false)
    }

    private func updateReply(_ change: (inout ChatMessage) -> Void) {
        guard let last = messages.indices.last, messages[last].role == .assistant else { return }
        change(&messages[last])
    }

    /// Sends a request that the app itself raised (the auto DJ asking for the next mix).
    /// It shows as a note, not as something the user typed. Returns false if the agent is busy or not available.
    @discardableResult
    func sendAutomatic(_ text: String, label: String) -> Bool {
        guard phase == .ready, let bridge else { return false }
        notice(label)
        messages.append(ChatMessage(role: .assistant, text: ""))
        phase = .working
        bridge.chat(text)
        return true
    }

    private func notice(_ text: String) {
        messages.append(ChatMessage(role: .notice, text: text))
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .ready(let sdk, let offline):
            sdkVersion = sdk
            isOffline = offline
            bridge?.requestAuthStatus()

        case .authStatus(let loggedIn, let email):
            accountEmail = email
            if loggedIn {
                bridge?.requestModels()
            } else {
                phase = .signedOut
            }

        case .loginURL(let url):
            // The SDK normally opens the browser itself; this is the fallback.
            if let link = URL(string: url), !isOffline { NSWorkspace.shared.open(link) }

        case .models(let list):
            models = list
            startSession()

        case .sessionStarted(let agentID, let resumed):
            store.setSetting("agent.id", agentID)
            // A session that could not be resumed after a restart has lost its memory of the history on screen.
            if !resumed, messages.last.map({ $0.role != .notice }) == true {
                notice("New conversation: the agent no longer remembers what is above this line.")
            }
            phase = .ready

        case .sessionReplaced(let agentID):
            store.setSetting("agent.id", agentID)
            // The reply that is about to arrive is written into the last message, so the note goes above it.
            let note = ChatMessage(
                role: .notice, text: "The earlier conversation was cut off mid-reply and could not be continued, so this is a new one.")
            if let last = messages.indices.last, messages[last].role == .assistant {
                messages.insert(note, at: last)
            } else {
                messages.append(note)
            }

        case .textDelta(let text):
            updateReply { $0.append(text: text) }

        case .thinkingDelta:
            break

        case .toolStarted(let callID, let name, let server, let args):
            updateReply {
                $0.parts.append(.tool(ToolActivity(
                    id: callID, name: name, server: server, summary: Self.summary(name: name, args: args), state: .running)))
            }

        case .toolFinished(let callID, _, let ok):
            updateReply { $0.updateTool(id: callID) { $0.state = ok ? .done : .failed } }

        case .turnEnded(let status, let error):
            updateReply { $0.failRunningTools() }
            if status == "cancelled" {
                notice("Stopped.")
            } else if status == "error" {
                notice("The agent hit a problem: \(error ?? "unknown error").")
            }
            if let last = messages.last, last.role == .assistant, last.isEmpty {
                messages.removeLast()
            }
            saveHistory()
            if phase == .working { phase = .ready }

        case .error(let code, let message):
            switch phase {
            case .signingIn:
                phase = .signedOut
                notice("Sign-in did not complete: \(message)")
            case .starting, .connecting:
                if code == "AuthenticationError" {
                    phase = .signedOut
                } else {
                    phase = .unavailable(message)
                }
            case .working:
                notice(message)
                phase = .ready
            default:
                notice(message)
            }

        case .exited(let expected):
            bridge = nil
            resolveCommand(approved: false)
            if !expected {
                let detail = log.split(separator: "\n").last.map(String.init) ?? "no details"
                phase = .unavailable("The agent process stopped unexpectedly (\(detail)).")
            }
        }
    }

    /// A few words on what a tool call is doing, for the chip in the transcript.
    static func summary(name: String, args: JSON) -> String {
        func arg(_ key: String) -> String? { args[key]?.stringValue }
        switch name {
        case "library_search":
            var parts: [String] = []
            if let query = arg("query") { parts.append("“\(query)”") }
            if let low = args["bpm_min"]?.doubleValue, let high = args["bpm_max"]?.doubleValue {
                parts.append("\(Int(low))–\(Int(high)) BPM")
            }
            if let key = arg("compatible_with_key") ?? arg("key") { parts.append(key) }
            if let crate = arg("crate") { parts.append("in \(crate)") }
            return parts.isEmpty ? "Searching the library" : "Searching: " + parts.joined(separator: ", ")
        case "library_stats": return "Looking at the library"
        case "track_update": return "Editing a track"
        case "library_add_folder": return "Scanning \(arg("path").map { ($0 as NSString).lastPathComponent } ?? "a folder")"
        case "analyze_tracks": return "Analysing BPM and key"
        case "find_audio_files": return "Looking for audio files" + (arg("name_contains").map { " named “\($0)”" } ?? "")
        case "crate_list": return "Listing crates"
        case "crate_get": return "Reading crate \(arg("crate") ?? "")"
        case "crate_create": return "Creating crate \(arg("name") ?? "")"
        case "crate_add_tracks": return "Adding to \(arg("crate") ?? "a crate")"
        case "crate_remove_tracks": return "Removing from \(arg("crate") ?? "a crate")"
        case "crate_reorder": return "Reordering \(arg("crate") ?? "a crate")"
        case "player_play": return "Starting playback"
        case "player_queue_add": return "Adding to the queue"
        case "player_pause": return "Pausing"
        case "player_resume": return "Resuming"
        case "player_next": return "Skipping"
        case "player_seek": return "Seeking"
        case "player_status": return "Checking what is playing"
        case "spotify_search": return "Searching Spotify" + (arg("query").map { " for “\($0)”" } ?? "")
        case "tidal_search": return "Searching TIDAL" + (arg("query").map { " for “\($0)”" } ?? "")
        case "run_command": return "Command: \(arg("command") ?? "")"
        case "glob", "ls", "read", "grep": return "Looking at files"
        case "webSearch", "webFetch": return "Searching the web"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Command approval

    /// Called by the run_command tool. Suspends until the user decides.
    func requestApproval(_ request: CommandRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            if pendingCommand == nil {
                pendingCommand = request
                commandDecision = continuation
            } else {
                commandWaiters.append((request, continuation))
            }
        }
    }

    func resolveCommand(approved: Bool) {
        commandDecision?.resume(returning: approved)
        commandDecision = nil
        pendingCommand = nil
        if approved {
            if !commandWaiters.isEmpty {
                let (request, continuation) = commandWaiters.removeFirst()
                pendingCommand = request
                commandDecision = continuation
            }
        } else {
            // Declining or cancelling drops anything queued behind it too.
            for (_, continuation) in commandWaiters { continuation.resume(returning: false) }
            commandWaiters.removeAll()
        }
    }
}
