import CrateCore
import Foundation
import MediaPlayer
import Observation

/// "Just play this": the simple player on top of the decks.
///
/// Local tracks play on a deck; Spotify and TIDAL tracks play in their own
/// apps. This keeps the list of what is up next and moves on when a track
/// ends, and it is what the media keys and the agent's `player_*` tools drive.
/// Mixing by hand goes straight to the decks (`mixer`) and never through here.
@MainActor
@Observable
final class PlayerController {
    @ObservationIgnored let mixer: DJMixer
    /// Tracks waiting to play after the current one.
    private(set) var upNext: [Track] = []
    /// The most recent playback problem, shown in the deck area.
    var problem: String?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let spotify = SpotifyBackend()
    @ObservationIgnored private let tidal = TidalBackend()
    /// A Spotify or TIDAL track playing in its own app.
    private(set) var streaming: Track?
    private(set) var streamingPosition = 0.0
    private(set) var streamingIsPlaying = false
    @ObservationIgnored private var streamingBackend: PlaybackBackend?
    @ObservationIgnored private var timer: Timer?
    /// Counts requests to start something. A track takes a moment to come off the disk; if
    /// something else is asked for meanwhile, the earlier track is left on its deck, not started.
    @ObservationIgnored private var requests = 0
    /// How many tracks are on their way to being started.
    @ObservationIgnored private var starting = 0

    init(store: LibraryStore, mixer: DJMixer) {
        self.store = store
        self.mixer = mixer
        mixer.onDeckEnded = { [weak self] _ in self?.deckEnded() }
        configureMediaKeys()
    }

    // MARK: What is playing

    var current: Track? { streaming ?? (mixer.focus.isLoaded ? mixer.focus.track : nil) }
    var isPlaying: Bool { streaming != nil ? streamingIsPlaying : mixer.isAnyPlaying }
    var position: Double { streaming != nil ? streamingPosition : mixer.focus.position }
    var duration: Double { current?.duration ?? 0 }
    var canSeek: Bool { streamingBackend?.canSeek ?? true }
    var canPause: Bool { streamingBackend?.canPause ?? true }
    /// Output level of the deck being heard, in dBFS; -160 when silent.
    var localLevel: Float {
        let peak = mixer.focus.deck.state().peak
        return streaming == nil && peak > 0 ? max(-160, 20 * log10(peak)) : -160
    }

    // MARK: Transport

    /// Plays `tracks[start]` now, cutting off whatever is playing, with the rest up next.
    /// Returns at once: the track starts when its file has been read, which never holds up the interface.
    func play(_ tracks: [Track], startingAt start: Int = 0) {
        Task { await playAndWait(tracks, startingAt: start) }
    }

    /// The same, returning once the track is playing or has failed.
    func playAndWait(_ tracks: [Track], startingAt start: Int = 0) async {
        guard !tracks.isEmpty else { return }
        let index = max(0, min(start, tracks.count - 1))
        upNext = Array(tracks.dropFirst(index + 1))
        await begin(tracks[index], cut: true)
    }

