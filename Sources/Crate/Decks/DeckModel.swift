import AVFoundation
import CrateCore
import Foundation
import Observation

/// One deck as the window sees it: the loaded track, what it is doing, and the
/// actions behind its buttons. The audio itself is `deck`, in the engine.
/// A track fetched from disk, ready to go on a deck. The file is only read from one task at a time.
private struct Fetched: @unchecked Sendable {
    let audio: TrackAudio
    let file: AVAudioFile
}

@MainActor
@Observable
final class DeckModel: Identifiable {
    nonisolated let id: DeckID
    @ObservationIgnored let deck: Deck
    @ObservationIgnored private weak var mixer: DJMixer?
    @ObservationIgnored private let store: LibraryStore

    // The loaded track and what analysis knows about it.
    private(set) var track: Track?
    private(set) var grid: BeatGrid?
    private(set) var detail: WaveDetail?
    private(set) var peaks: Data?
    /// Hot cues by slot, 1...8, in seconds.
    private(set) var cues: [Int: Double] = [:]
    /// Where the Cue button returns to.
    private(set) var cuePoint = 0.0
    var problem: String?

    // Refreshed about twenty times a second from the engine.
    private(set) var position = 0.0
    private(set) var isPlaying = false
    /// A better grid arrived from analysis while the deck was playing; it is taken up when the deck stops.
    @ObservationIgnored private var gridIsWaiting = false
    private(set) var loop: ClosedRange<Double>?
    /// Output level 0...1, falling back gently between peaks.
    private(set) var level: Float = 0
    /// Speed set by the tempo fader or by Sync; 1 is as recorded.
    private(set) var tempo = 1.0
    /// How far from the master's beat, in beats; nil unless synced and locked.
    private(set) var phaseError: Double?
    private(set) var beatInBar: Int?
    private(set) var loadProgress = 1.0
    /// A track on its way from the disk onto this deck.
    private(set) var arriving: Track?
    /// How a track coming from another Mac is getting on ("Fetching from Studio… 40%").
    private(set) var arrivingNote: String?
    /// Counts loads asked for, so that when two overlap the later one wins.
    @ObservationIgnored private var loads = 0
    /// Play was pressed while a track was on its way.
    @ObservationIgnored private var startsOnArrival = false

    // Controls.
    /// The tempo fader's reach either side of zero: 0.08 is ±8%.
    var tempoRange = 0.08
    var isSynced = false { didSet { if !pulling { mixer?.sync.setSync(isSynced, for: id) } } }
    var keyLock = false { didSet { deck.keyLock = keyLock } }
    /// EQ knobs for low, mid and high: -1 is the band gone, 0 flat, 1 is +6 dB.
    var eq: [Double] = [0, 0, 0] { didSet { if !pulling { applyEQ() } } }
    var kills: [Bool] = [false, false, false] { didSet { applyEQ() } }
    /// True while a control is being updated to match the engine, so it is not sent straight back.
    @ObservationIgnored private var pulling = false
    /// -1...1: low-pass to the left, high-pass to the right.
    var filter = 0.0 { didSet { if !pulling { deck.set(.filter, to: filter) } } }
    var fader = 1.0 { didSet { if !pulling { mixer?.applyMixer() } } }
    /// Trim in decibels.
    var trim = 0.0 { didSet { mixer?.applyMixer() } }
    /// The headphones listen to this deck before its fader.
    var cueMonitor = false { didSet { mixer?.applyMixer() } }
    /// Length a new loop gets, in beats.
    var loopBeats = 4.0
    var echoOn = false { didSet { applyEcho() } }
    /// Echo time in beats.
    var echoBeats = 0.5 { didSet { applyEcho() } }
    /// A click on every beat of the grid, for checking the grid by ear.
    var metronome = false { didSet { applyMetronome() } }
    /// Drum attacks in the track, in seconds; filled in when the grid editor opens.
    private(set) var transients: [Double] = []
    private(set) var isAnalysingGrid = false
    private var gridUndo: [BeatGrid] = []
    private var gridRedo: [BeatGrid] = []
    @ObservationIgnored private var isDraggingGrid = false

