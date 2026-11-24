import CrateCore
import Foundation
import Observation

/// Mixes on request, for the agent and for the auto DJ.
///
/// The agent (or the auto DJ's own fallback) decides what to mix and when;
/// this turns that into a `Transition` on the beat grids and hands it to the
/// runner, which carries it out on the beat.
@MainActor
@Observable
final class MixDirector {
    @ObservationIgnored let mixer: DJMixer
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let runner: TransitionRunner
    @ObservationIgnored weak var agent: AgentSession?

    /// The mix that is scheduled or under way.
    private(set) var status = TransitionRunner.Status()
    /// Auto DJ: tracks that are up next get mixed in rather than started cold.
    var isAuto = false {
        didSet {
            asked = []
            if isAuto { activity = "Auto DJ on" } else { mixCrate = nil }
        }
    }
    /// The crate being played as a mix: its saved transitions are followed, and the agent is not asked.
    private(set) var mixCrate: Crate?
    /// A transition is being tried out from the mix editor.
    private(set) var isPreviewing = false
    /// What the auto DJ last did, shown under the mixer.
    private(set) var activity: String?

    @ObservationIgnored private var autoNotes: String?
    @ObservationIgnored private var asked: Set<Track.ID> = []
    @ObservationIgnored private var lastAutoCheck = Date.distantPast

    /// The agent is asked for the next mix this long before the mix-out point, in seconds.
    static let askAhead = 90.0
    /// With no mix scheduled this close to the mix-out point, the auto DJ mixes in the next track itself.
    static let fallbackAhead = 25.0

    init(mixer: DJMixer, player: PlayerController, store: LibraryStore) {
        self.mixer = mixer
        self.player = player
        self.store = store
        runner = TransitionRunner(engine: mixer.engine, sync: mixer.sync)
        mixer.onPoll = { [weak self] in self?.poll() }
    }

    // MARK: Following the runner

    private func poll() {
        let latest = runner.status
        if latest != status {
            if status.phase == .mixing, latest.phase != .mixing, latest.phase != .armed { activity = isAuto ? "Auto DJ: mixed" : nil }
            status = latest
        }
        if isAuto, Date().timeIntervalSince(lastAutoCheck) > 0.5 {
            lastAutoCheck = Date()
            autoStep()
        }
    }

    var isBusy: Bool { status.phase == .armed || status.phase == .mixing }

    /// A line for the mixer, counted in beats: "Bass Swap in 12", "Bass Swap: 20 left".
    var summary: String? {
        guard let transition = status.transition else { return nil }
        let name = transition.style.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        switch status.phase {
        case .armed: return "\(name) in \(Int(status.beatsToGo.rounded(.up)))"
        case .mixing: return "\(name): \(Int(status.beatsToGo.rounded(.up))) left"
        case .settling: return "Easing back to tempo"
        case .idle: return nil
        }
    }

    func cancel() {
        runner.cancel()
        status = runner.status
    }

    // MARK: A crate's mix

    /// The transition saved for one track going into another: in the crate being played as a mix, or failing
    /// that in any crate where the two are joined.
    private func savedStep(from: Int64, to: Int64) -> MixStep? {
        if let mixCrate, let step = try? store.mixStep(crate: mixCrate.id, from: from, to: to) { return step }
        for crate in (try? store.crates()) ?? [] where crate.id != mixCrate?.id {
            if let step = try? store.mixStep(crate: crate.id, from: from, to: to) { return step }
        }
        return nil
    }

    /// Plays a crate as a mix from one of its tracks: each transition as saved, and Crate's own where none is.
    func playMix(_ crate: Crate, from start: Int = 0) async {
        guard let tracks = try? store.tracks(inCrate: crate.id).filter({ $0.source == .local }), !tracks.isEmpty else { return }
        stopPreview()
        await player.playAndWait(tracks, startingAt: start)
        isAuto = true
        mixCrate = crate
        activity = "Playing the mix of “\(crate.name)”"
    }