    /// A double-click in the browser. With nothing playing it plays, with the
    /// rest of the list up next. With a deck already playing it only loads the
    /// other deck, ready to mix: a slip of the hand must never cut a live mix.
    func open(_ tracks: [Track], startingAt start: Int) {
        guard tracks.indices.contains(start) else { return }
        let track = tracks[start]
        guard isPlaying, track.source == .local, streaming == nil else { return play(tracks, startingAt: start) }
        let target = mixer.freeDeck
        Task {
            do {
                try await mixer.load(track, on: target)
                problem = nil
            } catch is CancellationError {
                // Another track was put on that deck before this one arrived.
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Replaces what is up next without touching what is playing.
    func setQueue(_ tracks: [Track]) { upNext = tracks }

    /// A track that has been mixed in by hand or by the auto DJ is no longer waiting.
    func removeFromQueue(_ id: Track.ID) { upNext.removeAll { $0.id == id } }

    func enqueue(_ tracks: [Track]) {
        Task { await enqueueAndWait(tracks) }
    }

    func enqueueAndWait(_ tracks: [Track]) async {
        upNext.append(contentsOf: tracks)
        if !isPlaying, current == nil, starting == 0 { await advance(cut: false) }
    }

    /// Starts a track; if it cannot be played, tries the ones after it.
    private func begin(_ first: Track, cut: Bool) async {
        requests += 1
        let request = requests
        starting += 1
        defer { starting -= 1 }
        var track: Track? = first
        var firstProblem: String?
        while let candidate = track {
            do {
                try await start(candidate, cut: cut, request: request)
                problem = firstProblem
                updateNowPlaying()
                return
            } catch is CancellationError {
                return  // overtaken by a later request, which reports for itself
            } catch {
                guard request == requests else { return }
                firstProblem = firstProblem ?? error.localizedDescription
                track = upNext.isEmpty ? nil : upNext.removeFirst()
            }
        }
        problem = firstProblem
        updateNowPlaying()
    }

    private func start(_ track: Track, cut: Bool, request: Int) async throws {
        if track.source == .local {
            let target = mixer.freeDeck
            try await mixer.load(track, on: target)
            // Something else was asked for while this was loading: it stays on its deck, stopped.
            guard request == requests else { throw CancellationError() }
            stopStreaming()
            if cut { for deck in mixer.decks where deck.id != target { deck.pause() } }
            mixer.deck(target).play()
        } else {
            let backend: PlaybackBackend = track.source == .spotify ? spotify : tidal
            try backend.start(track)
            for deck in mixer.decks { deck.pause() }
            if streamingBackend !== backend { streamingBackend?.stop() }
            streamingBackend = backend
            streaming = track
            streamingPosition = 0
            streamingIsPlaying = true
            startTimer()
        }
    }

    private func stopStreaming() {
        streamingBackend?.stop()
        streamingBackend = nil
        streaming = nil
        streamingIsPlaying = false
        streamingPosition = 0
        timer?.invalidate()
        timer = nil
    }

    private func advance(cut: Bool) async {
        guard !upNext.isEmpty else { return updateNowPlaying() }
        await begin(upNext.removeFirst(), cut: cut)
    }

    /// A deck ran off the end of its track. If nothing else is playing or about to, the next track starts.
    private func deckEnded() {
        guard !mixer.isAnyPlaying, streaming == nil, starting == 0 else { return }
        Task { await advance(cut: false) }
    }

    func togglePlayPause() {
        if let backend = streamingBackend {
            do {
                if streamingIsPlaying {
                    try backend.pause()
                    streamingIsPlaying = false
                } else {
                    try backend.resume()
                    streamingIsPlaying = true
                }
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        } else if mixer.isAnyPlaying {
            for deck in mixer.decks { deck.pause() }
        } else {
            mixer.focus.play()
        }
        updateNowPlaying()
    }

    /// Moves to the next track, or stops at the end of the list.
    func skip() {
        Task { await skipAndWait() }
    }

    func skipAndWait() async {
        if upNext.isEmpty { stop() } else { await advance(cut: true) }
    }

    /// Back to the start of the track.
    func previous() { seek(to: 0) }

    func seek(to seconds: Double) {
        if let backend = streamingBackend {
            do {
                try backend.seek(to: max(0, min(seconds, duration)))
                streamingPosition = backend.position
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        } else {
            mixer.focus.seek(to: max(0, min(seconds, duration)))
        }
        updateNowPlaying()
    }

    func stop() {
        for deck in mixer.decks { deck.pause() }
        stopStreaming()
        upNext = []
        updateNowPlaying()
    }

    /// Analysis may have finished for a loaded track.
    func refreshWaveform() { mixer.refreshAnalysis() }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let backend = streamingBackend else { return }
        if backend.isFinished {
            stopStreaming()
            Task { await advance(cut: false) }
        } else {
            streamingPosition = backend.position
        }
    }

    // MARK: Media keys and Control Centre

    private func configureMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: current.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        center.playbackState = isPlaying ? .playing : .paused
    }

    // MARK: Status for the agent

    func statusJSON() -> JSON {
        guard let current else {
            var result: [String: JSON] = ["state": "stopped"]
            if let problem { result["problem"] = .string(problem) }
            return .object(result)
        }
        var result: [String: JSON] = [
            "state": isPlaying ? "playing" : "paused",
            "track": TrackFormat.json(current),
            "position": .string(TrackFormat.duration(position)),
            "up_next": .array(upNext.prefix(5).map(TrackFormat.json)),
            "queue_remaining": .number(Double(upNext.count)),
        ]
        if current.source != .local {
            result["playing_in"] = .string("the \(current.source.displayName) app")
        } else {
            result["deck"] = .string(mixer.focus.id.name)
        }
        if let problem { result["problem"] = .string(problem) }
        return .object(result)
    }
}

extension PlayerController: PlayerControl {
    private func tracks(_ ids: [Int64]) throws -> [Track] {
        let tracks = try store.tracks(ids: ids)
        guard !tracks.isEmpty else { throw ToolError("None of those tracks are in the library.") }
        return tracks
    }

    func play(trackIDs: [Int64]) async throws -> JSON {
        await playAndWait(try tracks(trackIDs))
        if current == nil { throw ToolError(problem ?? "None of those tracks could be played.") }
        return statusJSON()
    }

    func enqueue(trackIDs: [Int64]) async throws -> JSON {
        await enqueueAndWait(try tracks(trackIDs))
        return statusJSON()
    }

    func pause() async throws -> JSON {
        guard current != nil else { throw ToolError("Nothing is playing.") }
        if isPlaying { togglePlayPause() }
        if isPlaying { throw ToolError(problem ?? "Could not pause.") }
        return statusJSON()
    }

    func resume() async throws -> JSON {
        guard current != nil else { throw ToolError("Nothing is loaded. Use player_play.") }
        if !isPlaying { togglePlayPause() }
        return statusJSON()
    }

    func next() async throws -> JSON {
        guard current != nil else { throw ToolError("Nothing is playing.") }
        await skipAndWait()
        return statusJSON()
    }

    func seek(toSeconds seconds: Double) async throws -> JSON {
        guard current != nil else { throw ToolError("Nothing is playing.") }
        guard canSeek else { throw ToolError("Crate cannot seek in TIDAL tracks.") }
        seek(to: seconds)
        return statusJSON()
    }

    func status() async -> JSON { statusJSON() }
}
