import XCTest
@testable import CrateCore

final class CamelotTests: XCTestCase {
    func testParsesTheNotationsFoundInTags() {
        XCTAssertEqual(CamelotKey(parsing: "8A")?.description, "8A")
        XCTAssertEqual(CamelotKey(parsing: "08b")?.description, "8B")
        XCTAssertEqual(CamelotKey(parsing: "Am")?.description, "8A")
        XCTAssertEqual(CamelotKey(parsing: "A minor")?.description, "8A")
        XCTAssertEqual(CamelotKey(parsing: "C")?.description, "8B")
        XCTAssertEqual(CamelotKey(parsing: "F#m")?.description, "11A")
        XCTAssertEqual(CamelotKey(parsing: "Gb min")?.description, "11A")
        XCTAssertEqual(CamelotKey(parsing: "Bb")?.description, "6B")
        XCTAssertEqual(CamelotKey(parsing: "bm")?.description, "10A")
        XCTAssertEqual(CamelotKey(parsing: "E♭ major")?.description, "5B")
        // Open Key
        XCTAssertEqual(CamelotKey(parsing: "1d")?.description, "8B")
        XCTAssertEqual(CamelotKey(parsing: "1m")?.description, "8A")
        XCTAssertEqual(CamelotKey(parsing: "6m")?.description, "1A")
    }

    func testRejectsNonsense() {
        XCTAssertNil(CamelotKey(parsing: ""))
        XCTAssertNil(CamelotKey(parsing: "13A"))
        XCTAssertNil(CamelotKey(parsing: "0B"))
        XCTAssertNil(CamelotKey(parsing: "H"))
        XCTAssertNil(CamelotKey(parsing: "A sus4"))
        XCTAssertNil(CamelotKey(parsing: "124"))
    }

    func testEveryKeyRoundTripsThroughItsPitchClass() {
        for number in 1...12 {
            for isMajor in [true, false] {
                let key = CamelotKey(number: number, isMajor: isMajor)!
                XCTAssertEqual(CamelotKey(pitchClass: key.pitchClass, isMajor: isMajor), key)
                XCTAssertEqual(CamelotKey(parsing: key.description), key)
            }
        }
    }

    func testCompatibleKeysWrapRoundTheWheel() {
        XCTAssertEqual(CamelotKey(parsing: "8A")!.compatible.map(\.description), ["8A", "7A", "9A", "8B"])
        XCTAssertEqual(CamelotKey(parsing: "12B")!.compatible.map(\.description), ["12B", "11B", "1B", "12A"])
        XCTAssertEqual(CamelotKey(parsing: "1A")!.compatible.map(\.description), ["1A", "12A", "2A", "1B"])
    }
}

final class FilenameParserTests: XCTestCase {
    private func guess(_ relative: String) -> FilenameParser.Guess {
        FilenameParser.guess(path: "/Volumes/Transcend/Music/" + relative, root: "/Volumes/Transcend/Music")
    }

    func testArtistDashTitle() {
        XCTAssertEqual(guess("Alan Braxe - Intro.wav"), .init(artist: "Alan Braxe", title: "Intro"))
        XCTAssertEqual(
            guess("Brothers' Vibe/Brothers' Vibe - Manos Libre (Dub).aiff"),
            .init(artist: "Brothers' Vibe", title: "Manos Libre (Dub)"))
    }

    func testTrackNumbersAreDropped() {
        XCTAssertEqual(guess("03 - Ackermann - Sweat.wav"), .init(artist: "Ackermann", title: "Sweat"))
        XCTAssertEqual(guess("A1 - Ackermann - Sweat.wav"), .init(artist: "Ackermann", title: "Sweat"))
        XCTAssertEqual(guess("01. Ackermann - Sweat.wav"), .init(artist: "Ackermann", title: "Sweat"))
    }

    func testArtistAlbumTitle() {
        XCTAssertEqual(
            guess("Change - The Glow of Love - 02 - Paradise.flac"),
            .init(artist: "Change", title: "Paradise", album: "The Glow of Love"))
    }

