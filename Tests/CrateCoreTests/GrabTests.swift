import AVFoundation
import XCTest
@testable import CrateCore

final class TiddlTextTests: XCTestCase {
    func testALineIsReadAsALinkAnAddressOrWordsToSearchFor() {
        XCTAssertEqual(Tiddl.reference("https://tidal.com/track/16330447"), .track("16330447"))
        XCTAssertEqual(Tiddl.reference("https://tidal.com/browse/track/16330447?u"), .track("16330447"))
        XCTAssertEqual(Tiddl.reference("  https://listen.tidal.com/album/16330444  "), .album("16330444"))
        // A track on its album's page names both: the track is what was meant.
        XCTAssertEqual(Tiddl.reference("https://tidal.com/browse/album/16330444/track/16330447"), .track("16330447"))
        XCTAssertEqual(
            Tiddl.reference("https://tidal.com/playlist/36ea71a8-445e-41a4-82ab-6628c581535d"),
            .playlist("36ea71a8-445e-41a4-82ab-6628c581535d"))
        XCTAssertEqual(Tiddl.reference("tidal:track:42"), .track("42"))
        XCTAssertEqual(Tiddl.reference("track/42"), .track("42"))
        XCTAssertEqual(Tiddl.reference("Diana Ross - Love Hangover"), .search("Diana Ross Love Hangover"))
        // Words that happen to start like an address are still words.
        XCTAssertEqual(Tiddl.reference("Track/Field Records anthem"), .search("Track/Field Records anthem"))
        XCTAssertEqual(Tiddl.reference("https://tidal.com/artist/10871"), .unsupported("https://tidal.com/artist/10871"))
        XCTAssertEqual(Tiddl.reference("https://tidal.com/track/abc"), .unsupported("https://tidal.com/track/abc"))
        XCTAssertNil(Tiddl.reference("   "))
    }

    func testATracklistLineLosesItsNumberItsTimeAndItsDash() {
        XCTAssertEqual(Tiddl.query(from: "01. Change - Paradise"), "Change Paradise")
        XCTAssertEqual(Tiddl.query(from: "3) Gino Soccio – Dancer"), "Gino Soccio Dancer")
        XCTAssertEqual(Tiddl.query(from: "[1:02:30] Suzi Lane - Harmony"), "Suzi Lane Harmony")
        XCTAssertEqual(Tiddl.query(from: "12:45 - Instant Funk - I Got My Mind Made Up"), "Instant Funk I Got My Mind Made Up")
        XCTAssertEqual(Tiddl.query(from: "07 - Easy Going - Baby I Love You"), "Easy Going Baby I Love You")
        // A number that is the artist's name stays.
        XCTAssertEqual(Tiddl.query(from: "808 State - Pacific"), "808 State Pacific")
        XCTAssertEqual(Tiddl.query(from: "2 Unlimited No Limit"), "2 Unlimited No Limit")
        // A dash inside a word is part of it.
        XCTAssertEqual(Tiddl.query(from: "Trans-Europe Express"), "Trans-Europe Express")
    }

    func testFindsThePythonBehindAnInstalledScript() {
        XCTAssertEqual(
            Tiddl.interpreter(inScriptHead: "#!/Users/me/.local/share/uv/tools/tiddl/bin/python\n# -*- coding: utf-8 -*-\nimport sys\n"),
            "/Users/me/.local/share/uv/tools/tiddl/bin/python")
        // A path with a space in it cannot go on the first line, so the script starts itself through sh.
        XCTAssertEqual(
            Tiddl.interpreter(inScriptHead: "#!/bin/sh\n'''exec' \"/Users/me/My Tools/tiddl/bin/python\" \"$0\" \"$@\"\n' '''\nimport sys\n"),
            "/Users/me/My Tools/tiddl/bin/python")
        XCTAssertNil(Tiddl.interpreter(inScriptHead: "#!/usr/bin/env python3\nimport sys\n"))
        XCTAssertNil(Tiddl.interpreter(inScriptHead: "\u{7F}ELF"))
    }

