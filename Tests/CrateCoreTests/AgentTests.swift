import XCTest
@testable import CrateCore

final class StubPlayer: PlayerControl, @unchecked Sendable {
    var played: [[Int64]] = []
    var queued: [[Int64]] = []
    func play(trackIDs: [Int64]) async throws -> JSON { played.append(trackIDs); return ["state": "playing"] }
    func enqueue(trackIDs: [Int64]) async throws -> JSON { queued.append(trackIDs); return ["queued": .number(Double(trackIDs.count))] }
    func pause() async throws -> JSON { ["state": "paused"] }
    func resume() async throws -> JSON { ["state": "playing"] }
    func next() async throws -> JSON { ["state": "playing"] }
    func seek(toSeconds seconds: Double) async throws -> JSON { ["position": .number(seconds)] }
    func status() async -> JSON { ["state": "stopped"] }
}

final class AgentToolTests: XCTestCase {
    private var store: LibraryStore!
    private var registry: ToolRegistry!
    private var context: LibraryToolContext!
    private var player: StubPlayer!

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
        registry = ToolRegistry()
        context = LibraryToolContext(store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog())
        player = StubPlayer()
        LibraryTools.register(into: registry, context: context)
        PlayerTools.register(into: registry, context: context, player: player)
    }

    @discardableResult
    private func add(_ artist: String, _ title: String, bpm: Double? = nil, key: String? = nil) throws -> Int64 {
        try store.upsertLocal(ScannedFile(
            path: "/music/\(artist) - \(title).flac", title: title, artist: artist, duration: 400, bpm: bpm, key: key,
            format: "flac"))
    }

    private func call(_ name: String, _ args: JSON = [:]) async -> (ok: Bool, content: JSON) {
        await registry.call(name: name, args: args)
    }

    func testEveryToolHasAnObjectSchemaAndADescription() {
        let names = registry.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for tool in registry.all {
            XCTAssertEqual(tool.inputSchema["type"], "object", tool.name)
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            for required in tool.inputSchema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(tool.inputSchema["properties"]?[required.stringValue ?? ""], "\(tool.name) requires an undeclared argument")
            }
        }
        // The instructions must not promise tools that do not exist.
        for name in ["library_search", "crate_reorder", "player_queue_add", "find_audio_files", "analyze_tracks"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testSearchByBPMRangeAndCompatibleKey() async throws {
        try add("A", "in range minor", bpm: 120, key: "Am")
        try add("B", "in range relative major", bpm: 123.44, key: "C")
        try add("C", "wrong key", bpm: 121, key: "F#m")
        try add("D", "too fast", bpm: 130, key: "Am")

        let result = await call("library_search", ["bpm_min": 118, "bpm_max": "124", "compatible_with_key": "8A", "sort": "bpm"])
        XCTAssertTrue(result.ok)
        let tracks = result.content["tracks"]?.arrayValue ?? []
        XCTAssertEqual(tracks.map { $0["title"]?.stringValue }, ["in range minor", "in range relative major"])
        XCTAssertEqual(tracks[1]["bpm"], 123.4)
        XCTAssertEqual(tracks[1]["key"], "8B")
        XCTAssertEqual(result.content["matching"], 2)

        let bad = await call("library_search", ["key": "Q flat"])
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.content.stringValue?.contains("Q flat") == true)
    }

    func testSearchLimitsLongResultsAndSaysSo() async throws {
        for index in 0..<60 { try add("Artist", "Track \(index)") }
        let result = await call("library_search", ["limit": 10])
        XCTAssertEqual(result.content["tracks"]?.arrayValue?.count, 10)
        XCTAssertEqual(result.content["matching"], 60)
        XCTAssertNotNil(result.content["note"])
    }

    func testCrateWorkflowWithLibraryIdsAndServiceURIs() async throws {
        let local = try add("Change", "Paradise", bpm: 118)
        context.catalog.remember([
            StreamingTrack(source: .spotify, uri: "spotify:track:abc", title: "Hit and Run", artist: "Loleatta Holloway", duration: 420),
        ])

        var result = await call("crate_create", ["name": "Boogie", "tracks": [.number(Double(local)), "spotify:track:abc"]])
        XCTAssertTrue(result.ok, "\(result.content)")
        XCTAssertEqual(result.content["tracks_added"], 2)
        XCTAssertEqual(try store.stats().spotify, 1, "the Spotify track was saved to the library on first use")

        result = await call("crate_get", ["crate": "boogie"])
        XCTAssertEqual(result.content["tracks"]?.arrayValue?.map { $0["title"]?.stringValue }, ["Paradise", "Hit and Run"])

        result = await call("crate_reorder", ["crate": "Boogie", "tracks": ["spotify:track:abc"]])
        XCTAssertEqual(result.content["tracks"]?.arrayValue?.first?["title"], "Hit and Run")

        result = await call("crate_add_tracks", ["crate": "Boogie", "tracks": [.number(Double(local))]])
        XCTAssertEqual(result.content["already_there"], 1)

        result = await call("crate_remove_tracks", ["crate": "Boogie", "tracks": [.number(Double(local))]])
        XCTAssertEqual(result.content["removed"], 1)
        XCTAssertEqual(try store.stats().tracks, 2, "removing from a crate leaves the track in the library")
    }

    func testBadReferencesAreExplainedAndLeaveNothingHalfDone() async throws {
        var result = await call("crate_create", ["name": "Empty", "tracks": ["spotify:track:never-searched"]])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.content.stringValue?.contains("Search for it first") == true)
        XCTAssertTrue(try store.crates().isEmpty, "a failed create must not leave a crate behind")

        result = await call("crate_add_tracks", ["crate": "Nope", "tracks": [1]])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.content.stringValue?.contains("Existing crates: none") == true)

        result = await call("player_play", ["tracks": [999]])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(player.played.isEmpty)

        result = await call("no_such_tool")
        XCTAssertFalse(result.ok)
    }

    func testTrackUpdateEditsTheDatabaseAndValidates() async throws {
        let id = try add("", "ackermann sweat")
        var result = await call("track_update", ["id": .number(Double(id)), "artist": "Ackermann", "title": "Sweat", "bpm": 124, "key": "Am"])
        XCTAssertTrue(result.ok, "\(result.content)")
        let track = try XCTUnwrap(store.track(id: id))
        XCTAssertEqual([track.artist, track.title, track.key], ["Ackermann", "Sweat", "8A"])
        XCTAssertEqual(track.bpmSource, .manual)

        result = await call("track_update", ["id": .number(Double(id)), "bpm": 900])
        XCTAssertFalse(result.ok)
        result = await call("track_update", ["id": .number(Double(id)), "key": "H#"])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(try store.track(id: id)?.bpm, 124)
    }

    func testPlayerToolsPassResolvedTracksThrough() async throws {
        let a = try add("A", "one"), b = try add("B", "two")
        _ = await call("player_play", ["tracks": [.number(Double(b)), .number(Double(a))]])
        _ = await call("player_queue_add", ["tracks": [.number(Double(a))]])
        XCTAssertEqual(player.played, [[b, a]])
        XCTAssertEqual(player.queued, [[a]])
        let seek = await call("player_seek", ["seconds": -3])
        XCTAssertFalse(seek.ok)
    }

    func testSpotlightQueryEscapesWhatPeopleType() {
        XCTAssertEqual(
            Spotlight.query(nameContains: nil, minimumSeconds: nil), "kMDItemContentTypeTree == \"public.audio\"")
        XCTAssertEqual(
            Spotlight.query(nameContains: "12\" mix*", minimumSeconds: 60),
            "kMDItemContentTypeTree == \"public.audio\" && kMDItemFSName == \"*12\\\" mix\\**\"cd && kMDItemDurationSeconds >= 60")
    }
}

