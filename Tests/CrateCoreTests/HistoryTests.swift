import XCTest
@testable import CrateCore

final class PlayLogTests: XCTestCase {
    /// Feeds the log the same picture for a while, a twentieth of a second at a time, as the app does.
    private func run(_ log: inout PlayLog, _ decks: [PlayLog.Deck], seconds: Double) -> [PlayLog.Entry] {
        var entries: [PlayLog.Entry] = []
        for _ in 0..<Int((seconds / 0.05).rounded()) { entries += log.observe(decks, elapsed: 0.05) }
        return entries
    }

    private func deck(_ track: Int64?, _ isInTheMix: Bool = false) -> PlayLog.Deck { PlayLog.Deck(track: track, isInTheMix: isInTheMix) }

    func testATrackCountsAfterHalfAMinuteInTheMixAndOnlyOnce() {
        var log = PlayLog()
        XCTAssertEqual(run(&log, [deck(1, true), deck(nil)], seconds: 29), [])
        XCTAssertEqual(run(&log, [deck(1, true), deck(nil)], seconds: 2), [PlayLog.Entry(track: 1, deck: 0, from: nil)])
        XCTAssertEqual(run(&log, [deck(1, true), deck(nil)], seconds: 200), [], "once is enough")
        // Stopped and started again: still the same play.
        XCTAssertEqual(run(&log, [deck(1, false), deck(nil)], seconds: 20), [])
        XCTAssertEqual(run(&log, [deck(1, true), deck(nil)], seconds: 60), [])
    }

    func testLoadedCuedOrTriedOutIsNotPlayed() {
        var log = PlayLog()
        // On the deck but never in the mix: fader down, or listened to in the headphones.
        XCTAssertEqual(run(&log, [deck(1, false), deck(2, false)], seconds: 300), [])
        // Twenty seconds in the mix, then swapped for another track.
        XCTAssertEqual(run(&log, [deck(1, true), deck(nil)], seconds: 20), [])
        XCTAssertEqual(run(&log, [deck(3, true), deck(nil)], seconds: 20), [], "the new track starts its own count")
        XCTAssertEqual(run(&log, [deck(3, true), deck(nil)], seconds: 11), [PlayLog.Entry(track: 3, deck: 0, from: nil)])
    }

    func testTheHalfMinuteAddsUpAcrossPauses() {
        var log = PlayLog()
        XCTAssertEqual(run(&log, [deck(1, true)], seconds: 15), [])
        XCTAssertEqual(run(&log, [deck(1, false)], seconds: 100), [])
        XCTAssertEqual(run(&log, [deck(1, true)], seconds: 16).map(\.track), [1])
    }

    func testABlendRemembersWhatItWasMixedInFrom() {
        var log = PlayLog()
        XCTAssertEqual(run(&log, [deck(1, true), deck(2)], seconds: 60).map(\.track), [1])
        // Track 2 comes in under track 1; a little later track 1 is taken out.
        XCTAssertEqual(run(&log, [deck(1, true), deck(2, true)], seconds: 10), [])
        XCTAssertEqual(run(&log, [deck(1, false), deck(2, true)], seconds: 25), [PlayLog.Entry(track: 2, deck: 1, from: 1)])
        // And the next goes on the first deck, mixed in from track 2.
        XCTAssertEqual(run(&log, [deck(3, true), deck(2, true)], seconds: 40), [PlayLog.Entry(track: 3, deck: 0, from: 2)])
    }

    func testACutCountsAsFollowingAndASilenceAsStartingCold() {
        var log = PlayLog()
        _ = run(&log, [deck(1, true), deck(2)], seconds: 60)
        // Cut: one stops as the other starts.
        XCTAssertEqual(run(&log, [deck(1, false), deck(2, true)], seconds: 31), [PlayLog.Entry(track: 2, deck: 1, from: 1)])
        // A minute of nothing, then a track: started cold.
        _ = run(&log, [deck(1, false), deck(2, false)], seconds: 60)
        XCTAssertEqual(run(&log, [deck(3, true), deck(2, false)], seconds: 31), [PlayLog.Entry(track: 3, deck: 0, from: nil)])
    }

    func testATrackTriedUnderAnotherIsNotWhatTheNextWasMixedFrom() {
        var log = PlayLog()
        _ = run(&log, [deck(1, true), deck(2)], seconds: 60)
        // Track 2 is brought in for ten seconds and taken out again: never played.
        XCTAssertEqual(run(&log, [deck(1, true), deck(2, true)], seconds: 10), [])
        // Track 3 replaces it and is mixed in from track 1, the only one that has really been playing.
        XCTAssertEqual(run(&log, [deck(1, true), deck(3, true)], seconds: 31), [PlayLog.Entry(track: 3, deck: 1, from: 1)])
    }

    func testTwoStartedTogetherAreNotMixedFromEachOther() {
        var log = PlayLog()
        let entries = run(&log, [deck(1, true), deck(2, true)], seconds: 31)
        XCTAssertEqual(Set(entries.map(\.track)), [1, 2])
        XCTAssertTrue(entries.allSatisfy { $0.from == nil })
    }

    func testAWindowThatStoodStillDoesNotCountAsMinutesOfPlaying() {
        var log = PlayLog()
        // One reading after a long stall: no more than a few seconds are taken on trust.
        XCTAssertEqual(log.observe([deck(1, true)], elapsed: 600), [])
    }
}