    func testFoldersSupplyWhatTheNameLacks() {
        XCTAssertEqual(
            guess("Grace Jones/Nightclubbing/03 Pull Up to the Bumper.flac"),
            .init(artist: "Grace Jones", title: "Pull Up to the Bumper", album: "Nightclubbing"))
        XCTAssertEqual(guess("Kraftwerk/Numbers.wav"), .init(artist: "Kraftwerk", title: "Numbers"))
        XCTAssertEqual(guess("loose_track_name.wav"), .init(artist: "", title: "loose track name"))
    }

    func testNamesThatStartWithNumbersSurvive() {
        XCTAssertEqual(guess("808 State - Pacific.wav"), .init(artist: "808 State", title: "Pacific"))
        XCTAssertEqual(guess("D12 - Fight Music.mp3"), .init(artist: "D12", title: "Fight Music"))
        XCTAssertEqual(guess("Artist/Album/2 Bad Mice.wav").title, "2 Bad Mice")
    }

    func testFoldersAboveTheLibraryRootAreIgnored() {
        let outside = FilenameParser.guess(path: "/Users/someone/Desktop/track.mp3", root: "/Volumes/Transcend/Music")
        XCTAssertEqual(outside, .init(artist: "", title: "track"))
    }
}

final class LibraryStoreTests: XCTestCase {
    private var store: LibraryStore!

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
    }

    @discardableResult
    private func add(
        _ artist: String, _ title: String, bpm: Double? = nil, key: String? = nil, path: String? = nil
    ) throws -> Int64 {
        try store.upsertLocal(ScannedFile(
            path: path ?? "/music/\(artist) - \(title).flac", title: title, artist: artist, duration: 300, bpm: bpm,
            key: key, format: "flac", size: 1000, modified: 1))
    }

    func testSearchMatchesEveryWordAsAPrefix() throws {
        try add("Loleatta Holloway", "Love Sensation")
        try add("Change", "Paradise")
        try add("First Choice", "Let No Man Put Asunder")

        var query = TrackQuery()
        query.text = "lole sens"
        XCTAssertEqual(try store.tracks(query).map(\.title), ["Love Sensation"])
        query.text = "choice"
        XCTAssertEqual(try store.tracks(query).map(\.artist), ["First Choice"])
        query.text = "paradise nope"
        XCTAssertTrue(try store.tracks(query).isEmpty)
        // Punctuation people type must not break the query.
        query.text = "\"change\" (paradise)*"
        XCTAssertEqual(try store.tracks(query).count, 1)
    }

    func testFiltersByBPMRangeAndKey() throws {
        try add("A", "one", bpm: 118, key: "Am")
        try add("B", "two", bpm: 124, key: "8B")
        try add("C", "three", bpm: 128, key: "F#m")
        try add("D", "four")

        var query = TrackQuery()
        query.bpmMin = 118
        query.bpmMax = 124
        XCTAssertEqual(try store.tracks(query).map(\.title), ["one", "two"])

        query = TrackQuery()
        query.keys = CamelotKey(parsing: "8A")!.compatible.map(\.description)
        XCTAssertEqual(try store.tracks(query).map(\.title), ["one", "two"])

        query = TrackQuery()
        query.needsTagging = true
        XCTAssertEqual(try store.tracks(query).map(\.title), ["four"])
    }

    func testKeysAreStoredAsCamelotAndSortRoundTheWheel() throws {
        try add("A", "twelve", key: "E")       // 12B
        try add("B", "two", key: "Ebm")        // 2A
        try add("C", "eight", key: "A minor")  // 8A
        try add("D", "none")
        var query = TrackQuery()
        query.sort = .key
        let tracks = try store.tracks(query)
        XCTAssertEqual(tracks.map(\.key), ["2A", "8A", "12B", nil])
    }

    func testRescanKeepsEditsAndLetsTagsBeatEstimates() throws {
        let id = try add("", "untitled", path: "/music/x.wav")
        try store.setAnalysis(id: id, bpm: 121.9, key: "8A", waveform: Data([1, 2, 3]))
        XCTAssertEqual(try store.track(id: id)?.bpmSource, .estimated)

        var patch = TrackPatch()
        patch.artist = "Decius"
        patch.key = .some("9A")
        try store.update(id: id, patch)

        // The file gains tags and is scanned again.
        let again = try store.upsertLocal(ScannedFile(
            path: "/music/x.wav", title: "Ghent", artist: "Someone Else", duration: 300, bpm: 122, key: "Am",
            format: "wav", size: 2000, modified: 2))
        XCTAssertEqual(again, id)
        let track = try XCTUnwrap(store.track(id: id))
        XCTAssertEqual(track.artist, "Decius", "an edit is never undone by a rescan")
        XCTAssertEqual(track.title, "untitled")
        XCTAssertEqual(track.bpm, 122, "a tag replaces an estimate")
        XCTAssertEqual(track.bpmSource, .tag)
        XCTAssertEqual(track.key, "9A", "a manual key beats a tag")
        XCTAssertEqual(track.keySource, .manual)
        XCTAssertEqual(try store.waveform(id: id), Data([1, 2, 3]))

        // A later estimate must not replace either.
        try store.setAnalysis(id: id, bpm: 61, key: "1B", waveform: nil)
        XCTAssertEqual(try store.track(id: id)?.bpm, 122)
        XCTAssertEqual(try store.track(id: id)?.key, "9A")
    }

    func testATrackAnalysedBeforeDetailedWaveformsIsAnalysedAgain() throws {
        let id = try add("Artist", "Title", path: "/music/y.wav")
        try store.setAnalysis(id: id, bpm: 120, key: "8A", waveform: Data([1]))
        XCTAssertNil(try store.waveDetail(id: id))
        XCTAssertEqual(try store.unanalyzedLocalTracks().map(\.id), [id], "no detailed waveform yet")

        let detail = WaveDetail(columnsPerSecond: 50, bytes: [1, 2, 3, 4, 5, 6])
        try store.setAnalysis(id: id, bpm: 120, key: "8A", waveform: nil, detail: detail)
        XCTAssertEqual(try store.waveDetail(id: id), detail)
        XCTAssertEqual(try store.unanalyzedLocalTracks().map(\.id), [id], "still no beat grid")
        try store.setBeatGrid(id: id, nil, edited: false)
        XCTAssertTrue(try store.unanalyzedLocalTracks().isEmpty, "a track with no findable beat is not tried again")
        XCTAssertNil(try store.beatGrid(id: id))

        try store.deleteTracks(ids: [id])
        XCTAssertNil(try store.waveDetail(id: id), "the waveform goes with its track")
    }

    func testAGridFromAnOlderBeatTrackerIsMadeAgainUnlessEditedByHand() throws {
        let detail = WaveDetail(columnsPerSecond: 50, bytes: [1, 2, 3, 4, 5, 6])
        let machine = try add("Artist", "Machine", path: "/music/m.wav"), edited = try add("Artist", "Edited", path: "/music/e.wav")
        let grid = BeatGrid(bpm: 120, firstBeat: 0.1, duration: 60).withMarkers()
        for id in [machine, edited] { try store.setAnalysis(id: id, bpm: 120, key: "8A", waveform: Data([1]), detail: detail) }
        try store.setBeatGrid(id: machine, grid, edited: false)
        try store.setBeatGrid(id: edited, grid, edited: true)
        XCTAssertTrue(try store.unanalyzedLocalTracks().isEmpty)
        XCTAssertFalse(try store.beatGridIsOutdated(id: machine))

        // As a library looks after upgrading: every grid made by the tracker before this one.
        try store.db.execute("UPDATE beatgrids SET version = ?", [.int(Int64(BeatTracker.version - 1))])
        XCTAssertEqual(try store.unanalyzedLocalTracks().map(\.id), [machine])
        XCTAssertTrue(try store.beatGridIsOutdated(id: machine))
        XCTAssertFalse(try store.beatGridIsOutdated(id: edited), "a grid corrected by hand is never redone")
        try store.setBeatGrid(id: machine, grid, edited: false)
        XCTAssertTrue(try store.unanalyzedLocalTracks().isEmpty)
    }

    func testAHandEditedBeatGridSurvivesReanalysisAndCuesAreKeptPerTrack() throws {
        let id = try add("Artist", "Title", path: "/music/z.wav")
        var analysed = BeatGrid(bpm: 120, firstBeat: 0.1, duration: 60).withMarkers()
        analysed.downbeat = 1
        try store.setBeatGrid(id: id, analysed, edited: false)
        XCTAssertEqual(try store.beatGrid(id: id), analysed)

        let nudged = analysed.shifted(by: -0.012).settingDownbeat(at: 1.1)
        try store.setBeatGrid(id: id, nudged, edited: true)
        try store.setBeatGrid(id: id, analysed, edited: false)   // a later re-analysis
        XCTAssertEqual(try store.beatGrid(id: id), nudged, "the hand-set grid wins")
        try store.setBeatGrid(id: id, analysed, edited: true)
        XCTAssertEqual(try store.beatGrid(id: id), analysed, "another hand edit replaces it")

        XCTAssertEqual(try store.cues(id: id), [:])
        try store.setCue(id: id, slot: 1, position: 12.5)
        try store.setCue(id: id, slot: 3, position: 64)
        try store.setCue(id: id, slot: 1, position: 13)
        XCTAssertEqual(try store.cues(id: id), [1: 13, 3: 64])
        try store.setCue(id: id, slot: 3, position: nil)
        XCTAssertEqual(try store.cues(id: id), [1: 13])

        // A cue can have a name, and an end that makes it a saved loop.
        try store.setCuePoint(id: id, CuePoint(slot: 1, position: 13, name: "Drop"))
        try store.setCuePoint(id: id, CuePoint(slot: 7, position: 32, name: "Intro loop", loopEnd: 40))
        XCTAssertEqual(try store.cuePoints(id: id), [
            CuePoint(slot: 1, position: 13, name: "Drop"), CuePoint(slot: 7, position: 32, name: "Intro loop", loopEnd: 40),
        ])
        // Moved by its pad, a cue keeps its name and a loop keeps its length.
        try store.setCue(id: id, slot: 1, position: 14)
        try store.setCue(id: id, slot: 7, position: 30)
        XCTAssertEqual(try store.cuePoints(id: id), [
            CuePoint(slot: 1, position: 14, name: "Drop"), CuePoint(slot: 7, position: 30, name: "Intro loop", loopEnd: 38),
        ])
        XCTAssertNil(CuePoint(slot: 2, position: 10, loopEnd: 9).loopEnd, "a loop that ends before it starts is no loop")
        // All at once, as the cue editor's undo and the agent do.
        try store.setCuePoints(id: id, [CuePoint(slot: 4, position: 5, name: "Start"), CuePoint(slot: 9, position: 1)])
        XCTAssertEqual(try store.cuePoints(id: id), [CuePoint(slot: 4, position: 5, name: "Start")], "there are eight pads")
    }

    func testUpdateRejectsAnUnreadableKeyAndUnknownTrack() throws {
        let id = try add("A", "one")
        var patch = TrackPatch()
        patch.key = .some("H sharp")
        XCTAssertThrowsError(try store.update(id: id, patch))
        XCTAssertThrowsError(try store.update(id: 999, TrackPatch()))
        patch.key = .some(nil)
        patch.bpm = .some(nil)
        XCTAssertNoThrow(try store.update(id: id, patch))
    }

    func testCratesKeepOrderAndIgnoreDuplicates() throws {
        let a = try add("A", "one"), b = try add("B", "two"), c = try add("C", "three")
        let crate = try store.createCrate(name: "Disco")
        XCTAssertThrowsError(try store.createCrate(name: "disco"), "names are unique whatever the case")

        XCTAssertEqual(try store.addToCrate(id: crate.id, trackIDs: [c, a]), 2)
        XCTAssertEqual(try store.addToCrate(id: crate.id, trackIDs: [a, b, 999]), 1)
        var query = TrackQuery()
        query.crateID = crate.id
        XCTAssertEqual(try store.tracks(query).map(\.id), [c, a, b])

        try store.reorderCrate(id: crate.id, trackIDs: [b, c])
        XCTAssertEqual(try store.tracks(query).map(\.id), [b, c, a])

        XCTAssertEqual(try store.removeFromCrate(id: crate.id, trackIDs: [c]), 1)
        XCTAssertEqual(try store.crates().first?.trackCount, 2)

        // Deleting a track takes it out of its crates.
        try store.deleteTracks(ids: [a])
        XCTAssertEqual(try store.tracks(query).map(\.id), [b])
        try store.deleteCrate(id: crate.id)
        XCTAssertEqual(try store.stats().tracks, 2)
    }

    func testStreamingTracksAreStoredOncePerURI() throws {
        let first = try store.upsertStreaming(
            source: .spotify, uri: "spotify:track:abc", title: "Paradise", artist: "Change", album: "", duration: 310)
        let second = try store.upsertStreaming(
            source: .spotify, uri: "spotify:track:abc", title: "Paradise", artist: "Change", album: "", duration: 310)
        XCTAssertEqual(first, second)
        let tidal = try store.upsertStreaming(
            source: .tidal, uri: "tidal:track:1", title: "Hit and Run", artist: "Loleatta Holloway", album: "",
            duration: 400, bpm: 119, key: "Dm")
        XCTAssertEqual(try store.track(id: tidal)?.key, "7A")
        XCTAssertEqual(try store.track(id: tidal)?.bpmSource, .service)
        let stats = try store.stats()
        XCTAssertEqual([stats.tracks, stats.spotify, stats.tidal, stats.local], [2, 1, 1, 0])
    }

    func testRemovingAFolderRemovesOnlyItsTracks() throws {
        try store.addFolder(path: "/music/house")
        try add("A", "in", path: "/music/house/in.wav")
        try add("B", "sibling", path: "/music/house2/sibling.wav")
        let folder = try XCTUnwrap(store.folders().first)
        try store.removeFolder(id: folder.id)
        XCTAssertEqual(try store.tracks().map(\.title), ["sibling"])
        XCTAssertTrue(try store.folders().isEmpty)
    }

    func testADriveThatRemountsUnderANewNameIsStillOneFolder() throws {
        try store.addFolder(path: "/Volumes/Transcend/Music", volumeUUID: "UUID-1", relativePath: "Music")
        try store.addFolder(path: "/Volumes/Transcend 1/Music", volumeUUID: "UUID-1", relativePath: "Music")
        XCTAssertEqual(try store.folders().map(\.path), ["/Volumes/Transcend 1/Music"])
        try store.addFolder(path: "/Users/me/Music/tiddl")
        try store.addFolder(path: "/Users/me/Music/tiddl")
        XCTAssertEqual(try store.folders().count, 2)
    }
}

