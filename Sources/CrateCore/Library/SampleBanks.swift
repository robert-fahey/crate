import Foundation

/// A set of eight sampler pads with a name: what is on each, not the audio itself.
///
/// Each deck has one bank up at a time. A bank can be tied to tracks, and then comes up on a
/// deck when one of them is loaded there. Banks hold paths to files on this Mac, so they stay on it.
public struct SampleBank: Identifiable, Equatable, Sendable {
    /// Pads to a bank.
    public static let size = 8

    /// What is kept of a pad: where its audio is and how it is set.
    public struct Pad: Codable, Equatable, Sendable {
        public var path: String
        public var name: String
        /// A mini deck (goes round until stopped) rather than a one-shot.
        public var loops: Bool
        public var gain: Double
        /// For a stretch of a longer file, as when a loop was taken from a deck.
        public var start: Double?
        public var end: Double?
        /// Nil in what was kept before pads could sync: a loop then syncs.
        public var sync: Bool?
        public var bpm: Double?
        public var firstBeat: Double?

        public init(
            path: String, name: String, loops: Bool = false, gain: Double = 1, start: Double? = nil, end: Double? = nil,
            sync: Bool? = nil, bpm: Double? = nil, firstBeat: Double? = nil
        ) {
            self.path = path
            self.name = name
            self.loops = loops
            self.gain = gain
            self.start = start
            self.end = end
            self.sync = sync
            self.bpm = bpm
            self.firstBeat = firstBeat
        }
    }

    public var id: Int64
    public var name: String
    /// Always `size` long; nil is an empty pad.
    public var pads: [Pad?] { didSet { pads = Self.fitted(pads) } }

    public init(id: Int64, name: String, pads: [Pad?] = []) {
        self.id = id
        self.name = name
        self.pads = Self.fitted(pads)
    }

    public var isEmpty: Bool { pads.allSatisfy { $0 == nil } }

    static func fitted(_ pads: [Pad?]) -> [Pad?] {
        pads.count == size ? pads : Array(pads.prefix(size)) + Array(repeating: nil, count: max(0, size - pads.count))
    }
}

extension LibraryStore {
    private func bank(from row: SQLRow) -> SampleBank? {
        guard let id = row.int("id") else { return nil }
        let pads = (row.string("pads")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([SampleBank.Pad?].self, from: $0) }
        return SampleBank(id: id, name: row.string("name") ?? "", pads: pads ?? [])
    }

    private func encoded(_ pads: [SampleBank.Pad?]) -> String {
        (try? JSONEncoder().encode(SampleBank.fitted(pads))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Every bank, in the order they were made.
    public func sampleBanks() throws -> [SampleBank] {
        try db.query("SELECT id, name, pads FROM sample_banks ORDER BY id").compactMap(bank(from:))
    }

    public func sampleBank(id: Int64) throws -> SampleBank? {
        try db.query("SELECT id, name, pads FROM sample_banks WHERE id = ?", [.int(id)]).first.flatMap(bank(from:))
    }

    /// Makes a bank. With no name it is "Bank" and the first number not in use.
    @discardableResult
    public func addSampleBank(name: String? = nil, pads: [SampleBank.Pad?] = []) throws -> SampleBank {
        let taken = Set(try sampleBanks().map(\.name))
        let named = name ?? (1...).lazy.map { "Bank \($0)" }.first { !taken.contains($0) } ?? "Bank"
        try db.execute("INSERT INTO sample_banks (name, pads) VALUES (?, ?)", [.text(named), .text(encoded(pads))])
        return SampleBank(id: db.lastInsertRowID, name: named, pads: pads)
    }

    /// Writes a bank's name and pads.
    public func saveSampleBank(_ bank: SampleBank) throws {
        try db.execute("UPDATE sample_banks SET name = ?, pads = ? WHERE id = ?", [.text(bank.name), .text(encoded(bank.pads)), .int(bank.id)])
    }

    /// Deletes a bank. Tracks it was tied to are tied to none.
    public func deleteSampleBank(id: Int64) throws {
        try db.transaction {
            try db.execute("DELETE FROM track_sample_banks WHERE bank_id = ?", [.int(id)])
            try db.execute("DELETE FROM sample_banks WHERE id = ?", [.int(id)])
        }
    }

    /// The bank that comes up with a track, if it is tied to one.
    public func sampleBankID(forTrack track: Int64) throws -> Int64? {
        try db.query("SELECT bank_id FROM track_sample_banks WHERE track_id = ?", [.int(track)]).first?.int("bank_id")
    }

    /// Ties a track to a bank, or with nil to none. A track has one bank; a bank can have many tracks.
    public func setSampleBank(_ bank: Int64?, forTrack track: Int64) throws {
        if let bank {
            try db.execute(
                "INSERT INTO track_sample_banks (track_id, bank_id) VALUES (?, ?) ON CONFLICT(track_id) DO UPDATE SET bank_id = excluded.bank_id",
                [.int(track), .int(bank)])
        } else {
            try db.execute("DELETE FROM track_sample_banks WHERE track_id = ?", [.int(track)])
        }
    }

    /// The tracks a bank comes up with.
    public func trackIDs(withSampleBank bank: Int64) throws -> [Int64] {
        try db.query("SELECT track_id FROM track_sample_banks WHERE bank_id = ? ORDER BY track_id", [.int(bank)]).compactMap { $0.int("track_id") }
    }
}