    /// Tries a transition out: the outgoing track from two bars before the mix, then the mix itself.
    /// It uses both decks, so it refuses while one of them is playing something else.
    func preview(_ step: MixStep) async throws {
        guard let from = try store.track(id: step.from), let to = try store.track(id: step.to) else { throw ToolError("One of the tracks has gone from the library.") }
        let busy = mixer.decks.filter { $0.isPlaying && $0.track?.id != step.from && $0.track?.id != step.to }
        guard busy.isEmpty || isPreviewing else { throw ToolError("A preview uses both decks. Stop deck \(busy[0].id.name) first.") }
        stopPreview()
        isAuto = false
        do {
            if mixer.deck(.a).track?.id != from.id { try await mixer.load(from, on: .a) }
            if mixer.deck(.b).track?.id != to.id { try await mixer.load(to, on: .b) }
        } catch {
            throw ToolError(Self.reason(error))
        }
        let out = mixer.deck(.a)
        await ensureAnalysed(out)
        await ensureAnalysed(mixer.deck(.b))
        let lead = out.grid.map { 8 * 60 / max(60, $0.bpm) } ?? 4
        out.setTempoOffset(0)
        out.seek(to: max(0, step.outAt - lead))
        mixer.crossfader = 0
        out.play()
        isPreviewing = true
        // The deck has to be seen playing before a mix out of it can be scheduled.
        try? await Task.sleep(nanoseconds: 150_000_000)
        _ = try await schedule(step.request)
    }

