import Foundation

/// A mix from the deck that is playing into the other one, described as data.
///
/// Whoever decides the mix (the DJ, the agent, the auto DJ) only chooses these
/// values. `TransitionRunner` carries it out on the beat.
public struct Transition: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        /// The incoming track fades up over the first half, the outgoing fades away over the second.
        case blend
        /// The incoming track comes in with its bass out; halfway, the bass swaps from one to the other.
        case bassSwap = "bass_swap"
        /// As a bass swap, with the outgoing track thinned by a rising high-pass filter.
        case filter
        /// The outgoing track drops away on the beat and echoes out while the incoming one starts.
        case echoOut = "echo_out"
        /// A hard switch on the beat.
        case cut
        /// The outgoing track slows to a stop like a tape; the incoming one starts on the next bar.
        case tapeStop = "tape_stop"

        /// Styles where both tracks play together and so must be in time.
        public var overlaps: Bool { self == .blend || self == .bassSwap || self == .filter }
    }

    public var style: Style
    /// How long the mix lasts, in beats. Ignored by the cut and tape stop.
    public var beats: Double
    /// Where in the outgoing track the mix starts, as a beat position in its grid.
    public var startBeat: Double
    /// Where the incoming track starts playing from, as a beat position in its grid.
    public var incomingBeat: Double
    /// True: the incoming track stays at the outgoing track's tempo. False: it eases back to its own over four bars.
    public var keepTempo: Bool

    public init(style: Style = .bassSwap, beats: Double = 32, startBeat: Double, incomingBeat: Double, keepTempo: Bool = false) {
        self.style = style
        self.beats = max(1, beats)
        self.startBeat = startBeat
        self.incomingBeat = incomingBeat
        self.keepTempo = keepTempo
    }

    /// Where each control should be `progress` (0...1) of the way through the mix.
    public struct Levels: Equatable, Sendable {
        public var outgoingFader = 1.0, incomingFader = 1.0
        public var outgoingLow = 1.0, incomingLow = 1.0
        public var outgoingFilter = 0.0
    }

    static func ramp(_ progress: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return progress >= end ? 1 : 0 }
        return max(0, min(1, (progress - start) / (end - start)))
    }

    public func levels(at progress: Double) -> Levels {
        var levels = Levels()
        // The bass changes hands over about a beat, right in the middle.
        let swap = Self.ramp(progress, from: 0.5 - 0.5 / beats, to: 0.5 + 0.5 / beats)
        switch style {
        case .blend:
            levels.incomingFader = Self.ramp(progress, from: 0, to: 0.5)
            levels.outgoingFader = 1 - Self.ramp(progress, from: 0.5, to: 1)
        case .bassSwap:
            levels.incomingFader = Self.ramp(progress, from: 0, to: 0.25)
            levels.outgoingFader = 1 - Self.ramp(progress, from: 0.75, to: 1)
            levels.incomingLow = swap
            levels.outgoingLow = 1 - swap
        case .filter:
            levels.incomingFader = Self.ramp(progress, from: 0, to: 0.25)
            levels.outgoingFader = 1 - Self.ramp(progress, from: 0.85, to: 1)
            levels.incomingLow = swap
            levels.outgoingLow = 1 - swap
            levels.outgoingFilter = 0.8 * Self.ramp(progress, from: 0.25, to: 1)
        case .echoOut, .cut, .tapeStop:
            break  // nothing gradual: these happen on one beat
        }
        return levels
    }
}

