import XCTest
@testable import CrateCore

/// Two (or three) libraries brought into line with each other, joined in memory.
final class SyncTests: XCTestCase {
    /// A clock the test moves by hand, so "earlier" and "later" are certain.
    private final class Clock: @unchecked Sendable {
        var now = 1000.0
    }

    private let clock = Clock()

    private func library(_ name: String) throws -> LibraryStore {
        let store = try LibraryStore(path: ":memory:")
        store.deviceName = name
        store.clock = { [clock] in clock.now }
        return store
    }

    @discardableResult
    private func add(_ title: String, to store: LibraryStore, bpm: Double? = nil) throws -> Int64 {
        try store.upsertLocal(ScannedFile(
            path: "/music/\(store.deviceName)/\(title).wav", title: title, artist: "Artist", duration: 300, bpm: bpm, format: "wav",
            size: 1000, modified: 1, contentID: "c1:1000:\(title)"))
    }

    /// Connects two libraries, lets them talk until neither has anything more to say, and hangs up.
    private func sync(_ first: LibraryStore, _ second: LibraryStore) async throws {
        let (near, far) = MemoryChannel.pair()
        let sessions = [SyncSession(store: first, channel: near), SyncSession(store: second, channel: far)]
        let tasks = sessions.map { session in Task { try? await session.run() } }
        var quiet = 0, last = -1
        while quiet < 6 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let handled = sessions.reduce(0) { $0 + $1.messagesHandled }
            quiet = handled == last ? quiet + 1 : 0
            last = handled
        }
        sessions.forEach { $0.close() }
        for task in tasks { await task.value }
    }

    private func titles(in crate: String, of store: LibraryStore) throws -> [String] {
        guard let found = try store.crate(named: crate) else { return ["<no crate \(crate)>"] }
        var query = TrackQuery()
        query.crateID = found.id
        return try store.tracks(query).map(\.title)
    }

    private func id(_ title: String, in store: LibraryStore) throws -> Int64 {
        try XCTUnwrap(try store.track(contentID: "c1:1000:\(title)")).id
    }

    func testANewMacReceivesTheWholeLibraryAndASecondSyncChangesNothing() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        let one = try add("One", to: studio, bpm: 124), two = try add("Two", to: studio), three = try add("Three", to: studio)
        try studio.setCue(id: one, slot: 2, position: 31.5)
        let grid = BeatGrid(bpm: 124, firstBeat: 0.1, duration: 300).withMarkers().shifted(by: 0.004)
        try studio.setBeatGrid(id: one, grid, edited: true)
        try studio.setAnalysis(id: two, bpm: 120, key: "8A", waveform: Data([1, 2, 3]), detail: WaveDetail(columnsPerSecond: 50, bytes: [9, 8, 7]))
        let crate = try studio.createCrate(name: "Disco")
        try studio.addToCrate(id: crate.id, trackIDs: [three, one])

        try await sync(studio, laptop)

        XCTAssertEqual(try laptop.tracks().map(\.title).sorted(), ["One", "Three", "Two"])
        let arrived = try XCTUnwrap(try laptop.track(contentID: "c1:1000:One"))
        XCTAssertFalse(arrived.isOnThisMac, "the file is still on the other Mac")
        XCTAssertEqual(arrived.bpm, 124)
        XCTAssertEqual(try laptop.cues(id: arrived.id), [2: 31.5])
        XCTAssertEqual(try laptop.beatGrid(id: arrived.id), grid)
        XCTAssertEqual(try titles(in: "Disco", of: laptop), ["Three", "One"])
        XCTAssertEqual(try laptop.holders(of: "c1:1000:One"), [studio.deviceID])
        XCTAssertEqual(try laptop.heldElsewhere()["c1:1000:Two"], ["Studio"])
        XCTAssertTrue(try laptop.unanalyzedLocalTracks().isEmpty, "a track with no file here is not queued for analysis")

        let before = (try studio.syncManifest(), try laptop.syncManifest())
        try await sync(studio, laptop)
        XCTAssertEqual(try studio.syncManifest(), before.0)
        XCTAssertEqual(try laptop.syncManifest(), before.1)
    }

    func testTheLatestChangeToATracksDetailsWinsAndABetterFoundedTempoIsTakenAnyway() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        try add("One", to: studio)
        try add("One", to: laptop)
        try add("Two", to: studio, bpm: 126)      // from a tag
        try laptop.setAnalysis(id: try add("Two", to: laptop), bpm: 63, key: nil, waveform: nil)   // a guess
        var patch = TrackPatch()
        clock.now = 2000
        patch.title = "One (studio's name)"
        try studio.update(id: try id("One", in: studio), patch)
        clock.now = 3000
        patch = TrackPatch()
        patch.notes = "opens the night"
        try laptop.update(id: try id("One", in: laptop), patch)

        try await sync(studio, laptop)
        for store in [studio, laptop] {
            let track = try XCTUnwrap(try store.track(contentID: "c1:1000:One"))
            XCTAssertEqual(track.notes, "opens the night", "the later edit")
            XCTAssertEqual(track.title, "One", "…replaces the earlier one whole, per track")
            XCTAssertEqual(try store.track(contentID: "c1:1000:Two")?.bpm, 126, "a tag beats a guess whichever is newer")
        }
    }

    func testAGridCorrectedByHandBeatsOneAMachineMadeLater() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        let analysed = BeatGrid(bpm: 120, firstBeat: 0.2, duration: 300).withMarkers()
        let corrected = analysed.shiftedHalfBeat()
        try studio.setBeatGrid(id: try add("One", to: studio), corrected, edited: true)
        clock.now = 5000
        try laptop.setBeatGrid(id: try add("One", to: laptop), analysed, edited: false)   // analysed afterwards

        try await sync(studio, laptop)
        XCTAssertEqual(try laptop.beatGrid(id: try id("One", in: laptop)), corrected)
        XCTAssertEqual(try studio.beatGrid(id: try id("One", in: studio)), corrected)

        // Throwing the correction away is a hand's decision too, and the later one.
        clock.now = 6000
        try laptop.setBeatGrid(id: try id("One", in: laptop), analysed, edited: false, discardingEdits: true)
        try await sync(studio, laptop)
        XCTAssertEqual(try studio.beatGrid(id: try id("One", in: studio)), analysed)
    }

    func testACrateChangedOnOneMacIsTakenAndChangedOnBothIsKeptTwice() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        for title in ["One", "Two", "Three", "Four"] { try add(title, to: studio) }
        let crate = try studio.createCrate(name: "Disco")
        try studio.addToCrate(id: crate.id, trackIDs: [try id("One", in: studio), try id("Two", in: studio)])
        try await sync(studio, laptop)
        XCTAssertEqual(try titles(in: "Disco", of: laptop), ["One", "Two"])

        // Changed on the laptop only.
        clock.now = 2000
        let there = try XCTUnwrap(try laptop.crate(named: "Disco"))
        try laptop.addToCrate(id: there.id, trackIDs: [try id("Three", in: laptop)])
        try await sync(studio, laptop)
        XCTAssertEqual(try titles(in: "Disco", of: studio), ["One", "Two", "Three"])
        XCTAssertEqual(try studio.crates().count, 1)

        // Changed on both while apart: the studio first, the laptop later.
        clock.now = 3000
        try studio.removeFromCrate(id: crate.id, trackIDs: [try id("One", in: studio)])
        clock.now = 4000
        try laptop.addToCrate(id: there.id, trackIDs: [try id("Four", in: laptop)])
        try await sync(studio, laptop)
        for store in [studio, laptop] {
            XCTAssertEqual(try store.crates().map(\.name), ["Disco", "Disco (Studio)"], "on \(store.deviceName)")
            XCTAssertEqual(try titles(in: "Disco", of: store), ["One", "Two", "Three", "Four"], "the later change keeps the name")
            XCTAssertEqual(try titles(in: "Disco (Studio)", of: store), ["Two", "Three"], "the earlier one is kept beside it")
        }
        XCTAssertEqual(try studio.crates().map(\.uid), try laptop.crates().map(\.uid))

        let settled = (try studio.syncManifest().crates, try laptop.syncManifest().crates)
        try await sync(studio, laptop)
        XCTAssertEqual(try studio.syncManifest().crates, settled.0, "and that is the end of it")
        XCTAssertEqual(try laptop.syncManifest().crates, settled.1)
        XCTAssertEqual(try laptop.crates().count, 2)
    }

    func testDeletingACrateCarriesOverUnlessTheOtherMacChangedIt() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        try add("One", to: studio)
        let going = try studio.createCrate(name: "Going"), staying = try studio.createCrate(name: "Staying")
        try await sync(studio, laptop)
        XCTAssertEqual(try laptop.crates().count, 2)

        clock.now = 2000
        try studio.deleteCrate(id: going.id)
        try studio.deleteCrate(id: staying.id)
        clock.now = 2500
        try laptop.addToCrate(id: try XCTUnwrap(try laptop.crate(named: "Staying")).id, trackIDs: [try id("One", in: laptop)])
        try await sync(studio, laptop)
        try await sync(studio, laptop)
        for store in [studio, laptop] {
            XCTAssertEqual(try store.crates().map(\.name), ["Staying"], "on \(store.deviceName)")
            XCTAssertEqual(try titles(in: "Staying", of: store), ["One"])
        }
    }

    func testRemovingATrackCarriesOverAndAddingItAgainBringsItBack() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        try add("One", to: studio)
        try add("Two", to: studio)
        try await sync(studio, laptop)

        clock.now = 2000
        try laptop.deleteTracks(ids: [try id("One", in: laptop)])
        try await sync(studio, laptop)
        XCTAssertEqual(try studio.tracks().map(\.title), ["Two"], "removed from the library everywhere")

        clock.now = 3000
        try add("One", to: studio)   // its folder is scanned again
        try await sync(studio, laptop)
        XCTAssertEqual(try laptop.tracks().map(\.title).sorted(), ["One", "Two"])
    }

    func testCratesMadeSeparatelyUnderOneNameAreBothKept() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop")
        try add("One", to: studio)
        try add("Two", to: laptop)
        try studio.addToCrate(id: try studio.createCrate(name: "Warm Up").id, trackIDs: [try id("One", in: studio)])
        try laptop.addToCrate(id: try laptop.createCrate(name: "Warm Up").id, trackIDs: [try id("Two", in: laptop)])
        try await sync(studio, laptop)
        XCTAssertEqual(try studio.crates().map(\.name), ["Warm Up", "Warm Up (Laptop)"])
        XCTAssertEqual(try laptop.crates().map(\.name), ["Warm Up", "Warm Up (Studio)"])
        XCTAssertEqual(try titles(in: "Warm Up (Laptop)", of: studio), ["Two"])
        XCTAssertEqual(Set(try studio.crates().map(\.uid)), Set(try laptop.crates().map(\.uid)))
    }

    func testACrateSharedBeforeItsTracksWereFingerprintedFillsInOnceTheyAre() async throws {
        // As after an upgrade: the crate exists, the files have not been fingerprinted yet.
        let studio = try library("Studio"), laptop = try library("Laptop")
        let one = try studio.upsertLocal(ScannedFile(path: "/music/One.wav", title: "One", duration: 300, format: "wav", size: 10, modified: 1))
        let two = try studio.upsertLocal(ScannedFile(path: "/music/Two.wav", title: "Two", duration: 300, format: "wav", size: 10, modified: 1))
        let crate = try studio.createCrate(name: "Disco")
        try studio.addToCrate(id: crate.id, trackIDs: [one, two])
        try await sync(studio, laptop)
        XCTAssertEqual(try titles(in: "Disco", of: laptop), [], "nothing in it can be named to another Mac yet")

        try studio.setContentID(id: one, "c1:10:one")
        try studio.setContentID(id: two, "c1:10:two")
        try await sync(studio, laptop)
        XCTAssertEqual(try titles(in: "Disco", of: laptop), ["One", "Two"])
        XCTAssertEqual(try titles(in: "Disco", of: studio), ["One", "Two"])
        XCTAssertEqual(try laptop.crates().count, 1, "filling in is not an edit: no second copy")
    }

    func testThreeMacsConverge() async throws {
        let studio = try library("Studio"), laptop = try library("Laptop"), mini = try library("Mini")
        try add("One", to: studio)
        try add("Two", to: mini)
        try studio.addToCrate(id: try studio.createCrate(name: "Disco").id, trackIDs: [try id("One", in: studio)])
        try await sync(studio, laptop)
        try await sync(laptop, mini)     // the mini never meets the studio, but hears of its music through the laptop
        try await sync(laptop, studio)
        for store in [studio, laptop, mini] {
            XCTAssertEqual(try store.tracks().map(\.title).sorted(), ["One", "Two"], "on \(store.deviceName)")
            XCTAssertEqual(try titles(in: "Disco", of: store), ["One"])
        }
    }

    // MARK: Files

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crate-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testAFingerprintTellsFilesApartWithoutReadingThemWhole() throws {
        let folder = try scratch()
        var bytes = Data((0..<3_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let first = folder.appendingPathComponent("a.wav"), second = folder.appendingPathComponent("b.wav")
        try bytes.write(to: first)
        try bytes.write(to: second)
        let print = try XCTUnwrap(Fingerprint.of(path: first.path))
        XCTAssertEqual(Fingerprint.of(path: second.path), print, "the same content anywhere is the same file")
        XCTAssertEqual(Fingerprint.size(of: print), 3_500_000)
        bytes[3_499_000] ^= 0xFF
        try bytes.write(to: second)
        XCTAssertNotEqual(Fingerprint.of(path: second.path), print)
        XCTAssertNil(Fingerprint.of(path: folder.appendingPathComponent("missing.wav").path))
    }

    func testAFileIsFetchedPickedUpAfterAnInterruptionAndChecked() async throws {
        let folder = try scratch()
        let source = folder.appendingPathComponent("Studio/Night Drive.wav"), music = folder.appendingPathComponent("Laptop Music")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((0..<2_300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 251) })
        try bytes.write(to: source)
        let key = try XCTUnwrap(Fingerprint.of(path: source.path))

        let studio = try library("Studio"), laptop = try library("Laptop")
        try studio.upsertLocal(ScannedFile(path: source.path, title: "Night Drive", artist: "Some/One", duration: 300, format: "wav", size: 2_300_000, modified: 1, contentID: key))
        try await sync(studio, laptop)
        XCTAssertEqual(try laptop.track(contentID: key)?.isOnThisMac, false)

        func fetch() async throws -> URL {
            let (near, far) = MemoryChannel.pair()
            let serving = SyncSession(store: studio, channel: far, purpose: "sync")
            let server = Task { try? await serving.run() }
            defer {
                near.close()
                server.cancel()
            }
            let asking = SyncSession(store: laptop, channel: near, purpose: "file")
            try await asking.greet()
            return try await FileTransfer.fetch(key: key, artist: "Some/One", over: near, into: music)
        }

        let incoming = music.appendingPathComponent(".incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let first = try await fetch()
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(first.path, music.appendingPathComponent("Some-One/Night Drive.wav").path, "filed under the artist, with its own name")
        try laptop.attachFile(contentID: key, path: first.path)
        XCTAssertEqual(try laptop.track(contentID: key)?.path, first.path)
        XCTAssertEqual(try laptop.tracks().count, 1, "the copy is the same track, not a second one")

        // An earlier attempt got the first 700 KB and was cut off: only the rest is sent.
        try FileManager.default.removeItem(at: first)
        let part = try partPath(for: key, in: incoming)
        try bytes.prefix(700_000).write(to: part)
        let resumed = try await fetch()
        XCTAssertEqual(try Data(contentsOf: resumed), bytes)

        try FileManager.default.removeItem(at: resumed)
        // Rubbish where the start of the file should be: the copy is refused, not accepted.
        try Data(repeating: 0x55, count: 700_000).write(to: part)
        do {
            _ = try await fetch()
            XCTFail("a damaged copy must not be accepted")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "the bad copy is thrown away")
        }
        let again = try await fetch()
        XCTAssertEqual(try Data(contentsOf: again), bytes)
    }

    /// Where a half-finished copy of a file is kept: found by letting a fetch that cannot finish create it.
    private func partPath(for key: String, in incoming: URL) throws -> URL {
        let (near, far) = MemoryChannel.pair()
        far.close()
        let expectation = expectation(description: "attempt")
        Task {
            _ = try? await FileTransfer.fetch(key: key, artist: "", over: near, into: incoming.deletingLastPathComponent())
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: incoming.path).first { $0.hasSuffix(".part") })
        return incoming.appendingPathComponent(name)
    }
}

