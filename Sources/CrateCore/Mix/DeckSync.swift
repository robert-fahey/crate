import Foundation

/// Keeps a deck in time with the other one.
///
/// One deck is the tempo master: the one that has been playing, until it stops
/// and the other takes over. A synced deck's speed is steered on every
/// control step so that its beats land on the master's beats. Because each
/// track's grid stores every beat, this keeps working while a drummer drifts.
/// Only the beat is matched: lining up bars is done by when the deck is started.
/// A deck that is already playing when Sync is switched on jumps onto the beat.
public final class DeckSync: @unchecked Sendable {
    /// What a deck's beat is doing now.
    public struct Beat: Equatable, Sendable {
        /// Position in beats from the start of the track's grid.
        public var position: Double
        /// Tempo as heard, including the deck's speed.
        public var bpm: Double
        /// 1...4.
        public var beatInBar: Int
    }

    private let engine: DeckEngine
    private let lock = NSLock()
    private var grids: [BeatGrid?] = [nil, nil]
    private var synced = [false, false]
    /// The deck the other follows. It keeps the job until it stops while the other plays, or another is picked.
    private var heldMaster: DeckID?
    /// Whether the master has been seen playing since it got the job. A deck picked while
    /// stopped (to set the tempo for what is playing) is not passed over just for being stopped.
    private var masterHasPlayed = false
    private var errors: [Double?] = [nil, nil]
    /// Decks whose Sync has just been switched on while playing: they jump onto the beat instead of creeping to it.
    private var snapping = [false, false]
    /// How quickly a synced deck closes a timing gap, in seconds. Shorter is tighter but bends the pitch more.
    public var pull = 0.35
    /// The most a synced deck's speed is bent to catch up, as a fraction.
    public var maximumCorrection = 0.06

    public init(engine: DeckEngine) {
        self.engine = engine
        engine.onTick { [weak self] in self?.tick() }
    }

    // MARK: Settings

    public func setGrid(_ grid: BeatGrid?, for deck: DeckID) {
        lock.withLock { grids[deck.rawValue] = grid?.isUsable == true ? grid : nil }
    }

    public func grid(for deck: DeckID) -> BeatGrid? { lock.withLock { grids[deck.rawValue] } }

    public func setSync(_ on: Bool, for deck: DeckID) {
        lock.withLock {
            if on, !synced[deck.rawValue] { snapping[deck.rawValue] = true }
            synced[deck.rawValue] = on
            if !on {
                errors[deck.rawValue] = nil
                snapping[deck.rawValue] = false
            }
        }
    }

    public func isSynced(_ deck: DeckID) -> Bool { lock.withLock { synced[deck.rawValue] } }

    /// The deck held as tempo master. Set it to pick one by hand, or to nil to let Crate pick afresh.
    public var master: DeckID? {
        get { lock.withLock { heldMaster } }
        set {
            lock.withLock {
                heldMaster = newValue
                masterHasPlayed = false
            }
        }
    }

    /// The deck the other one follows right now. With none held, it is a playing deck, for
    /// preference one that is not itself synced. It then stays the master for as long as it
    /// plays. When it stops (paused, or run off the end of its track) and the other deck is
    /// playing, the other deck takes over, and keeps the job when the first starts again.
    public var currentMaster: DeckID? {
        let states = engine.decks.map { $0.state() }
        return lock.withLock {
            func usable(_ id: DeckID) -> Bool { states[id.rawValue].hasTrack && grids[id.rawValue] != nil }
            let playing = DeckID.allCases.filter { states[$0.rawValue].isPlaying && usable($0) }
            if let held = heldMaster, usable(held) {
                if states[held.rawValue].isPlaying {
                    masterHasPlayed = true
                    return held
                }
                guard masterHasPlayed, let next = playing.first(where: { $0 != held }) else { return held }
                heldMaster = next
                return next
            }
            guard let next = playing.first(where: { !synced[$0.rawValue] }) ?? playing.first else { return nil }
            heldMaster = next
            masterHasPlayed = true
            return next
        }
    }