final class CommandToolTests: XCTestCase {
    private func registry(approve: Bool, seen: @escaping @Sendable (CommandRequest) -> Void = { _ in }) -> ToolRegistry {
        let registry = ToolRegistry()
        CommandTool.register(into: registry) { request in
            seen(request)
            return approve
        }
        return registry
    }

    func testADeclinedCommandNeverRuns() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("crate-declined-\(UUID().uuidString)")
        let result = await registry(approve: false).call(
            name: "run_command", args: ["command": .string("touch '\(marker.path)'"), "reason": "test"])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.content.stringValue?.contains("declined") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAnApprovedCommandReturnsOutputAndExitCode() async throws {
        let shown = Box()
        let result = await registry(approve: true) { shown.request = $0 }.call(
            name: "run_command",
            args: ["command": "echo out; echo err >&2; exit 3", "reason": "checking", "working_directory": "/tmp"])
        XCTAssertTrue(result.ok, "\(result.content)")
        XCTAssertEqual(result.content["exit_code"], 3)
        XCTAssertEqual(result.content["output"]?.stringValue?.split(separator: "\n").sorted(), ["err", "out"])
        XCTAssertEqual(shown.request?.command, "echo out; echo err >&2; exit 3")
        XCTAssertEqual(shown.request?.reason, "checking")
        XCTAssertEqual(shown.request?.workingDirectory, "/tmp")
    }

    func testAReasonIsRequiredAndTheFolderMustExist() async {
        var result = await registry(approve: true).call(name: "run_command", args: ["command": "true"])
        XCTAssertFalse(result.ok)
        result = await registry(approve: true).call(
            name: "run_command", args: ["command": "true", "reason": "x", "working_directory": "/no/such/folder"])
        XCTAssertFalse(result.ok)
    }