    init(id: DeckID, deck: Deck, mixer: DJMixer, store: LibraryStore) {
        self.id = id
        self.deck = deck
        self.mixer = mixer
        self.store = store
    }

    var duration: Double { track?.duration ?? 0 }
    var isLoaded: Bool { track != nil }
    /// Tempo as heard now.
    var bpm: Double? {
        if let grid { return grid.bpm(at: position) * tempo }
        return track?.bpm.map { $0 * tempo }
    }
    var isMaster: Bool { mixer?.masterDeck == id }
    /// The tempo fader's position as a fraction: 0.02 is +2%.
    var tempoOffset: Double { tempo - 1 }

    // MARK: Loading

    /// Puts a track on the deck. Finding the file, opening it and reading its first seconds
    /// can take seconds on a slow or sleeping drive, so all of that happens off the main
    /// thread: the interface, and the other deck's controls, carry on meanwhile.
    func load(_ requested: Track) async throws {
        guard requested.source == .local else {
            throw PlaybackError("\(requested.source.displayName) tracks play in their own app and cannot go on a deck.")
        }
        loads += 1
        let ticket = loads
        let wasPlaying = isPlaying
        startsOnArrival = false
        arriving = requested
        arrivingNote = nil
        defer {
            if ticket == loads {
                arriving = nil
                arrivingNote = nil
            }
        }
        // A track whose file is on another of the user's Macs is copied here first.
        var located = requested
        if !requested.isOnThisMac, let fetch = mixer?.fetchFile {
            located = try await fetch(requested) { [weak self] note in
                if self?.loads == ticket { self?.arrivingNote = note }
            }
            guard ticket == loads else { throw CancellationError() }
            arrivingNote = nil
        }
        let track = located
        let engine = mixer?.engine
        let fetched = try await Task.detached(priority: .userInitiated) { () throws -> Fetched in
            guard let path = Volumes.resolvedPath(for: track) else {
                throw PlaybackError(
                    track.volumeUUID != nil
                        ? "\"\(track.title)\" is on a drive that is not connected."
                        : "The file for \"\(track.title)\" has moved or been deleted.")
            }
            do {
                try engine?.start()
                return try TrackAudio.urgently {
                    let opened = try TrackAudio.open(path: path)
                    // Enough to start at once; the rest decodes while it plays.
                    opened.audio.decode(from: opened.file, upTo: Int(opened.audio.sampleRate * 2))
                    return Fetched(audio: opened.audio, file: opened.file)
                }
            } catch {
                throw PlaybackError("Could not load \"\(track.title)\": \(error.localizedDescription)")
            }
        }.value
        // Another track was asked for on this deck while this one was on its way: that one wins.
        guard ticket == loads else { throw CancellationError() }
        // The deck was stopped when this was asked for and has been started since: what is playing is not cut off.
        guard wasPlaying || !deck.state().isPlaying else {
            throw PlaybackError("Deck \(id.name) was started before \"\(track.title)\" had loaded, so it was left alone.")
        }
        deck.track?.cancelDecoding()
        deck.load(fetched.audio)
        Task.detached(priority: .userInitiated) { fetched.audio.decode(from: fetched.file) }

        self.track = track
        gridUndo = []
        gridRedo = []
        transients = []
        isDraggingGrid = false
        if metronome { metronome = false }
        problem = nil
        position = 0
        isPlaying = false
        loop = nil
        cuePoint = 0
        if echoOn { echoOn = false }
        deck.set(.dry, to: 1)
        deck.clearEcho()
        refreshAnalysis()
        // Cue at the first beat of the first bar, where a DJ would want to start.
        if let grid, let first = grid.beats.indices.first(where: { grid.beatInBar($0) == 1 && grid.beats[$0] >= 0 }) {
            cuePoint = grid.beats[first]
            deck.seek(to: cuePoint)
        }
        if startsOnArrival {
            startsOnArrival = false
            arriving = nil
            play()
        }
    }

