import CrateCore
import Foundation
import Observation

/// The mix history as the window shows it, and the watching of the decks that fills it in.
@MainActor
@Observable
final class HistoryModel {
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let mixer: DJMixer
    @ObservationIgnored private let player: PlayerController

    /// Latest first, each with its plays in the order they happened.
    private(set) var sessions: [MixSession] = []
    /// The tracks the plays are of, for showing them.
    private(set) var tracks: [Int64: Track] = [:]
    var problem: String?

    @ObservationIgnored private var log = PlayLog()
    @ObservationIgnored private var lastPoll: TimeInterval?

    init(store: LibraryStore, mixer: DJMixer, player: PlayerController) {
        self.store = store
        self.mixer = mixer
        self.player = player
        reload()
        NotificationCenter.default.addObserver(forName: .mixHistoryDidChange, object: store, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        mixer.afterEachPoll { [weak self] in self?.poll() }
    }

    var playCount: Int { sessions.reduce(0) { $0 + $1.plays.count } }

    func reload() {
        do {
            let loaded = try store.mixSessions()
            var found: [Int64: Track] = [:]
            for play in loaded.flatMap(\.plays) where found[play.trackID] == nil {
                found[play.trackID] = try store.track(id: play.trackID)
            }
            if loaded != sessions { sessions = loaded }
            if found != tracks { tracks = found }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Looks at the decks, about twenty times a second, and writes down any track that has now been played.
    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastPoll.map { now - $0 } ?? 0.05
        lastPoll = now
        let through = DeckEngine.crossfaderGains(mixer.crossfader)
        // Holding Cue to try a track out is not playing it.
        var decks = mixer.decks.map { deck in
            PlayLog.Deck(
                track: deck.track?.id,
                isInTheMix: deck.isPlaying && !deck.isCueing && deck.fader * through[deck.id.rawValue] > 0.05)
        }
        // A Spotify or TIDAL track plays in its own app; it is part of the set all the same.
        decks.append(PlayLog.Deck(track: player.streaming?.id, isInTheMix: player.streamingIsPlaying))
        for entry in log.observe(decks, elapsed: elapsed) {
            let name = entry.deck < mixer.decks.count ? mixer.decks[entry.deck].id.name : (player.streaming?.source.displayName ?? "")
            do {
                try store.addPlay(track: entry.track, deck: name, from: entry.from)
            } catch {
                problem = "A played track could not be added to the history: \(error.localizedDescription)"
            }
        }
    }

    // MARK: What can be done with it

    /// The tracks of a session, in the order played, each once.
    func tracks(of session: MixSession) -> [Track] {
        var seen = Set<Int64>()
        return session.plays.compactMap { play in seen.insert(play.trackID).inserted ? tracks[play.trackID] : nil }
    }

    static func name(of session: MixSession) -> String {
        let day = session.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        return "Set, \(day), \(session.startedAt.formatted(date: .omitted, time: .shortened))"
    }

    /// Makes a crate of a session, in the order played. Returns nil if it could not.
    func saveAsCrate(_ session: MixSession) -> Crate? {
        do {
            var name = Self.name(of: session)
            var number = 2
            while try store.crate(named: name) != nil {
                name = Self.name(of: session) + " (\(number))"
                number += 1
            }
            let crate = try store.createCrate(name: name)
            try store.addToCrate(id: crate.id, trackIDs: tracks(of: session).map(\.id))
            return crate
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func delete(_ session: MixSession) {
        do { try store.deleteMixSession(id: session.id) } catch { problem = error.localizedDescription }
    }

    func delete(_ play: Play) {
        do { try store.deletePlay(id: play.id) } catch { problem = error.localizedDescription }
    }
}