/// The same, over a real connection on this Mac: listening, calling, the sharing code, and a file crossing.
final class SyncNetworkTests: XCTestCase {
    private func library(_ name: String) throws -> LibraryStore {
        let store = try LibraryStore(path: ":memory:")
        store.deviceName = name
        return store
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crate-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func service(_ store: LibraryStore, secret: String, port: Int, music: URL, calling: [String] = []) -> SyncService {
        let service = SyncService(store: store, secret: secret, port: port, musicFolder: music)
        service.findsMacsWithTailscale = false
        service.addresses = calling
        addTeardownBlock { service.stop() }
        return service
    }

    private func wait(_ seconds: Double = 6, until condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try condition()
    }

    func testTwoMacsFindEachOtherShareACrateAndPassAFile() async throws {
        let folder = try scratch()
        let source = folder.appendingPathComponent("Studio/Night Drive.wav")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((0..<1_700_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 / 97) })
        try bytes.write(to: source)
        let key = try XCTUnwrap(Fingerprint.of(path: source.path))

        let studio = try library("Studio"), laptop = try library("Laptop")
        let id = try studio.upsertLocal(ScannedFile(path: source.path, title: "Night Drive", artist: "Someone", duration: 300, format: "wav", size: 1_700_000, modified: 1, contentID: key))
        try studio.setAnalysis(id: id, bpm: 122, key: "5A", waveform: Data([4, 5, 6]), detail: WaveDetail(columnsPerSecond: 50, bytes: [1, 2, 3, 4, 5, 6]))
        try studio.setBeatGrid(id: id, BeatGrid(bpm: 122, firstBeat: 0.05, duration: 300).withMarkers(), edited: false)
        try studio.addToCrate(id: try studio.createCrate(name: "Late").id, trackIDs: [id])

        let port = 47900 + Int.random(in: 0..<400) * 2
        let first = service(studio, secret: "amber otter violin", port: port, music: folder.appendingPathComponent("Studio Music"))
        let second = service(laptop, secret: "amber otter violin", port: port + 1, music: folder.appendingPathComponent("Laptop Music"), calling: ["127.0.0.1:\(port)"])
        first.start()
        second.start()

        let synced = try await wait { try laptop.crate(named: "Late")?.trackCount == 1 }
        XCTAssertTrue(synced, "the crate and its track arrived: \(second.problem ?? "no problem reported")")
        XCTAssertEqual(second.connected.map(\.device.name), ["Studio"])
        XCTAssertEqual(first.connected.map(\.device.name), ["Laptop"])
        XCTAssertTrue(second.canFetch(contentID: key))
        XCTAssertFalse(first.canFetch(contentID: key), "the laptop has no file to give")

        let path = try await second.fetch(contentID: key)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        let track = try XCTUnwrap(try laptop.track(contentID: key))
        XCTAssertEqual(track.path, path)
        XCTAssertTrue(track.isOnThisMac)
        XCTAssertTrue(try laptop.folders().contains { $0.path.hasSuffix("Laptop Music") }, "fetched music is in a library folder")
        // The waveforms follow the file, so it is not analysed a second time.
        let analysed = try await wait { try laptop.waveDetail(id: track.id) != nil }
        XCTAssertTrue(analysed)
        XCTAssertTrue(try laptop.unanalyzedLocalTracks().isEmpty)
        // And the studio hears that the laptop can now hand the file over too.
        let known = try await wait { try studio.holders(of: key) == [laptop.deviceID] }
        XCTAssertTrue(known)

        // A change made while connected crosses without anyone asking.
        try laptop.renameCrate(id: try XCTUnwrap(try laptop.crate(named: "Late")).id, to: "Later")
        let renamed = try await wait { try studio.crate(named: "Later") != nil }
        XCTAssertTrue(renamed)
    }