    func testTheDownloadCommandNamesTheFolderForNewAndOldFilesAndTheTracksById() {
        let arguments = Tiddl.downloadArguments(
            ids: ["16330447", "3684155"], folder: "/Users/me/Music/tiddl", quality: .high,
            template: "{album.artist}/{album.title}/{item.title_version}")
        XCTAssertEqual(arguments, [
            "download", "-q", "high", "-p", "/Users/me/Music/tiddl", "--scan-path", "/Users/me/Music/tiddl",
            "-o", "{album.artist}/{album.title}/{item.title_version}", "url", "track/16330447", "track/3684155",
        ])
        XCTAssertEqual(
            Tiddl.commandLine(Tiddl.downloadArguments(ids: ["7"], folder: "/Volumes/My Drive/it's", quality: .max, template: "")),
            "tiddl download -q max -p '/Volumes/My Drive/it'\\''s' --scan-path '/Volumes/My Drive/it'\\''s' url track/7")
    }

    func testReadsWhatTiddlSaysWentWrong() {
        XCTAssertNil(Tiddl.problem(inOutput: "Auth token expires in 0d 3h 58m\nDownloaded Love Hangover 16-bit, 44.1 kHz /Music/tiddl/Diana Ross\nTotal downloads: 1\n"))
        XCTAssertEqual(Tiddl.problem(inOutput: "Can't stream Love Hangover (16330447)\nTotal downloads: 0"), "TIDAL does not let this track be downloaded.")
        XCTAssertEqual(
            Tiddl.problem(inOutput: "API Error: Asset is not ready for playback, 401/4005 (track/1)\nTotal downloads: 0"),
            "tiddl said: Asset is not ready for playback, 401/4005 (track/1)")
        XCTAssertTrue(Tiddl.problem(inOutput: "AssertionError: Auth Token is missing. Use `tiddl auth login`")?.contains("tiddl auth login") == true)
        XCTAssertTrue(Tiddl.error(for: "Resource not found, 404/2001").message.contains("no such track"))
    }

    func testAMatchThatLooksNothingLikeWhatWasAskedForIsNotTaken() {
        let hangover = Tiddl.Hit(id: "1", title: "Love Hangover", version: "Single Version", artist: "Diana Ross")
        let unrelated = Tiddl.Hit(id: "2", title: "BIGGY BAP", artist: "Skrillex, Wuki")
        XCTAssertEqual(Tiddl.resemblance(of: hangover, to: "diana ross love hangover"), 1)
        XCTAssertEqual(Tiddl.resemblance(of: hangover, to: "Diana Ross Upside Down"), 0.5)
        XCTAssertEqual(Tiddl.resemblance(of: unrelated, to: "zzqx nonsense qqq"), 0)
        // Accents do not count against a match, and a missing apostrophe costs one word of seven.
        XCTAssertEqual(Tiddl.resemblance(of: Tiddl.Hit(id: "3", title: "Déjà Vu", artist: "Beyoncé"), to: "beyonce deja vu"), 1)
        XCTAssertEqual(Tiddl.resemblance(of: Tiddl.Hit(id: "4", title: "Don't You Want My Love", artist: "Debbie Jacobs"), to: "Debbie Jacobs - Dont You Want My Love"), 6.0 / 7, accuracy: 0.01)

        XCTAssertEqual(Tiddl.best(of: [unrelated, hangover], for: "Diana Ross Love Hangover")?.id, "1")
        XCTAssertNil(Tiddl.best(of: [unrelated], for: "zzqx nonsense qqq"))
        var locked = hangover
        locked.isAvailable = false
        XCTAssertNil(Tiddl.best(of: [locked], for: "Diana Ross Love Hangover"), "a track TIDAL will not give is not the best match")
    }

    func testATrackFromTheHelperKeepsItsVersionApartFromItsTitle() throws {
        let hit = try XCTUnwrap(Tiddl.hit([
            "id": "3684155", "title": "Love Hangover", "version": "Extended Alternate Version", "artist": "Diana Ross",
            "album": "Diana", "duration": 624, "bpm": 111, "quality": "LOSSLESS", "available": true,
            "path": "Diana Ross/Diana/Love Hangover (Extended Alternate Version)",
        ]))
        XCTAssertEqual(hit.name, "Diana Ross – Love Hangover (Extended Alternate Version)")
        XCTAssertEqual(hit.uri, "tidal:track:3684155")
        XCTAssertEqual(hit.bpm, 111)
        XCTAssertTrue(hit.isLossless)
        // TIDAL gives 0 for a tempo it does not know.
        XCTAssertNil(Tiddl.hit(["id": "1", "title": "x", "bpm": 0])?.bpm)
        XCTAssertNil(Tiddl.hit(["title": "no id"]))
    }
}