final class TrackSortingTests: XCTestCase {
    private func track(_ title: String, bpm: Double?, key: String?) -> Track {
        Track(
            id: Int64(title.unicodeScalars.first?.value ?? 0), source: .local, uri: "file:-:/\(title)", title: title, artist: "", album: "",
            duration: 300, bpm: bpm, key: key, format: "flac", addedAt: Date(timeIntervalSince1970: 0), notes: "", analyzed: true)
    }

    func testTheLastTwoColumnsClickedSortTogether() {
        let tracks = [
            track("a", bpm: 124.3, key: "8A"), track("b", bpm: 124.0, key: "5A"), track("c", bpm: 123.6, key: "6B"),
            track("d", bpm: 108, key: "6A"), track("e", bpm: 108, key: "5B"), track("f", bpm: nil, key: "1A"), track("g", bpm: 125, key: nil),
        ]
        // Key clicked, then BPM: by tempo, and by key among tracks at the same tempo (to the whole beat a minute).
        var levels = TrackSorting.levels(clicking: KeyPathComparator(\Track.sortKey), after: [KeyPathComparator(\Track.artist)])
        levels = TrackSorting.levels(clicking: KeyPathComparator(\Track.sortBPM), after: levels)
        XCTAssertEqual(tracks.sorted(using: TrackSorting.comparators(for: levels)).map(\.title), ["e", "d", "b", "c", "a", "g", "f"])
        XCTAssertEqual(TrackSorting.description(of: levels), "by BPM, then key")

        // BPM clicked again turns the tempo round and keeps the keys in order under it.
        levels = TrackSorting.levels(clicking: KeyPathComparator(\Track.sortBPM, order: .reverse), after: levels)
        XCTAssertEqual(tracks.sorted(using: TrackSorting.comparators(for: levels)).map(\.title), ["f", "g", "b", "c", "a", "e", "d"])

        // Then Key: by key, and by exact tempo within each key.
        levels = TrackSorting.levels(clicking: KeyPathComparator(\Track.sortKey), after: levels)
        let more = tracks + [track("h", bpm: 110, key: "6A")]
        XCTAssertEqual(more.sorted(using: TrackSorting.comparators(for: levels)).map(\.title), ["f", "b", "e", "h", "d", "c", "a", "g"])
        XCTAssertEqual(TrackSorting.description(of: levels), "by key, then BPM")
        XCTAssertNil(TrackSorting.description(of: [KeyPathComparator(\Track.artist)]))
    }
}