    func stopPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        cancel()
        for deck in mixer.decks where deck.isPlaying { deck.pause() }
    }

    // MARK: Scheduling a mix

    private func outgoingDeck() throws -> DeckModel {
        let playing = mixer.decks.filter(\.isPlaying)
        guard let deck = playing.first else { throw ToolError("Nothing is playing on the decks. Start a track first.") }
        guard playing.count == 1 else {
            throw ToolError("Both decks are playing, so there is no single track to mix out of. Use deck_control to finish the mix by hand.")
        }
        return deck
    }

    /// Why a load failed, in words the agent can pass on.
    private static func reason(_ error: Error) -> String {
        error is CancellationError ? "Another track was loaded onto that deck first." : error.localizedDescription
    }

    /// Makes sure a track has its beat grid and waveform, analysing it now if it has not been.
    private func ensureAnalysed(_ deck: DeckModel) async {
        guard deck.needsAnalysis, let track = deck.track else { return }
        let store = self.store
        _ = await Task.detached(priority: .userInitiated) { try? AudioAnalyzer.analyze(track: track, store: store) }.value
        deck.refreshAnalysis()
    }

    func schedule(_ request: MixRequest) async throws -> JSON {
        guard !isBusy else { throw ToolError("A mix is already scheduled or under way. Use mix_cancel first to replace it.") }
        let out = try outgoingDeck()
        let incoming = mixer.deck(out.id.other)
        if let id = request.trackID, incoming.track?.id != id {
            guard let track = try store.track(id: id) else { throw ToolError("There is no track with id \(id).") }
            guard track.id != out.track?.id else { throw ToolError("That track is the one already playing.") }
            do { try await mixer.load(track, on: incoming.id) } catch { throw ToolError(Self.reason(error)) }
        }
        guard let next = incoming.track else { throw ToolError("Deck \(incoming.id.name) is empty. Say which track to bring in.") }
        await ensureAnalysed(out)
        await ensureAnalysed(incoming)
        guard let grid = out.grid else {
            throw ToolError("\"\(out.track?.title ?? "The playing track")\" has no beat grid, so it cannot be mixed on the beat.")
        }
        var style = request.style
        var notes: [String] = []
        if style.overlaps, incoming.grid == nil {
            style = .cut
            notes.append("\"\(next.title)\" has no beat grid, so this will be a cut instead.")
        }

        // When: a bar or phrase line in the outgoing track, far enough ahead to schedule.
        let state = out.deck.state()
        let soonest = state.position + 0.8 * max(0.5, state.speed)
        var startBeat: Double
        switch request.start {
        case .nextBar:
            startBeat = grid.boundary(atOrAfter: soonest, every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)
        case .nextPhrase:
            startBeat = grid.boundary(atOrAfter: soonest, every: BeatGrid.beatsPerPhrase, anchoredAt: grid.phrase)
        case .time(let seconds):
            startBeat = grid.boundary(atOrAfter: max(soonest, seconds), every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)
            if seconds < soonest { notes.append("That point had already gone by, so the mix starts at the next bar.") }
        case .barsFromNow(let bars):
            startBeat = grid.boundary(atOrAfter: soonest, every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)
                + Double(bars * BeatGrid.beatsPerBar)
        }
        // The mix has to fit in what is left of the outgoing track.
        let lastBeat = grid.beatPosition(at: out.duration) - 1
        var beats = request.beats
        if style.overlaps {
            if startBeat + 4 > lastBeat {
                startBeat = grid.boundary(atOrAfter: soonest, every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)
            }
            let room = lastBeat - startBeat
            if room < 4 {
                style = .cut
                notes.append("The track is nearly over, so this will be a cut.")
            } else if beats > room {
                beats = max(4, (room / 4).rounded(.down) * 4)
                notes.append("Shortened to \(Int(beats)) beats to fit before the track ends.")
            }
        } else if startBeat > lastBeat {
            startBeat = grid.boundary(atOrAfter: soonest, every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)
        }

        // Where the new track starts: a bar line at the requested point, or its suggested mix-in.
        var incomingBeat = 0.0
        if let incomingGrid = incoming.grid {
            if let seconds = request.incomingSeconds {
                incomingBeat = incomingGrid.boundary(atOrAfter: seconds, every: BeatGrid.beatsPerBar, anchoredAt: incomingGrid.downbeat)
            } else if let detail = incoming.detail,
                      let mixIn = TrackStructure.analyse(detail: detail, grid: incomingGrid, duration: incoming.duration).mixIn {
                incomingBeat = mixIn.startBeat
            } else {
                incomingBeat = incomingGrid.boundary(atOrAfter: 0, every: BeatGrid.beatsPerBar, anchoredAt: incomingGrid.downbeat)
            }
        }

        let transition = Transition(
            style: style, beats: beats, startBeat: startBeat, incomingBeat: incomingBeat, keepTempo: request.keepTempo)
        do {
            try runner.start(transition, from: out.id)
        } catch {
            throw ToolError(error.localizedDescription)
        }
        status = runner.status
        player.removeFromQueue(next.id)

        let startsAt = grid.time(atBeat: startBeat)
        var result: [String: JSON] = [
            "scheduled": true,
            "style": .string(style.rawValue),
            "from": .string("deck \(out.id.name): \(out.track?.title ?? "")"),
            "into": .string("deck \(incoming.id.name): \(next.title)"),
            "starts_in_seconds": .number(((startsAt - state.position) / max(0.25, state.speed)).rounded()),
            "starts_at": .string(TrackFormat.duration(startsAt)),
            "new_track_from": .string(TrackFormat.duration(incoming.grid?.time(atBeat: incomingBeat) ?? 0)),
        ]
        if style.overlaps { result["beats"] = .number(beats) }
        if !notes.isEmpty { result["notes"] = .array(notes.map(JSON.string)) }
        return .object(result)
    }

    // MARK: Auto DJ

    /// Where to start mixing out of what is playing: the suggested point from the
    /// track's structure, or 48 beats before the end without one.
    private func mixOutBeat(for deck: DeckModel, grid: BeatGrid) -> Double {
        if let detail = deck.detail,
           let phrase = TrackStructure.analyse(detail: detail, grid: grid, duration: deck.duration).mixOut {
            return phrase.startBeat
        }
        return grid.boundary(atOrAfter: max(0, deck.duration - 48 * 60 / max(60, grid.bpm)), every: BeatGrid.beatsPerBar, anchoredAt: grid.downbeat)
    }

    private func autoStep() {
        guard !isBusy else { return }
        let playing = mixer.decks.filter(\.isPlaying)
        guard playing.count == 1, let out = playing.first, let track = out.track, let grid = out.grid else { return }
        let candidates = player.upNext.filter { $0.source == .local }
        guard !candidates.isEmpty else { return }

        let state = out.deck.state()

        // A transition saved for these two is followed as it stands; nobody needs asking.
        // (If it cannot be done, the track is marked as dealt with and Crate mixes out of it its own way below.)
        if !asked.contains(track.id), let step = savedStep(from: track.id, to: candidates[0].id) {
            let seconds = (step.outAt - state.position) / max(0.25, state.speed)
            guard seconds < Self.fallbackAhead else { return }
            activity = "Mixing into \(candidates[0].title) as saved"
            asked.insert(track.id)
            Task {
                do {
                    _ = try await schedule(step.request)
                } catch {
                    activity = "The saved mix into \(candidates[0].title) could not be done: \(error.localizedDescription)"
                }
            }
            return
        }

        let mixOut = mixOutBeat(for: out, grid: grid)
        let seconds = (grid.time(atBeat: mixOut) - state.position) / max(0.25, state.speed)

        if seconds < Self.fallbackAhead {
            // Nobody scheduled a mix in time: bring in the next track in order.
            var request = MixRequest(trackID: candidates[0].id)
            request.start = seconds > 1 ? .time(grid.time(atBeat: mixOut)) : .nextPhrase
            activity = "Auto DJ: mixing in \(candidates[0].title)"
            Task {
                do {
                    _ = try await schedule(request)
                } catch {
                    activity = "Auto DJ could not mix: \(error.localizedDescription)"
                    asked.insert(track.id)
                }
            }
        } else if seconds < Self.askAhead, !asked.contains(track.id) {
            asked.insert(track.id)
            guard let agent, agent.sendAutomatic(autoPrompt(out: out, track: track, mixOutSeconds: grid.time(atBeat: mixOut), secondsAway: seconds, candidates: candidates), label: "Auto DJ asked for the next mix") else {
                return
            }
            activity = "Auto DJ: asked the agent for the next mix"
        }
    }

    private func autoPrompt(out: DeckModel, track: Track, mixOutSeconds: Double, secondsAway: Double, candidates: [Track]) -> String {
        func line(_ candidate: Track) -> String {
            var parts = ["id \(candidate.id)", "\(candidate.artist) – \(candidate.title)"]
            if let bpm = candidate.bpm { parts.append(String(format: "%.1f BPM", bpm)) }
            if let key = candidate.key { parts.append(key) }
            return "- " + parts.joined(separator: ", ")
        }
        var text = """
            [Auto DJ] Deck \(out.id.name) is playing \(track.artist) – \(track.title) \
            (\(out.bpm.map { String(format: "%.1f BPM", $0) } ?? "tempo unknown")\(track.key.map { ", \($0)" } ?? "")), \
            now at \(TrackFormat.duration(out.position)) of \(TrackFormat.duration(out.duration)). Its suggested mix-out point is \
            \(TrackFormat.duration(mixOutSeconds)), about \(Int(secondsAway)) seconds away.

            Choose the next track from the set and schedule the mix now with mix_transition (give "track", and \
            "start_at" if you want a different point). track_structure shows either track's phrases if you want to \
            place it carefully. If you schedule nothing, Crate mixes in the first track on this list with a 32-beat \
            bass swap. Reply in one short line saying what you chose and why.

            Still to play:
            \(candidates.prefix(12).map(line).joined(separator: "\n"))
            """
        if let autoNotes, !autoNotes.isEmpty { text += "\n\nThe DJ's brief for this set: \(autoNotes)" }
        return text
    }
}