    func testAMacWithTheWrongSharingCodeIsNotLetIn() async throws {
        let folder = try scratch()
        let studio = try library("Studio"), stranger = try library("Stranger")
        try studio.createCrate(name: "Private")
        let port = 48800 + Int.random(in: 0..<400) * 2
        let first = service(studio, secret: "amber otter violin", port: port, music: folder)
        let second = service(stranger, secret: "a guess", port: port + 1, music: folder, calling: ["127.0.0.1:\(port)"])
        first.start()
        second.start()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertTrue(first.connected.isEmpty)
        XCTAssertTrue(second.connected.isEmpty)
        XCTAssertTrue(try stranger.crates().isEmpty)
    }

    func testFindingMacsInTailscalesStatus() {
        let status = """
            {"BackendState":"Running","Self":{"OS":"macOS","Online":true,"TailscaleIPs":["100.64.0.1"]},
             "Peer":{"nodekey:a":{"HostName":"laptop","OS":"macOS","Online":true,"TailscaleIPs":["100.64.0.7","fd7a:115c::7"]},
                     "nodekey:b":{"HostName":"mini","OS":"macOS","Online":false,"TailscaleIPs":["100.64.0.8"]},
                     "nodekey:c":{"HostName":"phone","OS":"iOS","Online":true,"TailscaleIPs":["100.64.0.9"]}}}
            """
        XCTAssertEqual(Tailscale.macs(inStatus: Data(status.utf8)), ["100.64.0.7"], "online Macs only, not this one, by IPv4 address")
        XCTAssertEqual(Tailscale.macs(inStatus: Data("{\"BackendState\":\"Stopped\",\"Peer\":null}".utf8)), [])
        XCTAssertEqual(Tailscale.macs(inStatus: Data()), [])
    }
}
