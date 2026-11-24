import XCTest
@testable import CrateCore

final class StubMix: MixControl, @unchecked Sendable {
    var requests: [MixRequest] = []
    var controls: [(DeckID, [String: JSON])] = []
    var loads: [(Int64, DeckID?)] = []
    var automix: [([Int64], String?)] = []
    var recording: [Bool] = []
    func deckStatus() async -> JSON { ["decks": []] }
    func load(trackID: Int64, deck: DeckID?) async throws -> JSON { loads.append((trackID, deck)); return ["deck": "A"] }
    func control(deck: DeckID, settings: [String: JSON]) async throws -> JSON { controls.append((deck, settings)); return [:] }
    func structure(trackID: Int64) async throws -> JSON { ["track": .number(Double(trackID))] }
    func transition(_ request: MixRequest) async throws -> JSON { requests.append(request); return ["scheduled": true] }
    func cancelTransition() async -> JSON { ["cancelled": true] }
    func startAutomix(trackIDs: [Int64], notes: String?) async throws -> JSON { automix.append((trackIDs, notes)); return [:] }
    func stopAutomix() async -> JSON { ["auto_dj": false] }
    func record(_ on: Bool) async throws -> JSON { recording.append(on); return [:] }
}

final class MixToolTests: XCTestCase {
    private var store: LibraryStore!
    private var registry: ToolRegistry!
    private var mix: StubMix!
    private var first: Int64 = 0, second: Int64 = 0

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
        registry = ToolRegistry()
        mix = StubMix()
        let context = LibraryToolContext(store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog())
        DeckTools.register(into: registry, context: context, mix: mix)
        first = try store.upsertLocal(ScannedFile(path: "/music/one.flac", title: "One", artist: "A", duration: 400, bpm: 120, format: "flac"))
        second = try store.upsertLocal(ScannedFile(path: "/music/two.flac", title: "Two", artist: "B", duration: 400, bpm: 122, format: "flac"))
    }

    func testTheInstructionsOnlyNameToolsThatExist() {
        let names = Set(registry.all.map(\.name))
        for name in ["deck_status", "deck_load", "deck_control", "track_structure", "mix_transition", "mix_cancel", "automix_start", "automix_stop", "mix_record"] {
            XCTAssertTrue(names.contains(name), name)
            XCTAssertTrue(AgentInstructions.text(mixingStyle: "").contains("`\(name)`"), "\(name) is not in the instructions")
        }
        for tool in registry.all {
            XCTAssertEqual(tool.inputSchema["type"], "object", tool.name)
            for required in tool.inputSchema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(tool.inputSchema["properties"]?[required.stringValue ?? ""], "\(tool.name) requires an undeclared argument")
            }
        }
        let styled = AgentInstructions.text(mixingStyle: "Never use the filter.")
        XCTAssertTrue(styled.contains("How this DJ likes to mix"))
        XCTAssertTrue(styled.hasSuffix("Never use the filter.\n"))
        XCTAssertFalse(AgentInstructions.text(mixingStyle: "  ").contains("How this DJ likes to mix"))
    }

    func testAMixRequestIsReadFromTheAgentsWords() async {
        var result = await registry.call(name: "mix_transition", args: ["track": .number(Double(second))])
        XCTAssertTrue(result.ok)
        var expected = MixRequest(trackID: second)
        XCTAssertEqual(mix.requests.last, expected, "defaults: a 32-beat bass swap at the next phrase")

        result = await registry.call(name: "mix_transition", args: [
            "track": .number(Double(second)), "style": "echo_out", "beats": 16, "start_at": "4:32", "incoming_from": 31.5, "keep_tempo": true,
        ])
        XCTAssertTrue(result.ok)
        expected.style = .echoOut
        expected.beats = 16
        expected.start = .time(272)
        expected.incomingSeconds = 31.5
        expected.keepTempo = true
        XCTAssertEqual(mix.requests.last, expected)

        _ = await registry.call(name: "mix_transition", args: ["start_in_bars": 8])
        XCTAssertEqual(mix.requests.last?.start, .barsFromNow(8))
        XCTAssertNil(mix.requests.last?.trackID, "no track given: use the one on the other deck")
        _ = await registry.call(name: "mix_transition", args: ["start": "next_bar"])
        XCTAssertEqual(mix.requests.last?.start, .nextBar)

        let before = mix.requests.count
        for bad: JSON in [["style": "wipe"], ["beats": 0], ["start_at": "soon"], ["track": 9999]] {
            let refused = await registry.call(name: "mix_transition", args: bad)
            XCTAssertFalse(refused.ok, "\(bad)")
        }
        XCTAssertEqual(mix.requests.count, before, "a bad request schedules nothing")
    }

    func testDeckToolsPassOnOnlyWhatWasAsked() async {
        var result = await registry.call(name: "deck_control", args: ["deck": "b", "eq_low": -1, "sync": true])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(mix.controls.last?.0, .b)
        XCTAssertEqual(mix.controls.last?.1, ["eq_low": -1, "sync": true])
        result = await registry.call(name: "deck_control", args: ["deck": "A"])
        XCTAssertFalse(result.ok, "nothing to change")
        result = await registry.call(name: "deck_control", args: ["deck": "C", "fader": 1])
        XCTAssertFalse(result.ok)
        result = await registry.call(name: "deck_control", args: ["fader": 1])
        XCTAssertFalse(result.ok, "no deck named")

        _ = await registry.call(name: "deck_load", args: ["track": .number(Double(first))])
        XCTAssertEqual(mix.loads.last?.0, first)
        XCTAssertNil(mix.loads.last?.1, "no deck given: the app picks the free one")
        _ = await registry.call(name: "deck_load", args: ["track": .number(Double(first)), "deck": "B"])
        XCTAssertEqual(mix.loads.last?.1, .b)

        _ = await registry.call(name: "automix_start", args: ["tracks": [.number(Double(first)), .number(Double(second))], "notes": "keep it moving"])
        XCTAssertEqual(mix.automix.last?.0, [first, second])
        XCTAssertEqual(mix.automix.last?.1, "keep it moving")
        _ = await registry.call(name: "mix_record", args: ["on": true])
        XCTAssertEqual(mix.recording, [true])
    }

    func testTimesCanBeSecondsOrMinutesAndSeconds() {
        XCTAssertEqual(DeckTools.seconds(90), 90)
        XCTAssertEqual(DeckTools.seconds("4:32"), 272)
        XCTAssertEqual(DeckTools.seconds("1:02:03"), 3723)
        XCTAssertNil(DeckTools.seconds("later"))
        XCTAssertNil(DeckTools.seconds(nil))
    }
}