    func unload() {
        deck.pause()
        deck.track?.cancelDecoding()
        deck.load(nil)
        track = nil
        grid = nil
        detail = nil
        peaks = nil
        cues = [:]
        loop = nil
        isPlaying = false
        position = 0
        mixer?.sync.setGrid(nil, for: id)
    }

    /// Picks up the beat grid, waveform and cues from the library; called again when analysis finishes.
    func refreshAnalysis() {
        guard let track else { return }
        // Mid-drag the grid on screen is ahead of the one in the library; do not snap it back.
        // Nor does a grid change under a deck that is playing: the mix would lurch. It arrives when the deck stops.
        if !isDraggingGrid {
            let stored = try? store.beatGrid(id: track.id)
            if stored != grid {
                if isPlaying, grid != nil {
                    gridIsWaiting = true
                } else {
                    grid = stored
                    applyMetronome()
                }
            }
        }
        detail = try? store.waveDetail(id: track.id)
        peaks = try? store.waveform(id: track.id)
        cues = (try? store.cues(id: track.id)) ?? [:]
        mixer?.sync.setGrid(grid, for: id)
        if let updated = try? store.track(id: track.id) { self.track = updated }
    }

    var needsAnalysis: Bool {
        guard let track else { return false }
        return grid == nil || detail == nil || (try? store.beatGridIsOutdated(id: track.id)) == true
    }

    // MARK: Refresh from the engine

    func poll() {
        let state = deck.state()
        guard track != nil else {
            if level != 0 { level = 0 }
            return
        }
        // Assign only what changed: every assignment redraws whatever reads it.
        if abs(position - state.position) > 0.001 { position = state.position }
        if isPlaying != state.isPlaying {
            isPlaying = state.isPlaying
            if !isPlaying, gridIsWaiting {
                gridIsWaiting = false
                refreshAnalysis()
            }
        }
        if loop != state.loop { loop = state.loop }
        let peak = min(1, state.peak)
        let shown = max(peak, level * 0.8)
        if abs(shown - level) > 0.003 { level = shown }
        let speed = deck.value(of: .tempo)
        if abs(tempo - speed) > 0.00005 { tempo = speed }
        let error = mixer?.sync.phaseError(for: id)
        if phaseError != error { phaseError = error }
        let bar = grid.map { $0.beatInBar(Int($0.beatPosition(at: state.position).rounded(.down))) }
        if beatInBar != bar { beatInBar = bar }
        if abs(loadProgress - state.loadProgress) > 0.01 || (state.loadProgress == 1 && loadProgress != 1) {
            loadProgress = state.loadProgress
        }
        pullControls()
    }

    /// A mix under way moves faders, EQ and filter in the engine; show them where they really are.
    private func pullControls() {
        guard let mixer else { return }
        pulling = true
        defer { pulling = false }
        let level = mixer.engine.settings.fader[id.rawValue]
        if abs(fader - level) > 0.002 { fader = level }
        let params: [DeckParam] = [.eqLow, .eqMid, .eqHigh]
        for band in 0..<3 where !kills[band] {
            let gain = deck.value(of: params[band])
            let knob = gain < 1 ? max(0, gain).squareRoot() - 1 : min(2, gain) - 1
            if abs(eq[band] - knob) > 0.004 { eq[band] = knob }
        }
        let knob = deck.value(of: .filter)
        if abs(filter - knob) > 0.004 { filter = knob }
        let synced = mixer.sync.isSynced(id)
        if isSynced != synced { isSynced = synced }
    }

    // MARK: Transport

    func togglePlay() {
        if arriving != nil, !deck.state().isPlaying {
            startsOnArrival.toggle()
            return
        }
        guard track != nil else { return }
        if deck.state().isPlaying { pause() } else { play() }
    }

    // `isPlaying` is set at once rather than waiting for the next poll, so code
    // that asks straight afterwards (the agent's tools, the play queue) sees it.
    func play() {
        // Play pressed while a track is still coming off the disk means that track: it starts the moment it lands.
        if arriving != nil, !deck.state().isPlaying {
            startsOnArrival = true
            return
        }
        guard track != nil, !deck.state().isPlaying else { return }
        mixer?.sync.play(id)  // starts on the master's beat when synced
        isPlaying = true
    }

