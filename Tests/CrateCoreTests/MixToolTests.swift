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

final class CueSuggesterTests: XCTestCase {
    /// 120 BPM, so a phrase is 16 seconds and a beat half a second. One phrase for each level of bass given.
    private func shape(bass: [UInt8]) -> (structure: TrackStructure, grid: BeatGrid, detail: WaveDetail) {
        var bytes: [UInt8] = []
        for level in bass {
            for _ in 0..<(16 * 50) { bytes += [level, 150, 80] }
        }
        let duration = Double(bass.count) * 16
        let detail = WaveDetail(columnsPerSecond: 50, bytes: bytes)
        let grid = BeatGrid(bpm: 120, firstBeat: 0, duration: duration)
        return (TrackStructure.analyse(detail: detail, grid: grid, duration: duration), grid, detail)
    }

    func testCuesGoWhereTheTrackChangesAndLoopsAtEachEnd() {
        // Intro without bass, three phrases full, a breakdown, three full, two of outro.
        let (structure, grid, _) = shape(bass: [0, 200, 200, 200, 30, 200, 200, 200, 10, 10])
        let cues = CueSuggester.suggest(structure: structure, grid: grid)
        XCTAssertEqual(cues.filter { !$0.isLoop }, [
            CuePoint(slot: 1, position: 0, name: "Start"), CuePoint(slot: 2, position: 16, name: "Bass in"),
            CuePoint(slot: 3, position: 64, name: "Break"), CuePoint(slot: 4, position: 80, name: "Drop"),
            CuePoint(slot: 5, position: 128, name: "Outro"),
        ])
        // Four bars at each end, on the last two pads.
        XCTAssertEqual(cues.filter(\.isLoop), [
            CuePoint(slot: 7, position: 0, name: "Intro loop", loopEnd: 8), CuePoint(slot: 8, position: 128, name: "Outro loop", loopEnd: 136),
        ])
    }

    func testATrackWithManyBreakdownsKeepsTheCuesThatMatterMost() {
        // Four breakdowns: more places than there are pads for cues.
        let (structure, grid, _) = shape(bass: [0, 200, 20, 200, 20, 200, 20, 200, 20, 200, 10])
        let cues = CueSuggester.suggest(structure: structure, grid: grid).filter { !$0.isLoop }
        XCTAssertEqual(cues.map(\.name), ["Start", "Bass in", "Break", "Drop", "Break 2", "Outro"])
        XCTAssertEqual(cues.map(\.slot), [1, 2, 3, 4, 5, 6], "in the order they come in the track")
        XCTAssertEqual(cues.map(\.position), cues.map(\.position).sorted())
    }

    func testATrackThatIsFullThroughoutStillGetsAStartAndAWayOut() {
        let (structure, grid, _) = shape(bass: [200, 200, 200, 200])
        let cues = CueSuggester.suggest(structure: structure, grid: grid)
        XCTAssertEqual(cues.filter { !$0.isLoop }.map(\.name), ["Start", "Mix out"])
        XCTAssertEqual(cues.filter(\.isLoop).map(\.name), ["Intro loop", "Outro loop"])
    }

    func testSuggestionsOnlyFillPadsThatAreEmpty() {
        let mine = [CuePoint(slot: 1, position: 16.1, name: "My drop"), CuePoint(slot: 7, position: 200, name: "Mine")]
        let suggested = [
            CuePoint(slot: 1, position: 0, name: "Start"), CuePoint(slot: 2, position: 16, name: "Bass in"),
            CuePoint(slot: 7, position: 0, name: "Intro loop", loopEnd: 8),
        ]
        let result = CueSuggester.filling(mine, with: suggested, beat: 0.5)
        XCTAssertEqual(result, [
            CuePoint(slot: 1, position: 16.1, name: "My drop"),           // kept
            CuePoint(slot: 2, position: 0, name: "Start"),                // its pad was taken: the next free one
            CuePoint(slot: 3, position: 0, name: "Intro loop", loopEnd: 8),
            CuePoint(slot: 7, position: 200, name: "Mine"),
        ], "and nothing is put where there is a cue within a beat already")
    }