    /// How far a synced deck is from the master's beat, in beats (positive: behind). Nil when not locked.
    public func phaseError(for deck: DeckID) -> Double? { lock.withLock { errors[deck.rawValue] } }

    public func beat(for deck: DeckID) -> Beat? {
        guard let grid = grid(for: deck) else { return nil }
        let state = engine.deck(deck).state()
        guard state.hasTrack else { return nil }
        let position = grid.beatPosition(at: state.position)
        let tempo = engine.deck(deck).value(of: .tempo)
        return Beat(position: position, bpm: grid.bpm(at: state.position) * tempo, beatInBar: grid.beatInBar(Int(position.rounded(.down))))
    }

    // MARK: Starting in time

    /// Starts a deck. If it is synced and the master is playing, it starts a moment
    /// from now exactly on the master's beat, shifted by less than half a beat to get there.
    public func play(_ id: DeckID) {
        let deck = engine.deck(id)
        guard isSynced(id), let master = currentMaster, master != id,
              let grid = grid(for: id), let masterGrid = self.grid(for: master)
        else { return deck.play() }
        let own = deck.state(), other = engine.deck(master).state()
        guard other.isPlaying, !own.isPlaying, own.hasTrack else { return deck.play() }

        // Start a moment from now, so the start is scheduled to the frame rather than "as soon as possible".
        // A deck with key lock is rendered `lead` frames before it is heard, so it needs that much more notice.
        let rate = engine.deck(id).sampleRate
        let now = other.frame - other.frameOffset
        let start = max(now, own.frame - own.frameOffset) + max(1323, own.lead + 1024)
        let masterAtStart = other.position + Double(start - now) / rate * other.speed
        let masterBeat = masterGrid.beatPosition(at: masterAtStart)
        let ownBeat = grid.beatPosition(at: own.position)
        let match = Self.match(master: other, masterGrid: masterGrid, at: masterAtStart, grid: grid, at: own.position)
        // Shift by under half a beat to land on the master's beat; at the very start of a track, later rather than earlier.
        var startBeat = ownBeat + Self.phaseError(master: masterBeat, own: ownBeat, ratio: match.ratio) / match.ratio
        while grid.time(atBeat: startBeat) < 0 { startBeat += 1 }
        let from = grid.time(atBeat: startBeat)
        let at = start + own.frameOffset - own.lead
        deck.set(.tempo, to: match.tempo)
        deck.seek(to: from, at: at)
        deck.play(at: at)
        lock.withLock { snapping[id.rawValue] = false }
    }

    // MARK: Steering

    /// The fractional part of a beat difference, as -0.5..<0.5.
    static func wrap(_ beats: Double) -> Double {
        let fraction = beats - beats.rounded(.down)
        return fraction >= 0.5 ? fraction - 1 : fraction
    }

    /// How many of the master's beats go by for each of a deck's own: 1 as a rule, 2 for a
    /// 67 BPM grid following a 134 BPM one, a half the other way round. It lets a track whose
    /// tempo was read at half or double speed still be mixed without playing at the wrong speed.
    static func beatRatio(masterBPM: Double, ownBPM: Double) -> Double {
        guard masterBPM > 0, ownBPM > 0 else { return 1 }
        return max(0.5, min(2, pow(2, log2(masterBPM / ownBPM).rounded())))
    }

    /// How far a deck is behind the master's beat, in the master's beats.
    static func phaseError(master: Double, own: Double, ratio: Double) -> Double {
        ratio >= 1 ? wrap(master - own * ratio) : wrap(master / ratio - own) * ratio
    }

    /// The speed at which a deck's beats are as long as the master's, and the beat ratio that speed assumes.
    private static func match(master: DeckState, masterGrid: BeatGrid, at masterPosition: Double, grid: BeatGrid, at position: Double) -> (tempo: Double, ratio: Double) {
        let masterBPM = masterGrid.bpm(at: masterPosition) * (master.isPlaying && abs(master.speed) > 0.5 ? master.speed : 1)
        let own = grid.bpm(at: position)
        guard own > 0, masterBPM > 0 else { return (1, 1) }
        let ratio = beatRatio(masterBPM: masterBPM, ownBPM: own)
        return (masterBPM / (own * ratio), ratio)
    }