    func pause() {
        startsOnArrival = false
        deck.pause()
        isPlaying = false
    }

    /// The Cue button, as on a CDJ: while playing it goes back to the cue point and
    /// stops; while stopped it moves the cue point to where the deck is.
    func cue() {
        guard track != nil else { return }
        let state = deck.state()
        if state.isPlaying {
            pause()
            deck.seek(to: cuePoint)
        } else if abs(state.position - cuePoint) > 0.02 {
            cuePoint = snapped(state.position)
            deck.seek(to: cuePoint)
        }
    }

    /// The nearest beat, when Snap is on and the track has a grid.
    func snapped(_ seconds: Double) -> Double {
        guard mixer?.snap == true, let grid else { return seconds }
        return max(0, grid.nearestBeat(to: seconds))
    }

    /// Moves to another place. While playing with Snap on, the jump keeps the beat:
    /// it lands as far into the new beat as the deck was into the old one.
    func jump(to seconds: Double) {
        guard track != nil else { return }
        let state = deck.state()
        guard state.isPlaying, mixer?.snap == true, let grid else {
            deck.seek(to: state.isPlaying ? seconds : snapped(seconds))
            return
        }
        let now = grid.beatPosition(at: state.position)
        let target = grid.beatPosition(at: seconds).rounded()
        deck.seek(to: max(0, grid.time(atBeat: target + (now - now.rounded(.down)))))
    }

    func seek(to seconds: Double) { deck.seek(to: seconds) }

    // MARK: Tempo

    /// Sets the tempo by hand. Taking the fader on a synced deck takes it out of Sync.
    func setTempoOffset(_ offset: Double) {
        if isSynced, mixer?.masterDeck != id { isSynced = false }
        let clamped = max(-tempoRange, min(tempoRange, offset))
        deck.set(.tempo, to: 1 + clamped)
        tempo = 1 + clamped
    }

    /// Pitch bend: held to nudge the deck ahead or back, released to return.
    func bend(_ amount: Double) { deck.set(.bend, to: amount) }

    func toggleMaster() {
        guard let mixer else { return }
        mixer.sync.master = mixer.sync.master == id ? nil : id
        if mixer.sync.master == id, isSynced { isSynced = false }  // a master follows nobody
        mixer.poll()
    }

    // MARK: Loops

    func toggleLoop() {
        guard track != nil else { return }
        if deck.state().loop != nil {
            deck.endLoop()
        } else {
            startLoop(beats: loopBeats)
        }
    }

    /// Starts a loop of `beats` from the beat the deck is in (or from right here without a grid or Snap).
    func startLoop(beats: Double) {
        guard track != nil else { return }
        let now = deck.state().position
        if let grid {
            let start = mixer?.snap == true ? grid.beatPosition(at: now).rounded(.down) : grid.beatPosition(at: now)
            deck.loop(from: max(0, grid.time(atBeat: start)), to: grid.time(atBeat: start + beats))
        } else if let bpm = track?.bpm, bpm > 0 {
            deck.loop(from: now, to: now + beats * 60 / bpm)
        }
    }

    /// Loops between two moments, as set with a controller's loop in and out buttons.
    func setLoop(from start: Double, to end: Double) {
        guard track != nil, end > start else { return }
        deck.loop(from: start, to: end)
    }

    /// Moves forwards or back by a number of beats, keeping the beat.
    func jump(byBeats beats: Double) {
        guard track != nil else { return }
        let now = deck.state().position
        if let grid {
            deck.seek(to: max(0, min(duration, grid.time(atBeat: grid.beatPosition(at: now) + beats))))
        } else if let bpm = track?.bpm, bpm > 0 {
            deck.seek(to: max(0, min(duration, now + beats * 60 / bpm)))
        }
    }