final class TrackStructureTests: XCTestCase {
    func testPhrasesAreNamedByWhereTheBassIs() {
        // 120 BPM: a phrase is 16 seconds. Ten phrases: intro without bass, six full, a breakdown, two of outro.
        let bass: [UInt8] = [0, 200, 200, 200, 30, 200, 200, 200, 10, 10]
        let mids: [UInt8] = [90, 150, 150, 150, 150, 150, 150, 150, 100, 60]
        var bytes: [UInt8] = []
        for phrase in 0..<10 {
            for _ in 0..<(16 * 50) { bytes += [bass[phrase], mids[phrase], 80] }
        }
        let detail = WaveDetail(columnsPerSecond: 50, bytes: bytes)
        let grid = BeatGrid(bpm: 120, firstBeat: 0, duration: 160)
        let structure = TrackStructure.analyse(detail: detail, grid: grid, duration: 160)

        XCTAssertEqual(structure.phrases.count, 10)
        XCTAssertEqual(structure.phrases.map(\.label), [
            "intro, no bass", "full", "full", "full", "breakdown", "full", "full", "full", "outro, no bass", "outro, no bass",
        ])
        XCTAssertEqual(structure.phrases[1].time, 16, accuracy: 0.01)
        XCTAssertEqual(structure.phrases[1].bar, 9)
        XCTAssertEqual(structure.phrases[1].bass, 10)
        XCTAssertEqual(structure.phrases[0].bass, 0)
        XCTAssertEqual(structure.mixIn?.index, 0)
        XCTAssertEqual(structure.mixOut?.index, 8, "the last phrase that leaves room for a 32-beat mix")

        let json = structure.json
        XCTAssertEqual(json["suggested_mix_out"]?["at"], "2:08")
        XCTAssertEqual(json["phrases_of_8_bars"]?.arrayValue?.count, 10)
        XCTAssertEqual(json["tempo"], "steady")
    }
}