/// Grabbing against a stand-in for tiddl: a script that "downloads" by copying a short file into
/// place, and a helper that answers as tiddl's Python would. Nothing goes near TIDAL.
final class GrabTests: XCTestCase {
    private var folder: URL!
    private var music: String { folder.appendingPathComponent("music").path }
    private var log: URL { folder.appendingPathComponent("calls.log") }
    private var store: LibraryStore!
    private var scanner: LibraryScanner!
    private var grabber: TrackGrabber!
    private var tiddl: Tiddl!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("crate-grab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try LibraryStore(path: ":memory:")
        scanner = LibraryScanner(store: store)
        grabber = TrackGrabber(store: store, scanner: scanner)

        // Three seconds of sound as FLAC, which is what tiddl saves.
        let fixture = folder.appendingPathComponent("fixture.flac")
        let file = try AVAudioFile(forWriting: fixture, settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 132_300))
        buffer.frameLength = 132_300
        for channel in 0..<2 {
            for frame in 0..<132_300 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.3 }
        }
        try file.write(from: buffer)

        let script = folder.appendingPathComponent("tiddl")
        try """
            #!/bin/bash
            echo "$@" >> '\(log.path)'
            folder=""
            while [ $# -gt 0 ]; do
              case "$1" in
                -p) folder="$2"; shift 2;;
                url) shift; break;;
                *) shift;;
              esac
            done
            for item in "$@"; do
              id="${item#track/}"
              if [ "$id" = "404" ]; then echo "Error: Resource not found (track/404)"; continue; fi
              mkdir -p "$folder/Artist/Album"
              cp '\(fixture.path)' "$folder/Artist/Album/Track $id.flac"
              echo "Downloaded Track $id $folder/Artist/Album"
            done
            echo "Total downloads: 1"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        tiddl = Tiddl(executable: script.path, python: "/usr/bin/python3")
        tiddl.helper = """
            import sys, json
            mode, quality, args = sys.argv[1], sys.argv[2], sys.argv[3:]
            def hit(i, path=True):
                h = {"id": str(i), "title": "Track " + str(i), "version": "Extended Mix" if str(i) == "2" else "",
                     "artist": "Artist", "album": "Album", "duration": 3, "bpm": 120, "quality": "LOSSLESS",
                     "available": str(i) != "13"}
                if path: h["path"] = "Artist/Album/Track " + str(i)
                return h
            if mode == "search":
                tracks = [] if args[0] == "nothing" else [hit(1, False), hit(2, False)]
                if args[0] == "unrelated words": tracks = [hit(8, False)]
            elif mode == "tracks":
                tracks = [hit(i) for i in args]
            else:
                tracks = [hit(5, False), hit(6, False)]
            print("something tiddl printed on its own")
            print("CRATE-TIDDL " + json.dumps({"template": "{item.title}", "tracks": tracks}))
            """
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var downloadCalls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testAsksTheHelperAndReadsOnlyItsAnswer() async throws {
        let found = try await tiddl.search("anything")
        XCTAssertEqual(found.map(\.fullTitle), ["Track 1", "Track 2 (Extended Mix)"])
        XCTAssertNil(found[0].path)
        let looked = try await tiddl.tracks(ids: ["7"], quality: .high)
        XCTAssertEqual(looked.hits.first?.path, "Artist/Album/Track 7")
        XCTAssertEqual(looked.template, "{item.title}")
        let album = try await tiddl.tracks(of: .album("9"))
        XCTAssertEqual(album.map(\.id), ["5", "6"])
    }

    func testGrabbingDownloadsIntoTheLibraryAndACrateAndNeverDownloadsTwice() async throws {
        let crate = try store.createCrate(name: "Set")
        let options = TrackGrabber.Options(folder: music, quality: .high, crateID: crate.id)
        let requests = [TrackGrabber.Request(Tiddl.Hit(id: "2", title: "Track 2")), TrackGrabber.Request(Tiddl.Hit(id: "1", title: "Track 1"))]

        let first = await grabber.grab(requests, with: tiddl, options: options)
        guard case .downloaded(let two) = first[0].result, case .downloaded(let one) = first[1].result else {
            return XCTFail("\(first.map(\.result))")
        }
        XCTAssertEqual(two.source, .local)
        XCTAssertEqual(two.path, music + "/Artist/Album/Track 2.flac")
        XCTAssertEqual(two.format, "flac")
        XCTAssertEqual(two.duration, 3, accuracy: 0.1)
        // Looked up by id, the track came back whole.
        XCTAssertEqual(first[0].hit.fullTitle, "Track 2 (Extended Mix)")
        // The folder is now one the library looks after.
        XCTAssertEqual(try store.folders().map(\.path), [music])
        var query = TrackQuery()
        query.crateID = crate.id
        XCTAssertEqual(try store.tracks(query).map(\.id), [two.id, one.id])
        XCTAssertEqual(downloadCalls.count, 2)
        XCTAssertTrue(downloadCalls[0].hasSuffix("-o {item.title} url track/2"), downloadCalls[0])

        let second = await grabber.grab(requests, with: tiddl, options: options)
        XCTAssertEqual(second.map(\.result), [.alreadyHad(two), .alreadyHad(one)])
        XCTAssertEqual(downloadCalls.count, 2, "a file that is there is not downloaded again")
        XCTAssertEqual(try store.tracks().count, 2)
    }

    func testAGrabbedFileTakesItsStreamingTracksPlaceInItsCrates() async throws {
        let before = try store.upsertLocal(ScannedFile(path: "/music/before.wav", title: "Before", duration: 200, format: "wav"))
        let streaming = try store.upsertStreaming(source: .tidal, uri: "tidal:track:1", title: "Track 1", artist: "Artist", album: "Album", duration: 3)
        let after = try store.upsertLocal(ScannedFile(path: "/music/after.wav", title: "After", duration: 200, format: "wav"))
        var notes = TrackPatch()
        notes.notes = "play after the break"
        try store.update(id: streaming, notes)
        let crate = try store.createCrate(name: "Set")
        try store.addToCrate(id: crate.id, trackIDs: [before, streaming, after])

        let outcomes = await grabber.grab(
            [.init(Tiddl.Hit(id: "1", title: "Track 1"), replacing: streaming)], with: tiddl, options: .init(folder: music))
        let file = try XCTUnwrap(outcomes[0].result.track)

        var query = TrackQuery()
        query.crateID = crate.id
        XCTAssertEqual(try store.tracks(query).map(\.id), [before, file.id, after])
        XCTAssertNil(try store.track(id: streaming), "the streaming track has given way to the file")
        XCTAssertEqual(try store.track(id: file.id)?.notes, "play after the break")
    }

    func testReplacingInACrateThatHasBothKeepsOne() throws {
        let a = try store.upsertLocal(ScannedFile(path: "/music/a.wav", title: "A", duration: 200, format: "wav"))
        let b = try store.upsertLocal(ScannedFile(path: "/music/b.wav", title: "B", duration: 200, format: "wav"))
        let crate = try store.createCrate(name: "Both")
        try store.addToCrate(id: crate.id, trackIDs: [a, b])
        XCTAssertEqual(try store.replaceInCrates(track: a, with: b), 1)
        var query = TrackQuery()
        query.crateID = crate.id
        XCTAssertEqual(try store.tracks(query).map(\.id), [b])
        XCTAssertNotNil(try store.track(id: a), "replacing in crates removes nothing from the library")
    }

    func testAFailedDownloadSaysWhyAndTheOthersCarryOn() async throws {
        let outcomes = await grabber.grab(
            [.init(Tiddl.Hit(id: "404", title: "Gone")), .init(Tiddl.Hit(id: "13", title: "Locked")), .init(Tiddl.Hit(id: "3", title: "Fine"))],
            with: tiddl, options: .init(folder: music))
        XCTAssertEqual(outcomes[0].result, .failed("tiddl said: Resource not found (track/404)"))
        XCTAssertEqual(outcomes[1].result, .failed("TIDAL does not let this track be downloaded."))
        XCTAssertNotNil(outcomes[2].result.track)
        XCTAssertEqual(try store.tracks().count, 1)
    }

    func testAHelperThatCannotAnswerFailsEveryTrackWithTheReason() async throws {
        tiddl.helper = "print('CRATE-TIDDL {\"problem\": \"Auth Token is missing. Use `tiddl auth login`\"}')"
        let outcomes = await grabber.grab([.init(Tiddl.Hit(id: "1", title: "x"))], with: tiddl, options: .init(folder: music))
        guard case .failed(let message) = outcomes[0].result else { return XCTFail("\(outcomes[0].result)") }
        XCTAssertTrue(message.contains("not signed in"), message)
        XCTAssertTrue(downloadCalls.isEmpty)
    }

    // MARK: The agent's tools

    private func registry(approve: Bool, seen: @escaping @Sendable (CommandRequest) -> Void = { _ in }) -> ToolRegistry {
        let registry = ToolRegistry()
        let found = tiddl!, folder = music
        GrabTools.register(
            into: registry, context: LibraryToolContext(store: store, scanner: scanner, catalog: StreamingCatalog()), grabber: grabber,
            tiddl: { found }, options: { TrackGrabber.Options(folder: folder) },
            approve: { request in
                seen(request)
                return approve
            })
        return registry
    }

    func testTheAgentSearchesWithoutAsking() async throws {
        let result = await registry(approve: false).call(name: "tiddl_search", args: ["query": "Artist - Track"])
        XCTAssertTrue(result.ok, "\(result.content)")
        XCTAssertEqual(result.content.arrayValue?.map { $0["title"]?.stringValue }, ["Track 1", "Track 2 (Extended Mix)"])
        XCTAssertEqual(result.content.arrayValue?.first?["uri"], "tidal:track:1")
    }

    func testADownloadTheUserDeclinesDoesNotHappen() async throws {
        let result = await registry(approve: false).call(name: "tiddl_grab", args: ["tracks": ["tidal:track:1"]])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.content.stringValue?.contains("declined") == true)
        XCTAssertTrue(downloadCalls.isEmpty)
        XCTAssertEqual(try store.tracks().count, 0)
    }

    func testTheAgentsDownloadIsShownByNameThenLandsInTheCrate() async throws {
        _ = try store.createCrate(name: "Set")
        let shown = Shown()
        let result = await registry(approve: true) { shown.request = $0 }.call(
            name: "tiddl_grab",
            args: ["tracks": ["tidal:track:2", "Artist - Track", "https://tidal.com/album/9", "nothing", "unrelated words"], "crate": "Set"])
        XCTAssertTrue(result.ok, "\(result.content)")
        let request = try XCTUnwrap(shown.request)
        // The user is shown the tracks by name and the command that fetches them.
        XCTAssertEqual(request.reason, "Download 2 tracks from TIDAL: Artist – Track 2 (Extended Mix); Artist – Track 1")
        XCTAssertTrue(request.command.hasPrefix("tiddl download -q high -p "), request.command)
        XCTAssertTrue(request.command.hasSuffix("url track/2 track/1"), request.command)

        XCTAssertEqual(result.content["downloaded"]?.arrayValue?.count, 2)
        XCTAssertEqual(result.content["added_to_crate"], "Set")
        // What could not be done is said, not dropped.
        let problems = try XCTUnwrap(result.content["problems"]?.arrayValue)
        XCTAssertEqual(problems.count, 3)
        // TIDAL offered something for the unrelated words; it is named, and not downloaded.
        XCTAssertEqual(problems[2]["nearest"]?.arrayValue?.first?["uri"], "tidal:track:8")
        XCTAssertFalse(downloadCalls.contains { $0.contains("track/8") })
        XCTAssertEqual(try store.crate(named: "Set")?.trackCount, 2)
    }

    func testWithoutTiddlTheAgentIsToldHowToGetIt() async throws {
        let registry = ToolRegistry()
        GrabTools.register(
            into: registry, context: LibraryToolContext(store: store, scanner: scanner, catalog: StreamingCatalog()), grabber: grabber,
            tiddl: { nil }, options: { TrackGrabber.Options(folder: "/tmp") }, approve: { _ in true })
        let result = await registry.call(name: "tiddl_grab", args: ["tracks": ["x"]])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.content.stringValue?.contains("not installed") == true)
    }
}

private final class Shown: @unchecked Sendable {
    var request: CommandRequest?
}