    func scaleLoop(by factor: Double) {
        loopBeats = max(1.0 / 16, min(64, loopBeats * factor))
        guard let active = deck.state().loop else { return }
        // Keep the start; move the end.
        if let grid {
            let start = grid.beatPosition(at: active.lowerBound)
            deck.loop(from: active.lowerBound, to: grid.time(atBeat: start + loopBeats))
        } else {
            deck.loop(from: active.lowerBound, to: active.lowerBound + (active.upperBound - active.lowerBound) * factor)
        }
    }

    // MARK: Hot cues

    /// Jumps to a hot cue, or sets it here if the slot is empty.
    func hotCue(_ slot: Int) {
        guard let track else { return }
        if let position = cues[slot] {
            jump(to: position)
        } else {
            let position = snapped(deck.state().position)
            cues[slot] = position
            try? store.setCue(id: track.id, slot: slot, position: position)
        }
    }

    func clearHotCue(_ slot: Int) {
        guard let track else { return }
        cues[slot] = nil
        try? store.setCue(id: track.id, slot: slot, position: nil)
    }

    // MARK: Beat grid edits

    /// Applies a change to the grid. Sync and the metronome follow at once;
    /// `persist` also saves it as a hand-edited grid, safe from re-analysis.
    private func apply(_ edited: BeatGrid, persist: Bool) {
        guard let track else { return }
        grid = edited
        mixer?.sync.setGrid(edited, for: id)
        applyMetronome()
        if persist { try? store.setBeatGrid(id: track.id, edited, edited: true) }
    }

    /// One undoable edit to the beat grid.
    func editGrid(_ change: (BeatGrid) -> BeatGrid) {
        guard let grid else { return }
        let edited = change(grid)
        guard edited != grid else { return }
        gridUndo.append(grid)
        gridRedo = []
        apply(edited, persist: true)
    }

    /// A marker drag is many small changes but one edit: it is undone as a whole and saved when it ends.
    func beginGridDrag() {
        guard let grid, !isDraggingGrid else { return }
        isDraggingGrid = true
        gridUndo.append(grid)
        gridRedo = []
    }

    func dragGrid(_ change: (BeatGrid) -> BeatGrid) {
        guard let grid, isDraggingGrid else { return }
        apply(change(grid), persist: false)
    }

    func endGridDrag() {
        guard isDraggingGrid else { return }
        isDraggingGrid = false
        if let grid {
            if gridUndo.last == grid { gridUndo.removeLast() }  // picked up and put straight back
            apply(grid, persist: true)
        }
    }

    var canUndoGrid: Bool { !gridUndo.isEmpty }
    var canRedoGrid: Bool { !gridRedo.isEmpty }

    func undoGrid() {
        guard let grid, let previous = gridUndo.popLast() else { return }
        gridRedo.append(grid)
        apply(previous, persist: true)
    }

    func redoGrid() {
        guard let grid, let next = gridRedo.popLast() else { return }
        gridUndo.append(grid)
        apply(next, persist: true)
    }

    func shiftGrid(milliseconds: Double) { editGrid { $0.shifted(by: milliseconds / 1000) } }

    /// For a grid that sits on the off-beat instead of the kick.
    func shiftGridHalfBeat() { editGrid { $0.shiftedHalfBeat() } }

    func setDownbeatHere() {
        let position = deck.state().position
        editGrid { $0.settingDownbeat(at: position) }
    }

    func scaleGrid(by factor: Double) {
        guard grid != nil, let track else { return }
        editGrid { factor > 1 ? $0.doubled() : $0.halved() }
        if let bpm = grid?.bpm {
            var patch = TrackPatch()
            patch.bpm = .some((bpm * 100).rounded() / 100)
            try? store.update(id: track.id, patch)
        }
    }

