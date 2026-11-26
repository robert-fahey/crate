import XCTest
@testable import CrateCore

final class SampleBankTests: XCTestCase {
    private var store: LibraryStore!

    override func setUpWithError() throws {
        store = try LibraryStore(path: ":memory:")
    }

    @discardableResult
    private func add(_ title: String) throws -> Int64 {
        try store.upsertLocal(ScannedFile(path: "/music/\(title).flac", title: title, artist: "Artist", duration: 300, bpm: 120, key: "8A", format: "flac"))
    }

    private let horn = SampleBank.Pad(path: "/samples/horn.wav", name: "Horn")
    private let drums = SampleBank.Pad(path: "/samples/drums 124bpm.wav", name: "Drums", loops: true, gain: 0.5, start: 1, end: 3, sync: true, bpm: 124, firstBeat: 0.1)

    func testABankKeepsItsNameAndItsEightPads() throws {
        XCTAssertEqual(try store.sampleBanks(), [], "a new library has none")
        let first = try store.addSampleBank()
        let second = try store.addSampleBank()
        XCTAssertEqual([first.name, second.name], ["Bank 1", "Bank 2"], "named by the first number free")
        XCTAssertEqual(first.pads.count, 8)
        XCTAssertTrue(first.isEmpty)

        var bank = first
        bank.name = "Disco tools"
        bank.pads[0] = horn
        bank.pads[7] = drums
        try store.saveSampleBank(bank)
        let read = try XCTUnwrap(store.sampleBank(id: first.id))
        XCTAssertEqual(read, bank, "every setting of a pad comes back")
        XCTAssertEqual(read.pads[7]?.bpm, 124)
        XCTAssertNil(read.pads[3])
        XCTAssertEqual(try store.sampleBanks().map(\.name), ["Disco tools", "Bank 2"], "in the order made")
        XCTAssertEqual(try store.addSampleBank().name, "Bank 1", "the number is free again")

        // However many pads it is given, a bank has eight.
        XCTAssertEqual(try store.addSampleBank(name: "Long", pads: Array(repeating: horn, count: 11)).pads.count, 8)
        XCTAssertEqual(SampleBank(id: 1, name: "Short", pads: [horn]).pads.count, 8)
    }

    func testABankCanBeTiedToTracksAndATrackToOneBank() throws {
        let a = try add("A"), b = try add("B"), c = try add("C")
        let tools = try store.addSampleBank(name: "Tools"), vocals = try store.addSampleBank(name: "Vocals")
        XCTAssertNil(try store.sampleBankID(forTrack: a))

        try store.setSampleBank(tools.id, forTrack: a)
        try store.setSampleBank(tools.id, forTrack: b)
        XCTAssertEqual(try store.sampleBankID(forTrack: a), tools.id)
        XCTAssertEqual(try store.trackIDs(withSampleBank: tools.id), [a, b], "one bank for several tracks")
        XCTAssertNil(try store.sampleBankID(forTrack: c))

        try store.setSampleBank(vocals.id, forTrack: a)
        XCTAssertEqual(try store.sampleBankID(forTrack: a), vocals.id, "tying it to another unties it from the first")
        XCTAssertEqual(try store.trackIDs(withSampleBank: tools.id), [b])

        try store.setSampleBank(nil, forTrack: a)
        XCTAssertNil(try store.sampleBankID(forTrack: a))
    }

    func testDeletingABankOrATrackUntiesThem() throws {
        let a = try add("A"), b = try add("B")
        let tools = try store.addSampleBank(name: "Tools"), vocals = try store.addSampleBank(name: "Vocals")
        try store.setSampleBank(tools.id, forTrack: a)
        try store.setSampleBank(vocals.id, forTrack: b)

        try store.deleteSampleBank(id: tools.id)
        XCTAssertNil(try store.sampleBank(id: tools.id))
        XCTAssertNil(try store.sampleBankID(forTrack: a), "the track is still there, with no bank")
        XCTAssertNotNil(try store.track(id: a))
        XCTAssertEqual(try store.sampleBankID(forTrack: b), vocals.id, "other banks are untouched")

        try store.deleteTracks(ids: [b])
        XCTAssertEqual(try store.trackIDs(withSampleBank: vocals.id), [])
        XCTAssertNotNil(try store.sampleBank(id: vocals.id), "the bank outlives its track")
    }

    func testATrackThatTakesAnothersPlaceTakesItsBank() throws {
        let stream = try add("Stream"), file = try add("File"), other = try add("Other"), own = try add("Own")
        let tools = try store.addSampleBank(name: "Tools"), vocals = try store.addSampleBank(name: "Vocals")
        try store.setSampleBank(tools.id, forTrack: stream)
        _ = try store.replaceInCrates(track: stream, with: file)
        XCTAssertEqual(try store.sampleBankID(forTrack: file), tools.id)
        XCTAssertNil(try store.sampleBankID(forTrack: stream))

        // A track with a bank of its own keeps it.
        try store.setSampleBank(tools.id, forTrack: other)
        try store.setSampleBank(vocals.id, forTrack: own)
        _ = try store.replaceInCrates(track: other, with: own)
        XCTAssertEqual(try store.sampleBankID(forTrack: own), vocals.id)
    }

    func testThePadsThereWereBeforeBanksBecomeTheFirstBank() throws {
        // A library as the last version left it: no bank tables, and eight pads in a setting.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("crate-banks-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        var old: LibraryStore? = try LibraryStore(path: path)
        let pads = #"[{"path":"/samples/horn.wav","name":"Horn","loops":false,"gain":1},null,{"path":"/samples/break.wav","name":"Break","loops":true,"gain":0.5,"start":4,"end":8}]"#
        old?.setSetting("sampler.pads", pads)
        try old?.db.execute("DROP TABLE track_sample_banks")
        try old?.db.execute("DROP TABLE sample_banks")
        try old?.db.execute("PRAGMA user_version = 9")
        old = nil

        let banks = try LibraryStore(path: path).sampleBanks()
        XCTAssertEqual(banks.count, 1)
        XCTAssertEqual(banks[0].name, "Bank 1")
        XCTAssertEqual(banks[0].pads[0], horn)
        XCTAssertNil(banks[0].pads[1])
        XCTAssertEqual(banks[0].pads[2], SampleBank.Pad(path: "/samples/break.wav", name: "Break", loops: true, gain: 0.5, start: 4, end: 8))
        XCTAssertEqual(banks[0].pads.count, 8)
    }
}