/// Carries out a `Transition` on the engine: starts the incoming deck exactly
/// on the outgoing deck's beat, moves faders and EQ as the beats go by, and
/// hands over at the end.
public final class TransitionRunner: @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for the outgoing track to reach the start point.
        case armed
        case mixing
        /// The mix is done; the incoming track is easing back to its own tempo.
        case settling
    }

    public struct Status: Equatable, Sendable {
        public var phase = Phase.idle
        public var transition: Transition?
        public var outgoing: DeckID?
        /// Beats until the mix starts (while armed) or until it ends (while mixing).
        public var beatsToGo = 0.0
        public var progress = 0.0

        public init(phase: Phase = .idle, transition: Transition? = nil, outgoing: DeckID? = nil, beatsToGo: Double = 0, progress: Double = 0) {
            self.phase = phase
            self.transition = transition
            self.outgoing = outgoing
            self.beatsToGo = beatsToGo
            self.progress = progress
        }
    }

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let engine: DeckEngine
    private let sync: DeckSync
    private let lock = NSLock()
    private var current = Status()
    private var incomingStarted = false
    private var settleFrom = 1.0
    private var settleStartBeat = 0.0
    /// Called when a mix completes (not when it is cancelled), with the deck now playing.
    public var onFinish: (@Sendable (DeckID) -> Void)?

    public init(engine: DeckEngine, sync: DeckSync) {
        self.engine = engine
        self.sync = sync
        engine.onTick { [weak self] in self?.tick() }
    }

    public var status: Status { lock.withLock { current } }

    /// Schedules a mix out of `outgoing` into the other deck, which must already hold the incoming track.
    public func start(_ transition: Transition, from outgoing: DeckID) throws {
        let incoming = outgoing.other
        guard let grid = sync.grid(for: outgoing) else { throw Failure(message: "The track on deck \(outgoing.name) has no beat grid.") }
        let out = engine.deck(outgoing).state(), other = engine.deck(incoming).state()
        guard out.isPlaying else { throw Failure(message: "Deck \(outgoing.name) is not playing.") }
        guard other.hasTrack else { throw Failure(message: "Deck \(incoming.name) is empty.") }
        if transition.style.overlaps, sync.grid(for: incoming) == nil {
            throw Failure(message: "The track on deck \(incoming.name) has no beat grid, so it cannot be mixed in time. Use a cut.")
        }
        guard !other.isPlaying else { throw Failure(message: "Deck \(incoming.name) is already playing.") }
        let now = grid.beatPosition(at: out.position)
        guard transition.startBeat > now + 0.5 else { throw Failure(message: "That point in the track has already gone by.") }

        // Get the incoming deck ready: at its start point, silent, matched in tempo.
        let deck = engine.deck(incoming)
        if let incomingGrid = sync.grid(for: incoming) {
            deck.seek(to: max(0, incomingGrid.time(atBeat: transition.incomingBeat)))
        }
        deck.endLoop()
        deck.set(.dry, to: 1)
        deck.set(.filter, to: 0)
        deck.set(.eqMid, to: 1)
        deck.set(.eqHigh, to: 1)
        let first = transition.levels(at: 0)
        deck.set(.eqLow, to: transition.style.overlaps ? first.incomingLow : 1)
        var settings = engine.settings
        settings.fader[incoming.rawValue] = transition.style.overlaps ? first.incomingFader : 1
        settings.crossfader = 0
        engine.settings = settings
        sync.master = outgoing
        sync.setSync(false, for: outgoing)
        sync.setSync(transition.style != .tapeStop && sync.grid(for: incoming) != nil, for: incoming)

        lock.withLock {
            current = Status(phase: .armed, transition: transition, outgoing: outgoing, beatsToGo: transition.startBeat - now, progress: 0)
            incomingStarted = false
        }
    }

    /// Stops automating. Everything stays where it is, for the DJ to take over.
    public func cancel() {
        lock.withLock { current = Status() }
    }

    private func finish(_ status: Status, incoming: DeckID) {
        guard let transition = status.transition, let outgoing = status.outgoing else { return }
        // The outgoing deck is done: stop it and put its controls back for next time.
        let old = engine.deck(outgoing)
        old.pause()
        old.set(.eqLow, to: 1)
        old.set(.filter, to: 0)
        var settings = engine.settings
        settings.fader[outgoing.rawValue] = 1
        settings.fader[incoming.rawValue] = 1
        engine.settings = settings
        engine.deck(incoming).set(.eqLow, to: 1)
        sync.setSync(false, for: incoming)
        sync.master = incoming

        let tempo = engine.deck(incoming).value(of: .tempo)
        let settles = !transition.keepTempo && abs(tempo - 1) > 0.0005 && sync.grid(for: incoming) != nil
        lock.withLock {
            if settles {
                settleFrom = tempo
                settleStartBeat = sync.grid(for: incoming)?.beatPosition(at: engine.deck(incoming).state().position) ?? 0
                current.phase = .settling
                current.progress = 1
                current.beatsToGo = 16
            } else {
                current = Status()
            }
        }
        onFinish?(incoming)
    }

    func tick() {
        let (status, started) = lock.withLock { (current, incomingStarted) }
        guard status.phase != .idle, let transition = status.transition, let outgoing = status.outgoing else { return }
        let incoming = outgoing.other

        if status.phase == .settling {
            // Ease back to the track's own tempo over four bars, too slowly to hear as a change.
            guard let grid = sync.grid(for: incoming) else { return cancel() }
            let state = engine.deck(incoming).state()
            let done = (grid.beatPosition(at: state.position) - lock.withLock { settleStartBeat }) / 16
            guard state.isPlaying, done < 1 else {
                if state.isPlaying { engine.deck(incoming).set(.tempo, to: 1) }
                return cancel()
            }
            let from = lock.withLock { settleFrom }
            engine.deck(incoming).set(.tempo, to: from + (1 - from) * max(0, done), over: 0.02)
            lock.withLock { current.beatsToGo = 16 * (1 - max(0, done)) }
            return
        }

        guard let grid = sync.grid(for: outgoing) else { return cancel() }
        let out = engine.deck(outgoing).state()
        // The DJ stopped the outgoing deck, or it ran out: nothing left to mix from.
        guard out.isPlaying || started else { return cancel() }
        let beat = grid.beatPosition(at: out.position)
        let beatsPerSecond = max(0.5, grid.bpm(at: out.position) / 60 * max(0.25, out.speed))
        let rate = engine.deck(outgoing).sampleRate

        /// The output frame at which the outgoing deck is heard reaching a beat.
        func outputFrame(atBeat target: Double) -> Int64 {
            out.frame - out.frameOffset + Int64((grid.time(atBeat: target) - out.position) / max(0.25, out.speed) * rate)
        }
        /// The outgoing deck's own frame for a command that should be heard on that beat.
        func outgoingFrame(atBeat target: Double) -> Int64 {
            outputFrame(atBeat: target) + out.frameOffset - out.lead
        }

        if status.phase == .armed {
            let secondsToGo = (transition.startBeat - beat) / beatsPerSecond
            lock.withLock { current.beatsToGo = transition.startBeat - beat }
            // Schedule the start a fraction of a second ahead, so it lands on the exact frame.
            let other = engine.deck(incoming).state()
            let notice = max(0.12, Double(other.lead + 2048) / rate)
            guard secondsToGo <= notice else { return }
            let at = outputFrame(atBeat: transition.startBeat) + other.frameOffset - other.lead

            switch transition.style {
            case .blend, .bassSwap, .filter:
                engine.deck(incoming).play(at: at)
            case .cut:
                engine.deck(incoming).play(at: at)
                engine.deck(outgoing).pause(at: outgoingFrame(atBeat: transition.startBeat))
            case .echoOut:
                // Feed the echo for the last beat, then drop the deck and let the echo ring.
                let old = engine.deck(outgoing)
                old.set(.echoFrames, to: 0.5 / beatsPerSecond * rate)
                old.set(.echoFeedback, to: 0.7)
                old.set(.echoSend, to: 1)
                let drop = outgoingFrame(atBeat: transition.startBeat)
                old.set(.dry, to: 0, at: drop)
                old.set(.echoSend, to: 0, at: drop)
                engine.deck(incoming).play(at: at)
            case .tapeStop:
                let old = engine.deck(outgoing)
                old.pause(brake: 2 / beatsPerSecond, at: outgoingFrame(atBeat: transition.startBeat))
                // The new track comes in after a bar, at its own tempo.
                engine.deck(incoming).set(.tempo, to: 1)
                engine.deck(incoming).play(at: at + Int64(4 / beatsPerSecond * rate))
            }
            lock.withLock {
                incomingStarted = true
                current.phase = .mixing
            }
            return
        }

        // Mixing.
        let length = transition.style.overlaps ? transition.beats : (transition.style == .cut ? 0.5 : 8)
        let progress = (beat - transition.startBeat) / length
        lock.withLock {
            current.progress = max(0, min(1, progress))
            current.beatsToGo = max(0, length * (1 - progress))
        }
        if transition.style.overlaps {
            let levels = transition.levels(at: max(0, min(1, progress)))
            var settings = engine.settings
            if settings.fader[outgoing.rawValue] != levels.outgoingFader || settings.fader[incoming.rawValue] != levels.incomingFader {
                settings.fader[outgoing.rawValue] = levels.outgoingFader
                settings.fader[incoming.rawValue] = levels.incomingFader
                engine.settings = settings
            }
            engine.deck(outgoing).set(.eqLow, to: levels.outgoingLow, over: 0.02)
            engine.deck(incoming).set(.eqLow, to: levels.incomingLow, over: 0.02)
            engine.deck(outgoing).set(.filter, to: levels.outgoingFilter, over: 0.02)
        }
        // Where the outgoing deck has stopped itself (cut, tape stop) its beat no longer advances: go by the new deck.
        let incomingPlaying = engine.deck(incoming).state().isPlaying
        let finished = transition.style.overlaps ? progress >= 1 : (incomingPlaying && (progress >= 1 || !out.isPlaying))
        if finished {
            if transition.style == .echoOut {
                engine.deck(outgoing).set(.dry, to: 1)
                engine.deck(outgoing).clearEcho()
            }
            finish(lock.withLock { current }, incoming: incoming)
        }
    }
}