// MARK: - What the agent can ask for

extension MixDirector: MixControl {
    private func describe(_ deck: DeckModel) -> JSON {
        guard let track = deck.track else { return ["deck": .string(deck.id.name), "state": "empty"] }
        var result: [String: JSON] = [
            "deck": .string(deck.id.name),
            "track": TrackFormat.json(track),
            "state": deck.isPlaying ? "playing" : "stopped",
            "position": .string(TrackFormat.duration(deck.position)),
            "remaining": .string(TrackFormat.duration(max(0, deck.duration - deck.position))),
            "tempo_percent": .number((deck.tempoOffset * 1000).rounded() / 10),
            "sync": .bool(deck.isSynced),
            "master": .bool(deck.isMaster),
            "key_lock": .bool(deck.keyLock),
            "fader": .number((deck.fader * 100).rounded() / 100),
            "eq": ["low": .number(deck.eq[0]), "mid": .number(deck.eq[1]), "high": .number(deck.eq[2])],
            "filter": .number(deck.filter),
            "has_beat_grid": .bool(deck.grid != nil),
        ]
        if let bpm = deck.bpm { result["bpm_now"] = .number((bpm * 10).rounded() / 10) }
        if let loop = deck.loop {
            result["loop"] = .string("\(TrackFormat.duration(loop.lowerBound)) to \(TrackFormat.duration(loop.upperBound))")
        }
        if let grid = deck.grid {
            let now = grid.beatPosition(at: deck.position)
            let nextPhrase = grid.boundary(atOrAfter: deck.position, every: BeatGrid.beatsPerPhrase, anchoredAt: grid.phrase)
            result["beats_to_next_phrase"] = .number((nextPhrase - now).rounded())
            if deck.isPlaying, let detail = deck.detail,
               let mixOut = TrackStructure.analyse(detail: detail, grid: grid, duration: deck.duration).mixOut {
                result["suggested_mix_out"] = .string(TrackFormat.duration(mixOut.time))
            }
        }
        return .object(result)
    }

