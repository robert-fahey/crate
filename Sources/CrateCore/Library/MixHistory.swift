import Foundation

/// One track having been played in the mix.
public struct Play: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// The session it belongs to.
    public var session: Int64
    public var trackID: Int64
    public var playedAt: Date
    /// "A" or "B", or the service a streaming track played through.
    public var deck: String
    /// The track it was mixed in from: the one already playing as it came in. Nil for a track started cold.
    public var fromTrackID: Int64?
}

/// One sitting at the decks: the tracks played, in order.
public struct MixSession: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var plays: [Play]

    public var startedAt: Date { plays.first?.playedAt ?? Date(timeIntervalSince1970: TimeInterval(id)) }
    public var lastPlayedAt: Date { plays.last?.playedAt ?? startedAt }
}

/// Decides when a track on a deck has been played, as opposed to loaded, cued up or tried out.
///
/// A track counts once it has been in the mix (playing, with its fader and the crossfader letting
/// it through) for half a minute in all. What it was mixed in from is the track that was in the mix
/// as it arrived, or that had only just left: a blend and a cut both count; a track started after
/// a silence was started cold.
public struct PlayLog: Sendable {
    /// How long a track has to be in the mix before it counts, in seconds.
    public static let threshold = 30.0
    /// How long after one track leaves the mix the next still counts as following it.
    public static let handover = 5.0

    /// What one deck is doing.
    public struct Deck: Equatable, Sendable {
        public var track: Int64?
        /// Playing, and let through by its fader and the crossfader.
        public var isInTheMix: Bool

        public init(track: Int64?, isInTheMix: Bool) {
            self.track = track
            self.isInTheMix = isInTheMix
        }
    }

    public struct Entry: Equatable, Sendable {
        public var track: Int64
        /// Which of the decks given to `observe`, by position.
        public var deck: Int
        public var from: Int64?
    }

    private struct State: Sendable {
        var track: Int64?
        var inTheMix = 0.0
        var counted = false
        var from: Int64?
    }

    private var states: [State] = []
    private var clock = 0.0
    /// When each track that has counted was last in the mix, by the log's own clock.
    private var lastHeard: [Int64: Double] = [:]

    public init() {}

    /// Takes what the decks are doing now, `elapsed` seconds after the last time, and gives the
    /// tracks that have just come to count as played.
    public mutating func observe(_ decks: [Deck], elapsed: Double) -> [Entry] {
        let elapsed = max(0, min(5, elapsed))
        clock += elapsed
        if states.count != decks.count { states = decks.map { State(track: $0.track) } }
        var entries: [Entry] = []
        for (index, deck) in decks.enumerated() {
            if states[index].track != deck.track { states[index] = State(track: deck.track) }
            guard let track = deck.track, deck.isInTheMix else { continue }
            if states[index].inTheMix == 0 {
                // Arriving: what was in the mix until now, or until a moment ago?
                let before = lastHeard.filter { $0.key != track && clock - $0.value <= Self.handover + elapsed }
                states[index].from = before.max { $0.value < $1.value }?.key
            }
            states[index].inTheMix += elapsed
            if states[index].counted {
                lastHeard[track] = clock
            } else if states[index].inTheMix >= Self.threshold {
                states[index].counted = true
                lastHeard[track] = clock
                entries.append(Entry(track: track, deck: index, from: states[index].from))
            }
        }
        // Only what was heard lately can be mixed out of.
        lastHeard = lastHeard.filter { clock - $0.value <= 60 }
        return entries
    }
}

extension LibraryStore {
    /// A play this long after the one before starts a new session.
    public static let sessionGap: TimeInterval = 3600

    /// Records a track as played, in the session under way or a new one.
    @discardableResult
    public func addPlay(track: Int64, deck: String, from: Int64? = nil, at date: Date = Date()) throws -> Play {
        let time = date.timeIntervalSince1970
        let last = try db.query("SELECT session, played_at FROM plays ORDER BY played_at DESC, id DESC LIMIT 1").first
        var session = Int64(time)
        if let last, let previous = last.double("played_at"), let under = last.int("session"),
           time >= previous, time - previous <= Self.sessionGap {
            session = under
        }
        // Mixed in from a track that has since left the library: started cold, as far as anyone can now tell.
        let known = try from.flatMap { try self.track(id: $0) }?.id
        try db.execute(
            "INSERT INTO plays (session, track_id, played_at, deck, from_track) VALUES (?, ?, ?, ?, ?)",
            [.int(session), .int(track), .double(time), .text(deck), known.map { .int($0) } ?? .null])
        let play = Play(id: db.lastInsertRowID, session: session, trackID: track, playedAt: date, deck: deck, fromTrackID: known)
        NotificationCenter.default.post(name: .mixHistoryDidChange, object: self)
        return play
    }

    /// The sessions, latest first, each with its plays in the order they happened.
    public func mixSessions(limit: Int? = nil) throws -> [MixSession] {
        var sql = "SELECT id, session, track_id, played_at, deck, from_track FROM plays"
        var arguments: [SQLValue] = []
        if let limit {
            sql += " WHERE session IN (SELECT DISTINCT session FROM plays ORDER BY session DESC LIMIT ?)"
            arguments.append(.int(Int64(limit)))
        }
        sql += " ORDER BY session DESC, played_at, id"
        var sessions: [MixSession] = []
        for row in try db.query(sql, arguments) {
            guard let id = row.int("id"), let session = row.int("session"), let track = row.int("track_id") else { continue }
            let play = Play(
                id: id, session: session, trackID: track, playedAt: Date(timeIntervalSince1970: row.double("played_at") ?? 0),
                deck: row.string("deck") ?? "", fromTrackID: row.int("from_track"))
            if sessions.last?.id == session {
                sessions[sessions.count - 1].plays.append(play)
            } else {
                sessions.append(MixSession(id: session, plays: [play]))
            }
        }
        return sessions
    }

    /// Every time a track was played, latest first.
    public func plays(of track: Int64) throws -> [Play] {
        try mixSessions().flatMap(\.plays).filter { $0.trackID == track }.sorted { $0.playedAt > $1.playedAt }
    }

    public func deletePlay(id: Int64) throws {
        try db.execute("DELETE FROM plays WHERE id = ?", [.int(id)])
        NotificationCenter.default.post(name: .mixHistoryDidChange, object: self)
    }

    public func deleteMixSession(id: Int64) throws {
        try db.execute("DELETE FROM plays WHERE session = ?", [.int(id)])
        NotificationCenter.default.post(name: .mixHistoryDidChange, object: self)
    }
}

extension Notification.Name {
    public static let mixHistoryDidChange = Notification.Name("CrateMixHistoryDidChange")
}