    func testTheAgentCanReadSetAndClearCues() async throws {
        let store = try LibraryStore(path: ":memory:")
        let registry = ToolRegistry()
        let context = LibraryToolContext(store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog())
        CueTools.register(into: registry, context: context)
        let id = try store.upsertLocal(ScannedFile(path: "/music/x.flac", title: "Dancer", artist: "Gino Soccio", duration: 160, format: "flac"))
        let (_, grid, detail) = shape(bass: [0, 200, 200, 200, 30, 200, 200, 200, 10, 10])

        // Not analysed yet: nothing to suggest, and loops cannot be measured.
        var result = await registry.call(name: "cue_points", args: ["track": .number(Double(id))])
        XCTAssertTrue(result.ok, "\(result.content)")
        XCTAssertNil(result.content["suggested"])
        result = await registry.call(name: "cue_set", args: ["track": .number(Double(id)), "cues": [["at": 10, "loop_beats": 16]]])
        XCTAssertFalse(result.ok)

        try store.setBeatGrid(id: id, grid, edited: false)
        try store.setAnalysis(id: id, bpm: 120, key: nil, waveform: nil, detail: detail)
        result = await registry.call(name: "cue_points", args: ["track": .number(Double(id))])
        XCTAssertEqual(result.content["suggested"]?.arrayValue?.count, 7)
        XCTAssertEqual(result.content["suggested"]?.arrayValue?.last?["loop_beats"], 16)
        XCTAssertEqual(result.content["free_pads"]?.arrayValue?.count, 8)

        // Times land on the nearest beat; a pad is found when none is given; a loop is so many beats.
        result = await registry.call(name: "cue_set", args: ["track": .number(Double(id)), "cues": [
            ["at": "1:04.2", "name": "Break"], ["at": 80.1, "name": "Drop", "pad": 4], ["at": 128, "name": "Outro loop", "loop_beats": 16, "pad": 8],
        ]])
        XCTAssertTrue(result.ok, "\(result.content)")
        XCTAssertEqual(try store.cuePoints(id: id), [
            CuePoint(slot: 1, position: 64, name: "Break"), CuePoint(slot: 4, position: 80, name: "Drop"),
            CuePoint(slot: 8, position: 128, name: "Outro loop", loopEnd: 136),
        ])
        XCTAssertEqual(result.content["set"]?.arrayValue?.first?["bar"], 33)

        result = await registry.call(name: "cue_set", args: ["track": .number(Double(id)), "cues": [["at": 999]]])
        XCTAssertFalse(result.ok, "outside the track")
        result = await registry.call(name: "cue_clear", args: ["track": .number(Double(id)), "pads": [4]])
        XCTAssertEqual(result.content["removed"], 1)
        result = await registry.call(name: "cue_set", args: ["track": .number(Double(id)), "replace_all": true, "cues": [["at": 0, "name": "Start"]]])
        XCTAssertEqual(try store.cuePoints(id: id), [CuePoint(slot: 1, position: 0, name: "Start")])
        result = await registry.call(name: "cue_clear", args: ["track": .number(Double(id))])
        XCTAssertEqual(try store.cuePoints(id: id), [])
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

final class MixPlanTests: XCTestCase {
    private var store: LibraryStore!
    private var registry: ToolRegistry!

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
        registry = ToolRegistry()
        MixPlanTools.register(into: registry, context: LibraryToolContext(store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog()))
    }

    /// A track of ten 8-bar phrases: an intro without bass, a body, and two phrases of outro.
    private func add(_ title: String, bpm: Double, analysed: Bool = true) throws -> Track {
        let phrase = 32 * 60 / bpm, duration = phrase * 10
        let id = try store.upsertLocal(ScannedFile(path: "/music/\(title).flac", title: title, artist: "Artist", duration: duration, bpm: bpm, format: "flac"))
        if analysed {
            var bytes: [UInt8] = []
            for level: UInt8 in [0, 200, 200, 200, 200, 200, 200, 200, 10, 10] {
                for _ in 0..<Int(phrase * 50) { bytes += [level, 150, 80] }
            }
            try store.setBeatGrid(id: id, BeatGrid(bpm: bpm, firstBeat: 0, duration: duration), edited: false)
            try store.setAnalysis(id: id, bpm: bpm, key: nil, waveform: nil, detail: WaveDetail(columnsPerSecond: 50, bytes: bytes))
        }
        return try XCTUnwrap(try store.track(id: id))
    }

    func testCrateJoinsTwoTracksWhereOneThinsOutAndTheOtherBegins() throws {
        let a = try add("A", bpm: 120), b = try add("B", bpm: 122), fast = try add("Fast", bpm: 140), raw = try add("Raw", bpm: 120, analysed: false)
        let step = MixPlanner.suggest(from: MixSide(track: a, store: store), to: MixSide(track: b, store: store))
        XCTAssertEqual(step.style, .bassSwap)
        XCTAssertEqual(step.beats, 32)
        XCTAssertEqual(step.outAt, 128, accuracy: 0.01, "the start of the outro: phrase nine of ten at 16 seconds a phrase")
        XCTAssertEqual(step.inAt, 0, accuracy: 0.01)
        XCTAssertEqual(step.author, .crate)
        XCTAssertEqual(step.request.trackID, b.id)
        XCTAssertEqual(step.request.start, .time(step.outAt))
        XCTAssertEqual(step.request.incomingSeconds, step.inAt)

        // Too far apart in tempo to blend; nothing to keep time by without a grid.
        XCTAssertEqual(MixPlanner.suggest(from: MixSide(track: a, store: store), to: MixSide(track: fast, store: store)).style, .echoOut)
        XCTAssertEqual(MixPlanner.suggest(from: MixSide(track: a, store: store), to: MixSide(track: raw, store: store)).style, .cut)
        XCTAssertLessThan(MixPlanner.tempoGap(120, 61), 0.03, "a tempo read at half speed is the same tempo")
    }

    func testTimesLandOnBarLinesAndAMixIsShortenedToFit() throws {
        let a = try add("A", bpm: 120), b = try add("B", bpm: 120)
        let from = MixSide(track: a, store: store), to = MixSide(track: b, store: store)
        var step = MixStep(from: a.id, to: b.id, style: .blend, beats: 64, outAt: 150.9, inAt: 17.2)
        step = MixPlanner.tidied(step, from: from, to: to)
        XCTAssertEqual(step.outAt, 150, accuracy: 0.001, "bars are two seconds long at 120")
        XCTAssertEqual(step.inAt, 18, accuracy: 0.001)
        XCTAssertEqual(step.beats, 16, "ten seconds are left: 64 beats would run off the end")
        // A cut has no length to fit.
        XCTAssertEqual(MixPlanner.tidied(MixStep(from: a.id, to: b.id, style: .cut, beats: 64, outAt: 158, inAt: 0), from: from, to: to).beats, 64)
    }

    func testAMixIsKeptWithItsCrateAndGoesWithIt() throws {
        let a = try add("A", bpm: 120), b = try add("B", bpm: 120), c = try add("C", bpm: 120)
        let crate = try store.createCrate(name: "Set")
        try store.addToCrate(id: crate.id, trackIDs: [a.id, b.id, c.id])
        let first = MixStep(from: a.id, to: b.id, style: .filter, beats: 16, outAt: 120, inAt: 16, note: "filter out", author: .agent)
        try store.setMixSteps(crate: crate.id, [first, MixStep(from: b.id, to: c.id, style: .cut, outAt: 100, inAt: 0)])
        XCTAssertEqual(try store.mixStep(crate: crate.id, from: a.id, to: b.id), first)
        XCTAssertEqual(try store.mixSteps(crate: crate.id).count, 2)
        XCTAssertNil(try store.mixStep(crate: crate.id, from: b.id, to: a.id), "a transition has a direction")

        // Each track from where it comes in to where it is left: 120 + (100 - 16) + 160.
        XCTAssertEqual(MixPlanner.length(of: [a, b, c], steps: try store.mixSteps(crate: crate.id)), 364, accuracy: 0.01)

        try store.removeMixSteps(crate: crate.id, pairs: [(from: b.id, to: c.id)])
        XCTAssertEqual(try store.mixSteps(crate: crate.id), [first])
        try store.deleteCrate(id: crate.id)
        XCTAssertEqual(try store.mixSteps(crate: crate.id), [])
    }

    func testTheAgentCanReadSaveAndClearACratesMix() async throws {
        let a = try add("A", bpm: 120), b = try add("B", bpm: 120), c = try add("C", bpm: 120)
        let crate = try store.createCrate(name: "Set")
        try store.addToCrate(id: crate.id, trackIDs: [a.id, b.id, c.id])

        var result = await registry.call(name: "mix_plan", args: ["crate": "Set"])
        XCTAssertTrue(result.ok, "\(result.content)")
        var transitions = try XCTUnwrap(result.content["transitions"]?.arrayValue)
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions[0]["saved"], false, "nothing saved yet: this is what Crate would do")
        XCTAssertEqual(transitions[0]["style"], "bass_swap")
        XCTAssertEqual(transitions[0]["out_at"], "2:08")

        // The DJ has set one by hand.
        try store.setMixSteps(crate: crate.id, [MixStep(from: b.id, to: c.id, style: .tapeStop, outAt: 140, inAt: 16)])

        result = await registry.call(name: "mix_plan_set", args: ["crate": "Set", "transitions": [
            ["from": .number(Double(a.id)), "to": .number(Double(b.id)), "style": "filter", "beats": 16, "out_at": "2:09", "in_at": 15.6, "note": "filter over the outro"],
        ]])
        XCTAssertTrue(result.ok, "\(result.content)")
        let saved = try XCTUnwrap(try store.mixStep(crate: crate.id, from: a.id, to: b.id))
        XCTAssertEqual(saved.style, .filter)
        XCTAssertEqual(saved.beats, 16)
        XCTAssertEqual(saved.outAt, 130, accuracy: 0.001, "on the nearest bar line")
        XCTAssertEqual(saved.inAt, 16, accuracy: 0.001)
        XCTAssertEqual(saved.author, .agent)
        XCTAssertEqual(saved.note, "filter over the outro")

        result = await registry.call(name: "mix_plan", args: ["crate": "Set"])
        transitions = try XCTUnwrap(result.content["transitions"]?.arrayValue)
        XCTAssertEqual(transitions[0]["set_by"], "agent")
        XCTAssertEqual(transitions[1]["set_by"], "the DJ")
        XCTAssertEqual(transitions[1]["style"], "tape_stop")

        // Changing only the style keeps the rest; a pair that are not neighbours is saved with a warning.
        result = await registry.call(name: "mix_plan_set", args: ["crate": "Set", "transitions": [
            ["from": .number(Double(a.id)), "to": .number(Double(b.id)), "style": "blend"],
            ["from": .number(Double(a.id)), "to": .number(Double(c.id)), "style": "cut"],
        ]])
        XCTAssertEqual(try store.mixStep(crate: crate.id, from: a.id, to: b.id)?.outAt ?? 0, 130, accuracy: 0.001)
        XCTAssertEqual(try store.mixStep(crate: crate.id, from: a.id, to: b.id)?.style, .blend)
        XCTAssertEqual(result.content["notes"]?.arrayValue?.count, 1)

        result = await registry.call(name: "mix_plan_set", args: ["crate": "Set", "transitions": [["from": .number(Double(a.id)), "to": 9999]]])
        XCTAssertFalse(result.ok)
        result = await registry.call(name: "mix_plan_set", args: ["crate": "Set", "transitions": [["from": .number(Double(a.id)), "to": .number(Double(b.id)), "out_at": 9999]]])
        XCTAssertFalse(result.ok, "outside the track")

        result = await registry.call(name: "mix_plan_clear", args: ["crate": "Set", "pairs": [["from": .number(Double(a.id)), "to": .number(Double(c.id))]]])
        XCTAssertEqual(result.content["removed"], 1)
        result = await registry.call(name: "mix_plan_clear", args: ["crate": "Set"])
        XCTAssertEqual(try store.mixSteps(crate: crate.id), [])
    }
}