    func testTheAgentRunsOnOpus46UnlessAnotherOfferedModelWasChosen() {
        let offered = ["default", "claude-opus-5-5", "claude-opus-4-6", "gpt-5.5"]
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: nil, available: offered), "claude-opus-4-6")
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: "", available: offered), "claude-opus-4-6")
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: "gpt-5.5", available: offered), "gpt-5.5")
        // A saved model Cursor no longer offers falls back to the preferred one.
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: "retired", available: offered), "claude-opus-4-6")
        // Without Opus 4.6 on the account: Cursor's automatic choice, then whatever is first.
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: nil, available: ["gpt-5.5", "default"]), "default")
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: nil, available: ["offline"]), "offline")
        XCTAssertEqual(AgentSessionConfig.resolveModel(saved: nil, available: []), "claude-opus-4-6")
    }

    func testARunawayProcessIsStoppedAtTheTimeout() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testABackgroundChildHoldingThePipeDoesNotHangTheCall() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", "echo started; (sleep 20 &)"], timeout: 30)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testOutputBeyondTheLimitIsCutAndFlagged() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", "head -c 50000 /dev/zero | tr '\\0' 'x'"], timeout: 10, outputLimit: 1000)
        XCTAssertEqual(result.output.count, 1000)
        XCTAssertTrue(result.truncated)
    }

    private final class Box: @unchecked Sendable { var request: CommandRequest? }
}

/// Runs the real sidecar binary (built by build.sh) with the offline SDK stand-in.
final class AgentBridgeTests: XCTestCase {
    private func sidecar() throws -> AgentLaunch {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = repo.appendingPathComponent("agent/build/crate-agent").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary), "Run ./build.sh first to build the sidecar.")
        return AgentLaunch(executable: binary, environment: ["CRATE_FAKE_SDK": "1"])
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentEvent] = []
        func add(_ event: AgentEvent) { lock.lock(); events.append(event); lock.unlock() }
        var all: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }

        func wait(seconds: Double = 10, until condition: ([AgentEvent]) -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition(all) { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
    }

    func testAChatTurnCallsARealToolAndStreamsTheAnswer() async throws {
        let store = try LibraryStore(path: ":memory:")
        try store.upsertLocal(ScannedFile(path: "/music/x.flac", title: "Paradise", artist: "Change", duration: 300, bpm: 118, format: "flac"))
        let registry = ToolRegistry()
        LibraryTools.register(into: registry, context: LibraryToolContext(
            store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog()))

        let bridge = AgentBridge(launch: try sidecar(), registry: registry)
        let recorder = Recorder()
        bridge.onEvent = { recorder.add($0) }
        try bridge.start()
        defer { bridge.stop() }

        bridge.requestModels()
        bridge.startSession(AgentSessionConfig(model: "offline", workingDirectory: NSTemporaryDirectory(), libraryFolders: []))
        bridge.chat("/tool library_search {\"query\":\"paradise\"}")

        let ended = await recorder.wait { $0.contains { if case .turnEnded = $0 { return true } else { return false } } }
        XCTAssertTrue(ended, "no turn.ended; got \(recorder.all)")
        let events = recorder.all
        XCTAssertTrue(events.contains(.ready(sdk: "fake", offline: true)))
        XCTAssertTrue(events.contains(.models([AgentModel(id: "offline", name: "Offline test agent (no AI)")])))
        XCTAssertTrue(events.contains { if case .sessionStarted = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .toolStarted(_, "library_search", nil, _) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .toolFinished(_, "library_search", true) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains(.turnEnded(status: "finished", error: nil)))
        let text = events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined()
        XCTAssertTrue(text.contains("Paradise") && text.contains("Change"), text)
    }

    func testCancelEndsATurnAndStopReportsAnExpectedExit() async throws {
        let bridge = AgentBridge(launch: try sidecar(), registry: ToolRegistry())
        let recorder = Recorder()
        bridge.onEvent = { recorder.add($0) }
        try bridge.start()
        bridge.startSession(AgentSessionConfig(model: "offline", workingDirectory: NSTemporaryDirectory(), libraryFolders: []))
        bridge.chat("/slow")
        let streaming = await recorder.wait { $0.contains { if case .textDelta = $0 { return true } else { return false } } }
        XCTAssertTrue(streaming)
        bridge.cancel()
        let cancelled = await recorder.wait { $0.contains(.turnEnded(status: "cancelled", error: nil)) }
        XCTAssertTrue(cancelled, "\(recorder.all.suffix(3))")

        bridge.stop()
        let exited = await recorder.wait { $0.contains(.exited(expected: true)) }
        XCTAssertTrue(exited)
        XCTAssertFalse(bridge.isRunning)
    }
}