    func tick() {
        guard let master = currentMaster else { return }
        // The master follows nobody, so it has no distance from anybody's beat (it may have had one, as a follower).
        let (grids, synced) = lock.withLock { () -> ([BeatGrid?], [Bool]) in
            errors[master.rawValue] = nil
            return (self.grids, self.synced)
        }
        guard let masterGrid = grids[master.rawValue] else { return }
        let leader = engine.deck(master).state()
        let rate = engine.deck(master).sampleRate

        for id in DeckID.allCases where id != master && synced[id.rawValue] {
            guard let grid = grids[id.rawValue] else { continue }
            let deck = engine.deck(id)
            let follower = deck.state()
            guard follower.hasTrack, !follower.isScratching else { continue }

            // The master's tempo fader may itself be the tempo reference when it is stopped.
            let masterTempo = engine.deck(master).value(of: .tempo)
            guard leader.isPlaying, !leader.isScratching, abs(leader.speed - masterTempo) < 0.02 * masterTempo else {
                // Master stopped, braking or being scratched: match tempo only.
                if !leader.isPlaying, !follower.isPlaying {
                    let masterBPM = masterGrid.bpm(at: leader.position) * masterTempo
                    let own = grid.bpm(at: follower.position)
                    if own > 0, masterBPM > 0 { deck.set(.tempo, to: masterBPM / (own * Self.beatRatio(masterBPM: masterBPM, ownBPM: own))) }
                }
                lock.withLock { errors[id.rawValue] = nil }
                continue
            }

            // Compare the two decks at the same output frame; their snapshots can be a render apart.
            let leaderFrame = leader.frame - leader.frameOffset, followerFrame = follower.frame - follower.frameOffset
            let common = min(leaderFrame, followerFrame)
            let leaderPosition = leader.position + Double(common - leaderFrame) / rate * leader.speed
            let followerPosition = follower.position + Double(common - followerFrame) / rate * follower.speed

            let match = Self.match(master: leader, masterGrid: masterGrid, at: leaderPosition, grid: grid, at: followerPosition)
            guard follower.isPlaying else {
                deck.set(.tempo, to: match.tempo)
                lock.withLock { errors[id.rawValue] = nil }
                continue
            }
            let ownBeat = grid.beatPosition(at: followerPosition)
            let error = Self.phaseError(master: masterGrid.beatPosition(at: leaderPosition), own: ownBeat, ratio: match.ratio)
            let beatsPerSecond = masterGrid.bpm(at: leaderPosition) / 60 * leader.speed

            // Sync switched on while both decks play: jump onto the beat, by under half a beat,
            // as a DJ expects. Creeping there at a few percent takes seconds and sounds like a mistake.
            let snap = lock.withLock { () -> Bool in
                defer { snapping[id.rawValue] = false }
                return snapping[id.rawValue]
            }
            if snap, abs(error) / max(0.5, beatsPerSecond) > 0.012 {
                let ahead = max(1323, follower.lead + 1024)
                let landing = grid.time(atBeat: ownBeat + error / match.ratio) + Double(ahead) / rate * match.tempo
                if landing >= 0, landing < follower.duration {
                    deck.set(.tempo, to: match.tempo)
                    deck.seek(to: landing, at: common + ahead + follower.frameOffset - follower.lead)
                    lock.withLock { errors[id.rawValue] = 0 }
                    continue
                }
            }
            let correction = max(-maximumCorrection, min(maximumCorrection, error / (pull * max(0.5, beatsPerSecond))))
            deck.set(.tempo, to: match.tempo * (1 + correction), over: 0.02)
            lock.withLock { errors[id.rawValue] = error }
        }
    }
}