    /// Throws away hand edits and tracks the beats afresh. Undoable.
    func revertGridToAnalysed() async {
        guard let track, let path = Volumes.resolvedPath(for: track), !isAnalysingGrid else { return }
        isAnalysingGrid = true
        defer { isAnalysingGrid = false }
        let hint = track.bpmSource == .tag || track.bpmSource == .manual ? track.bpm : nil
        let fresh = await Task.detached(priority: .userInitiated) { () -> BeatGrid? in
            guard let audio = try? AudioAnalyzer.decode(path: path) else { return nil }
            guard let bpm = hint ?? AudioAnalyzer.analyze(audio).bpm?.bpm else { return nil }
            return BeatTracker.track(samples: audio.samples, sampleRate: audio.sampleRate, bpm: bpm)
        }.value
        guard let fresh, self.track?.id == track.id else {
            problem = "Crate could not find a steady beat in this track."
            return
        }
        if let grid { gridUndo.append(grid) }
        gridRedo = []
        self.grid = fresh
        mixer?.sync.setGrid(fresh, for: id)
        applyMetronome()
        try? store.setBeatGrid(id: track.id, fresh, edited: false, discardingEdits: true)
    }

    /// Finds the drum attacks, for the grid editor to show and snap to. Done once per loaded track.
    func loadTransients() async {
        guard transients.isEmpty, let audio = deck.track, let loaded = track?.id else { return }
        // Decoding may still be finishing.
        while audio.progress < 1, track?.id == loaded { try? await Task.sleep(for: .milliseconds(100)) }
        let found = await Task.detached(priority: .userInitiated) { TransientDetector.find(in: audio) }.value
        if track?.id == loaded { transients = found }
    }

    private func applyMetronome() {
        guard let grid, metronome else { return deck.setMetronome(beats: [], accents: [], level: 0) }
        deck.setMetronome(beats: grid.beats, accents: grid.beats.indices.map { grid.beatInBar($0) == 1 }, level: 0.8)
    }

    // MARK: EQ and effects

    /// A knob at -1 removes the band, 0 is flat, 1 doubles it (+6 dB).
    static func gain(forKnob value: Double) -> Double {
        value < 0 ? pow(1 + max(-1, value), 2) : 1 + min(1, value)
    }

    private func applyEQ() {
        let params: [DeckParam] = [.eqLow, .eqMid, .eqHigh]
        for band in 0..<3 {
            deck.set(params[band], to: kills[band] ? 0 : Self.gain(forKnob: eq[band]))
        }
    }

    private var beatSeconds: Double { 60 / max(40, bpm ?? 120) }

    private func applyEcho() {
        deck.set(.echoFrames, to: echoBeats * beatSeconds * deck.sampleRate)
        deck.set(.echoFeedback, to: 0.55)
        deck.set(.echoSend, to: echoOn ? 1 : 0)
    }

    /// Echo out: the deck drops away on the next beat and its last beat repeats into silence.
    func echoOut() {
        guard track != nil, let grid else { return }
        let state = deck.state()
        guard state.isPlaying else { return }
        let rate = deck.sampleRate
        func frame(atBeat beat: Double) -> Int64 {
            state.frame - state.lead + Int64((grid.time(atBeat: beat) - state.position) / max(0.25, state.speed) * rate)
        }
        let next = grid.beatPosition(at: state.position).rounded(.up)
        deck.set(.echoFrames, to: beatSeconds * 0.5 * rate)
        deck.set(.echoFeedback, to: 0.7)
        deck.set(.echoSend, to: 1)
        deck.set(.dry, to: 0, at: frame(atBeat: next))
        deck.set(.echoSend, to: 0, at: frame(atBeat: next))
        deck.pause(at: frame(atBeat: next + 8))
        deck.set(.dry, to: 1, at: frame(atBeat: next + 8))
        if echoOn { echoOn = false }
    }

    /// Cuts the echo tail dead.
    func killEcho() {
        if echoOn { echoOn = false }
        deck.set(.echoSend, to: 0)
        deck.clearEcho()
    }

    /// Slows to a stop like a tape machine being switched off.
    func tapeStop() { deck.pause(brake: 0.9) }

    /// Spins the record backwards hard, then stops.
    func rewind() {
        guard track != nil else { return }
        let state = deck.state()
        deck.spin(speed: -6, reaching: 0.12)
        deck.pause(brake: 0.1, at: state.frame + Int64(0.7 * deck.sampleRate))
    }