final class MixHistoryStoreTests: XCTestCase {
    private var store: LibraryStore!
    private var registry: ToolRegistry!

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
        registry = ToolRegistry()
        HistoryTools.register(into: registry, context: LibraryToolContext(store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog()))
    }

    @discardableResult
    private func add(_ title: String) throws -> Int64 {
        try store.upsertLocal(ScannedFile(path: "/music/\(title).flac", title: title, artist: "Artist", duration: 300, bpm: 120, key: "8A", format: "flac"))
    }

    private let evening = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlaysAreKeptInSessionsLatestFirst() throws {
        let a = try add("A"), b = try add("B"), c = try add("C")
        try store.addPlay(track: a, deck: "A", at: evening)
        try store.addPlay(track: b, deck: "B", from: a, at: evening.addingTimeInterval(300))
        // Fifty minutes after the last track started: the same sitting.
        try store.addPlay(track: c, deck: "A", from: b, at: evening.addingTimeInterval(300 + 3000))
        // The next day.
        try store.addPlay(track: b, deck: "A", at: evening.addingTimeInterval(86400))

        let sessions = try store.mixSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].plays.map(\.trackID), [b], "the latest session first")
        XCTAssertEqual(sessions[1].plays.map(\.trackID), [a, b, c], "in the order played")
        XCTAssertEqual(sessions[1].plays.map(\.fromTrackID), [nil, a, b])
        XCTAssertEqual(sessions[1].plays.map(\.deck), ["A", "B", "A"])
        XCTAssertEqual(sessions[1].startedAt, evening)
        XCTAssertEqual(sessions[1].lastPlayedAt, evening.addingTimeInterval(3300))
        XCTAssertEqual(try store.mixSessions(limit: 1).map(\.id), [sessions[0].id])
        XCTAssertEqual(try store.plays(of: b).count, 2)
    }

    func testRemovingAPlayASessionOrATrack() throws {
        let a = try add("A"), b = try add("B"), c = try add("C")
        try store.addPlay(track: a, deck: "A", at: evening)
        let second = try store.addPlay(track: b, deck: "B", from: a, at: evening.addingTimeInterval(200))
        try store.addPlay(track: c, deck: "A", from: b, at: evening.addingTimeInterval(400))
        try store.addPlay(track: a, deck: "A", at: evening.addingTimeInterval(90000))

        try store.deletePlay(id: second.id)
        XCTAssertEqual(try store.mixSessions().last?.plays.map(\.trackID), [a, c])

        // A track removed from the library takes its plays with it; what was mixed in from it was, from then on, started cold.
        try store.deleteTracks(ids: [a])
        let sessions = try store.mixSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].plays.map(\.trackID), [c])

        try store.deleteMixSession(id: sessions[0].id)
        XCTAssertEqual(try store.mixSessions(), [])
    }

    func testADownloadTakingAStreamingTracksPlaceTakesItsHistoryToo() throws {
        let stream = try add("Stream"), file = try add("File"), other = try add("Other")
        try store.addPlay(track: stream, deck: "TIDAL", at: evening)
        try store.addPlay(track: other, deck: "A", from: stream, at: evening.addingTimeInterval(100))
        try store.replaceInCrates(track: stream, with: file)
        try store.deleteTracks(ids: [stream])
        let plays = try XCTUnwrap(try store.mixSessions().first).plays
        XCTAssertEqual(plays.map(\.trackID), [file, other])
        XCTAssertEqual(plays[1].fromTrackID, file)
    }

    func testTheAgentCanReadTheHistory() async throws {
        let a = try add("A"), b = try add("B"), c = try add("C")
        try store.addPlay(track: a, deck: "A", at: evening)
        try store.addPlay(track: b, deck: "B", from: a, at: evening.addingTimeInterval(300))
        try store.addPlay(track: c, deck: "A", at: evening.addingTimeInterval(600))

        let all = await registry.call(name: "mix_history", args: [:])
        XCTAssertTrue(all.ok)
        let session = try XCTUnwrap(all.content["sessions"]?.arrayValue?.first)
        let tracks = try XCTUnwrap(session["tracks"]?.arrayValue)
        XCTAssertEqual(tracks.compactMap { $0["track"]?["title"]?.stringValue }, ["A", "B", "C"])
        XCTAssertEqual(tracks[1]["mixed_from"]?.intValue, Int(a))
        XCTAssertNil(tracks[2]["mixed_from"])

        let one = await registry.call(name: "mix_history", args: ["track": .number(Double(b))])
        XCTAssertTrue(one.ok)
        XCTAssertEqual(one.content["times_played"]?.intValue, 1)
        let play = try XCTUnwrap(one.content["plays"]?.arrayValue?.first)
        XCTAssertEqual(play["mixed_from"]?["title"]?.stringValue, "A")
        XCTAssertEqual(play["before"]?["title"]?.stringValue, "A")
        XCTAssertEqual(play["after"]?["title"]?.stringValue, "C")
        XCTAssertNil(play["mixed_into"], "C was started cold")

        let missing = await registry.call(name: "mix_history", args: ["track": 9999])
        XCTAssertFalse(missing.ok)
    }
}