    func deckStatus() async -> JSON {
        var result: [String: JSON] = [
            "decks": .array(mixer.decks.map(describe)),
            "crossfader": .number(mixer.crossfader),
            "auto_dj": .bool(isAuto),
            "up_next": .array(player.upNext.prefix(8).map(TrackFormat.json)),
            "recording": .bool(mixer.isRecording),
        ]
        if let summary { result["mix"] = .string(summary) }
        return .object(result)
    }

    func load(trackID: Int64, deck: DeckID?) async throws -> JSON {
        guard let track = try store.track(id: trackID) else { throw ToolError("There is no track with id \(trackID).") }
        let target = deck ?? mixer.freeDeck
        if mixer.deck(target).isPlaying {
            throw ToolError("Deck \(target.name) is playing. Load the other deck, or pause this one first.")
        }
        do { try await mixer.load(track, on: target) } catch { throw ToolError(Self.reason(error)) }
        await ensureAnalysed(mixer.deck(target))
        return describe(mixer.deck(target))
    }

    func control(deck id: DeckID, settings: [String: JSON]) async throws -> JSON {
        let deck = mixer.deck(id)
        guard deck.isLoaded else { throw ToolError("Deck \(id.name) is empty.") }
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let value = settings[key] else { return nil }
            guard let number = value.doubleValue, range.contains(number) else {
                throw ToolError("\"\(key)\" must be a number from \(range.lowerBound) to \(range.upperBound).")
            }
            return number
        }
        // Read everything first, so a bad value changes nothing.
        let seek = try number("seek_seconds", 0...max(1, deck.duration))
        let tempo = try number("tempo_percent", -16...16)
        let low = try number("eq_low", -1...1), mid = try number("eq_mid", -1...1), high = try number("eq_high", -1...1)
        let filter = try number("filter", -1...1), fader = try number("fader", 0...1)
        let loop = try number("loop_beats", 0...64)
        let known: Set<String> = [
            "action", "seek_seconds", "tempo_percent", "sync", "key_lock", "eq_low", "eq_mid", "eq_high", "filter", "fader",
            "loop_beats", "echo", "effect",
        ]
        if let unknown = settings.keys.first(where: { !known.contains($0) }) { throw ToolError("Unknown setting \"\(unknown)\".") }
        let action = settings["action"]?.stringValue, effect = settings["effect"]?.stringValue
        if let action, !["play", "pause", "cue"].contains(action) { throw ToolError("\"action\" must be play, pause or cue.") }
        if let effect, !["echo_out", "cut_echo", "tape_stop", "rewind"].contains(effect) {
            throw ToolError("\"effect\" must be echo_out, cut_echo, tape_stop or rewind.")
        }