    /// Beat repeat: loops a fraction of a beat for as long as the button is held.
    func repeatBeat(_ beats: Double?) {
        if let beats { startLoop(beats: beats) } else { deck.endLoop() }
    }

    // MARK: Scratching (driven by the waveform)

    func beginScratch() { deck.beginScratch(at: deck.state().position) }
    func scratch(to seconds: Double) { deck.scratch(to: seconds) }
    func endScratch() { deck.endScratch(settle: deck.state().isPlaying ? 0.18 : 0.35) }
}

/// The two decks and the mixer between them, for the window.
@MainActor
@Observable
final class DJMixer {
    @ObservationIgnored let engine: DeckEngine
    @ObservationIgnored let sync: DeckSync
    @ObservationIgnored private let store: LibraryStore
    private(set) var decks: [DeckModel] = []

    /// -1 is all deck A, 1 is all deck B.
    var crossfader = 0.0 { didSet { if !pulling { applyMixer() } } }
    @ObservationIgnored private var pulling = false
    var masterVolume = 1.0 { didSet { applyMixer() } }
    /// What the headphones hear: 0 the cued decks, 1 the master mix, both in full at the middle.
    var headphoneMix = 0.5 { didSet { applyMixer() } }
    /// The output has a second pair for headphones (a DJ controller's sound card).
    private(set) var hasHeadphones = false
    private(set) var outputName = ""
    /// Which output to play through: "auto", "system" or a device's identifier.
    var outputChoice: String = UserDefaults.standard.string(forKey: "audio.output") ?? "auto" {
        didSet {
            UserDefaults.standard.set(outputChoice, forKey: "audio.output")
            chooseOutput()
        }
    }
    /// Cues, loops and jumps land on beats.
    var snap = true
    private(set) var masterDeck: DeckID?
    private(set) var masterLevel: Float = 0
    /// Lit for a moment when the master output hit full scale and the limiter stepped in.
    private(set) var isClipping = false
    private(set) var isRecording = false
    private(set) var recordedSeconds = 0.0
    private(set) var lastRecording: URL?
    var problem: String?

    /// Called when a deck plays off the end of its track.
    @ObservationIgnored var onDeckEnded: ((DeckID) -> Void)?
    /// Called after every refresh from the engine.
    @ObservationIgnored var onPoll: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wasPlaying = [false, false]
    @ObservationIgnored private var clipHold = 0
    @ObservationIgnored private var analysing: Set<Track.ID> = []
    @ObservationIgnored private var lastLoaded: DeckID = .b

