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
    /// The conversation on screen. It follows the sidebar: a crate's own while that crate is shown, the library's otherwise.
    private(set) var conversation = ConversationID.library
    /// What the conversation on screen is called: the crate's name, or "Library".
    private(set) var title = "Library"
    /// The conversation a reply is being written into. The DJ may have moved on to another one meanwhile.
    private(set) var working: ConversationID?
    /// Every conversation looked at since launch, each read from the library the first time it is shown.
    private var histories: [ConversationID: [ChatMessage]] = [:]
    private var titles: [ConversationID: String] = [.library: "Library"]
    /// How many messages of a conversation are kept between launches.
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
    /// The conversation the agent process is holding: the one it remembers. It holds one at a time, and is
    /// handed another only when something is said in it, so looking through crates costs nothing.
    @ObservationIgnored private var live: ConversationID?
    /// The conversation the agent process has been asked to take up and has not yet confirmed.
    @ObservationIgnored private var switching: ConversationID?

    init(store: LibraryStore, registry: ToolRegistry) {
        self.store = store
        self.registry = registry
        histories[.library] = savedHistory(of: .library)
    }

    // MARK: Conversations

    /// The messages of the conversation on screen.
    var messages: [ChatMessage] { histories[conversation] ?? [] }

    /// A reply is being written into the conversation on screen.
    var isWorkingHere: Bool { phase == .working && working == conversation }

    /// The name of the other conversation the agent is busy in, if it is busy in one.
    var busyElsewhere: String? {
        guard phase == .working, let working, working != conversation else { return nil }
        return titles[working] ?? "another conversation"
    }

    /// What the agent is doing this moment, in a few words; nil when it is doing nothing.
    var activity: String? {
        guard phase == .working, let working, let reply = histories[working]?.last, reply.role == .assistant else { return nil }
        switch reply.parts.last {
        case .tool(let tool) where tool.state == .running: return tool.server.map { "\($0): " + tool.summary } ?? tool.summary
        case .text: return "Writing a reply"
        default: return "Thinking"
        }
    }

    /// Puts a conversation on screen. Nothing is sent to the agent until something is said in it.
    func show(_ id: ConversationID, title: String) {
        if titles[id] != title { titles[id] = title }
        if self.title != title { self.title = title }
        guard id != conversation else { return }
        if histories[id] == nil { histories[id] = savedHistory(of: id) }
        conversation = id
    }

    /// Forgets a conversation altogether, as when its crate is deleted.
    func forget(_ id: ConversationID) {
        guard id != working, !id.isLibrary else { return }
        histories[id] = nil
        titles[id] = nil
        store.setSetting(id.historySetting, nil)
        store.setSetting(id.agentSetting, nil)
        if live == id { live = nil }
    }

    // MARK: History

    /// Conversations are kept with the library, so they are still there after a restart.
    private func savedHistory(of id: ConversationID) -> [ChatMessage] {
        guard let saved = store.setting(id.historySetting)?.data(using: .utf8),
              var history = try? JSONDecoder().decode([ChatMessage].self, from: saved)
        else { return [] }
        // Anything still "running" when the app last closed never finished.
        for index in history.indices { history[index].failRunningTools() }
        return history.filter { !$0.isEmpty }
    }

    private func saveHistory(of id: ConversationID) {
        let recent = (histories[id] ?? []).suffix(Self.historyLimit).filter { !$0.isEmpty }
        if recent.isEmpty { return store.setSetting(id.historySetting, nil) }
        if let data = try? JSONEncoder().encode(Array(recent)), let text = String(data: data, encoding: .utf8) {
            store.setSetting(id.historySetting, text)
        }
    }

    /// What the user has asked before, oldest first, for recalling with the arrow keys.
    var pastRequests: [String] {
        var seen = Set<String>()
        return messages.reversed().filter { $0.role == .user }.map(\.text)
            .filter { seen.insert($0).inserted }.reversed()
    }

    /// Empties the history on screen. The agent's own memory of the conversation is separate; "Start Over" resets that.
    func clearHistory() {
        guard !isWorkingHere else { return }
        histories[conversation] = []
        saveHistory(of: conversation)
    }

    var selectedModel: String {
        // Only an explicit choice is saved; otherwise this is Claude Opus 4.6 when offered.
        get { AgentSessionConfig.resolveModel(saved: store.setting("agent.model"), available: models.map(\.id)) }
        set {
            store.setSetting("agent.model", newValue)
            store.removeSettings(prefix: "agent.id")  // a different model starts every conversation afresh
            live = nil
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
        store.removeSettings(prefix: "agent.id")
        live = nil
        for id in histories.keys { histories[id] = [] }
    }

    /// Starts the conversation on screen again from nothing, as far as the agent's memory goes.
    func newConversation() {
        guard phase == .ready else { return }
        store.setSetting(conversation.agentSetting, nil)
        // The history stays on screen; a line marks where the agent's memory starts again.
        notice(Self.forgotten, in: conversation)
        saveHistory(of: conversation)
        startSession()
    }

    private static let forgotten = "Starting over: the agent no longer remembers what is above this line."

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

    /// Readies the agent with the conversation on screen, at launch and after a change of settings.
    private func startSession() {
        phase = .connecting
        hand(conversation)
    }

    /// Has the agent process take up a conversation: resume it if it has been spoken in before, begin it if not.
    /// A request sent straight after this waits in the agent process until the conversation is ready.
    @discardableResult
    private func hand(_ id: ConversationID) -> Bool {
        guard let bridge else { return false }
        do {
            let servers = (try? Self.parseMCPServers(mcpServersText)) ?? [:]
            let folders = ((try? store.folders()) ?? []).map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
            let model = selectedModel
            switching = id
            bridge.startSession(AgentSessionConfig(
                model: model, workingDirectory: try workspace(), libraryFolders: folders, mcpServers: servers,
                resumeID: store.setting(id.agentSetting)))
            return true
        } catch {
            switching = nil
            phase = .unavailable("Could not prepare the agent's working folder: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Conversation

    /// Says something in the conversation on screen.
    /// - Parameter context: what the DJ is looking at, for the agent alone; it is not shown or kept.
    func send(_ text: String, context: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, !trimmed.isEmpty, let bridge else { return }
        let id = conversation
        histories[id, default: []].append(ChatMessage(role: .user, text: trimmed))
        saveHistory(of: id)  // so the request is kept even if the app quits before the reply
        guard begin(in: id) else { return }
        bridge.chat(context + trimmed)
    }

    /// Opens a reply in a conversation, handing the conversation to the agent process first if it holds another.
    /// False if the agent could not be readied.
    private func begin(in id: ConversationID) -> Bool {
        if live != id, !hand(id) { return false }
        histories[id, default: []].append(ChatMessage(role: .assistant, text: ""))
        working = id
        phase = .working
        return true
    }

    func cancel() {
        guard phase == .working else { return }
        bridge?.cancel()
        resolveCommand(approved: false)
    }

    private func updateReply(_ change: (inout ChatMessage) -> Void) {
        guard let working, let last = histories[working]?.indices.last, histories[working]?[last].role == .assistant else { return }
        change(&histories[working]![last])
    }

    /// Sends a request that the app itself raised (the auto DJ asking for the next mix).
    /// It shows as a note, not as something the user typed. Returns false if the agent is busy or not available.
    /// It goes into the conversation the agent already holds (the one last spoken in), wherever the DJ is looking.
    @discardableResult
    func sendAutomatic(_ text: String, label: String) -> Bool {
        guard phase == .ready, let bridge else { return false }
        let id = live ?? conversation
        notice(label, in: id)
        guard begin(in: id) else { return false }
        bridge.chat(text)
        return true
    }

    /// A line of the app's own in a conversation: by default the one being worked in, or else the one on screen.
    private func notice(_ text: String, in id: ConversationID? = nil) {
        histories[id ?? working ?? conversation, default: []].append(ChatMessage(role: .notice, text: text))
    }

    /// Notes in a conversation that the agent has lost its memory of what is above. The note goes above a
    /// request that is waiting for its reply, since that request is the first thing the agent will remember.
    private func noteMemoryLost(in id: ConversationID) {
        var history = histories[id] ?? []
        var end = history.count
        if working == id, phase == .working {
            if end > 0, history[end - 1].role == .assistant { end -= 1 }
            if end > 0, history[end - 1].role != .assistant { end -= 1 }
        }
        guard end > 0, history[end - 1].role != .notice else { return }
        history.insert(ChatMessage(role: .notice, text: Self.forgotten), at: end)
        histories[id] = history
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
            let id = switching ?? conversation
            switching = nil
            live = id
            store.setSetting(id.agentSetting, agentID)
            // A conversation that could not be resumed has lost the agent's memory of the history on screen.
            if !resumed { noteMemoryLost(in: id) }
            if phase == .connecting { phase = .ready }

        case .sessionReplaced(let agentID):
            let id = working ?? live ?? conversation
            store.setSetting(id.agentSetting, agentID)
            // The reply that is about to arrive is written into the last message, so the note goes above it.
            let note = ChatMessage(
                role: .notice, text: "The earlier conversation was cut off mid-reply and could not be continued, so this is a new one.")
            var history = histories[id] ?? []
            if let last = history.indices.last, history[last].role == .assistant {
                history.insert(note, at: last)
            } else {
                history.append(note)
            }
            histories[id] = history

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
            if let working {
                if let last = histories[working]?.last, last.role == .assistant, last.isEmpty {
                    histories[working]?.removeLast()
                }
                saveHistory(of: working)
            }
            working = nil
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
                // The conversation could not be taken up, so the agent process holds none.
                if switching != nil {
                    switching = nil
                    live = nil
                }
                if let working {
                    if let last = histories[working]?.last, last.role == .assistant, last.isEmpty {
                        histories[working]?.removeLast()
                    }
                    notice(message, in: working)
                    saveHistory(of: working)
                }
                working = nil
                phase = .ready
            default:
                // The request that was waiting behind a conversation that could not be taken up; that has been reported.
                if code != "no_session" { notice(message) }
            }

        case .exited(let expected):
            bridge = nil
            live = nil
            switching = nil
            working = nil
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