        if let seek { deck.seek(to: seek) }
        if let tempo {
            deck.tempoRange = abs(tempo) > 8 ? 0.16 : deck.tempoRange
            deck.setTempoOffset(tempo / 100)
        }
        if let sync = settings["sync"]?.boolValue { deck.isSynced = sync }
        if let keyLock = settings["key_lock"]?.boolValue { deck.keyLock = keyLock }
        if let low { deck.eq[0] = low; deck.kills[0] = false }
        if let mid { deck.eq[1] = mid; deck.kills[1] = false }
        if let high { deck.eq[2] = high; deck.kills[2] = false }
        if let filter { deck.filter = filter }
        if let fader { deck.fader = fader }
        if let loop {
            if deck.loop != nil { deck.toggleLoop() }
            if loop > 0 {
                deck.loopBeats = loop
                deck.startLoop(beats: loop)
            }
        }
        if let echo = settings["echo"]?.boolValue { deck.echoOn = echo }
        switch effect {
        case "echo_out": deck.echoOut()
        case "cut_echo": deck.killEcho()
        case "tape_stop": deck.tapeStop()
        case "rewind": deck.rewind()
        default: break
        }
        switch action {
        case "play": deck.play()
        case "pause": deck.pause()
        case "cue": deck.cue()
        default: break
        }
        return describe(deck)
    }

    func structure(trackID: Int64) async throws -> JSON {
        guard let track = try store.track(id: trackID) else { throw ToolError("There is no track with id \(trackID).") }
        guard track.source == .local else { throw ToolError("Only local tracks have a structure: streaming audio cannot be analysed.") }
        if try store.beatGrid(id: trackID) == nil || (try store.waveDetail(id: trackID)) == nil {
            let store = self.store
            _ = await Task.detached(priority: .userInitiated) { try? AudioAnalyzer.analyze(track: track, store: store) }.value
        }
        guard let grid = try store.beatGrid(id: trackID), let detail = try store.waveDetail(id: trackID) else {
            throw ToolError("Crate could not find a steady beat in \"\(track.title)\", so it has no phrase structure.")
        }
        guard case .object(var result) = TrackStructure.analyse(detail: detail, grid: grid, duration: track.duration).json else { return [:] }
        result["track"] = TrackFormat.json(track)
        return .object(result)
    }

    func transition(_ request: MixRequest) async throws -> JSON { try await schedule(request) }

    func cancelTransition() async -> JSON {
        let was = isBusy
        cancel()
        return ["cancelled": .bool(was)]
    }

    func startAutomix(trackIDs: [Int64], notes: String?) async throws -> JSON {
        let tracks = try store.tracks(ids: trackIDs).filter { $0.source == .local }
        guard !tracks.isEmpty else { throw ToolError("The auto DJ needs local tracks: streaming tracks cannot go on a deck.") }
        autoNotes = notes
        if player.isPlaying {
            let playing = Set(mixer.decks.filter(\.isPlaying).compactMap { $0.track?.id })
            player.setQueue(tracks.filter { !playing.contains($0.id) })
        } else {
            await player.playAndWait(tracks)
        }
        isAuto = true
        var result: [String: JSON] = ["auto_dj": true, "tracks_queued": .number(Double(player.upNext.count))]
        if let current = player.current { result["playing"] = TrackFormat.json(current) }
        return .object(result)
    }

    func stopAutomix() async -> JSON {
        isAuto = false
        activity = nil
        return ["auto_dj": false, "tracks_still_queued": .number(Double(player.upNext.count))]
    }

    func record(_ on: Bool) async throws -> JSON {
        if mixer.isRecording != on { mixer.toggleRecording() }
        if on, !mixer.isRecording { throw ToolError(mixer.problem ?? "Could not start recording.") }
        var result: [String: JSON] = ["recording": .bool(mixer.isRecording)]
        if let url = mixer.lastRecording { result["file"] = .string(url.path) }
        return .object(result)
    }
}