    init(store: LibraryStore) {
        self.store = store
        // Building a realtime engine cannot throw (only offline setup can); starting it can, and that is reported on load.
        engine = try! DeckEngine()
        sync = DeckSync(engine: engine)
        decks = DeckID.allCases.map { DeckModel(id: $0, deck: engine.deck($0), mixer: self, store: store) }
        engine.onOutputChange = { [weak self] in
            Task { @MainActor in self?.outputChanged() }
        }
        AudioDevices.onChange { [weak self] in
            Task { @MainActor in self?.chooseOutput() }
        }
        chooseOutput()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func deck(_ id: DeckID) -> DeckModel { decks[id.rawValue] }

    func applyMixer() {
        var settings = engine.settings
        settings.crossfader = crossfader
        settings.master = masterVolume
        settings.fader = decks.map(\.fader)
        settings.trim = decks.map { pow(10, $0.trim / 20) }
        settings.cue = decks.map(\.cueMonitor)
        settings.headphoneMix = headphoneMix
        engine.settings = settings
    }

    /// The outputs to offer in Settings.
    var outputs: [AudioOutput] { AudioDevices.outputs() }

    /// Plays through the chosen output: a DJ controller's sound card when "auto" finds one, else the Mac's own.
    /// Called again whenever a device is plugged in or pulled out.
    private func chooseOutput() {
        guard let device = AudioDevices.resolve(outputChoice) else { return }
        let engine = self.engine
        Task {
            // Switching stops and restarts the sound for a moment, which is not for the main thread.
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try engine.setOutputDevice(device.id)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { problem = "Could not play through \(device.name): \(failure)" }
            outputChanged()
        }
    }

    private func outputChanged() {
        hasHeadphones = engine.hasHeadphoneOutput
        let current = engine.outputDevice
        outputName = AudioDevices.outputs().first { $0.id == current }?.name ?? ""
        applyMixer()
    }

    /// The deck you are hearing: the playing one, the louder if both are; otherwise the last one loaded.
    var focus: DeckModel {
        let playing = decks.filter(\.isPlaying)
        if playing.count == 1 { return playing[0] }
        if playing.count == 2 {
            let gains = DeckEngine.crossfaderGains(crossfader)
            return playing.max { $0.fader * gains[$0.id.rawValue] < $1.fader * gains[$1.id.rawValue] } ?? playing[0]
        }
        return deck(lastLoaded)
    }

    /// Where the next track should go: an empty deck, else one that is not playing, else the quieter one.
    var freeDeck: DeckID {
        if let empty = decks.first(where: { !$0.isLoaded && $0.arriving == nil }) { return empty.id }
        let stopped = decks.filter { !$0.isPlaying }
        if stopped.count == 1 { return stopped[0].id }
        if stopped.count == 2 { return lastLoaded.other }
        return focus.id.other
    }

    var isAnyPlaying: Bool { decks.contains(where: \.isPlaying) }

    /// Copies a track's file from another of the user's Macs, telling the caller how it is going,
    /// and returns the track with its file. Set by the app when sharing is available.
    @ObservationIgnored var fetchFile: ((Track, @escaping @MainActor (String) -> Void) async throws -> Track)?

    func load(_ track: Track, on id: DeckID) async throws {
        lastLoaded = id  // at once, so a second track asked for straight after goes to the other deck
        try await deck(id).load(track)
        analyseIfNeeded(deck(id))
    }

    /// A track loaded without its beat grid or waveform jumps the analysis queue.
    private func analyseIfNeeded(_ deck: DeckModel) {
        guard deck.needsAnalysis, let track = deck.track, analysing.insert(track.id).inserted else { return }
        let store = self.store
        Task.detached(priority: .userInitiated) {
            _ = try? AudioAnalyzer.analyze(track: track, store: store)
        }
    }

    /// The library changed: analysis may have finished for a loaded track.
    func refreshAnalysis() {
        for deck in decks where deck.isLoaded { deck.refreshAnalysis() }
    }

    func poll() {
        for deck in decks { deck.poll() }
        let cross = engine.settings.crossfader
        if abs(crossfader - cross) > 0.002 {
            pulling = true
            crossfader = cross
            pulling = false
        }
        let master = sync.currentMaster
        if masterDeck != master { masterDeck = master }

        let peak = min(1.2, engine.takeMasterPeak())
        let shown = max(peak, masterLevel * 0.8)
        if abs(shown - masterLevel) > 0.003 { masterLevel = shown }
        if peak >= 0.999 { clipHold = 20 } else if clipHold > 0 { clipHold -= 1 }
        if isClipping != (clipHold > 0) { isClipping = clipHold > 0 }
        if isRecording { recordedSeconds = engine.recordedSeconds }

        for deck in decks {
            let index = deck.id.rawValue
            if wasPlaying[index], !deck.isPlaying, deck.deck.state().isEnded { onDeckEnded?(deck.id) }
            wasPlaying[index] = deck.isPlaying
        }
        onPoll?()
    }

    // MARK: Recording

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate Recordings")
    }

    func toggleRecording() {
        if isRecording {
            engine.stopRecording()
            isRecording = false
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = Self.recordingsFolder.appendingPathComponent("Mix \(formatter.string(from: Date())).wav")
            try engine.start()
            try engine.startRecording(to: url)
            lastRecording = url
            recordedSeconds = 0
            isRecording = true
            problem = nil
        } catch {
            problem = "Could not start recording: \(error.localizedDescription)"
        }
    }
}
