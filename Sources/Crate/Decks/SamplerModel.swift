import CrateCore
import Foundation
import Observation

/// The sampler as the window shows it: eight pads, what is on each, and whether it is sounding.
@MainActor
@Observable
final class SamplerModel {
    struct Pad: Identifiable, Equatable {
        let id: Int
        var name = ""
        var isLoaded = false
        /// Goes round until stopped, rather than playing once.
        var loops = false
        var gain = 1.0
        var seconds = 0.0
        var isPlaying = false
        var progress = 0.0
        /// Its audio is being read from disk.
        var isLoading = false
    }

    /// What is kept of a pad between launches: where its audio is, not the audio.
    private struct Saved: Codable {
        var path: String
        var name: String
        var loops: Bool
        var gain: Double
        /// For a stretch of a longer file, as when a loop was taken from a deck.
        var start: Double?
        var end: Double?
    }

    private(set) var pads: [Pad] = (0..<Sampler.padCount).map { Pad(id: $0) }
    /// The sampler's level into the mix.
    var level = 1.0 {
        didSet {
            store.setSetting("sampler.level", String(level))
            mixer?.applyMixer()
        }
    }
    /// The headphones hear the sampler whatever its level, like a deck's headphone cue.
    var cue = false { didSet { mixer?.applyMixer() } }
    var problem: String?

    @ObservationIgnored private let sampler: Sampler
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private weak var mixer: DJMixer?
    @ObservationIgnored private var saved: [Saved?] = Array(repeating: nil, count: Sampler.padCount)
    /// Counts loads per pad, so a slow one that has been overtaken does not land on top of a later one.
    @ObservationIgnored private var tickets = Array(repeating: 0, count: Sampler.padCount)

    init(sampler: Sampler, store: LibraryStore, mixer: DJMixer) {
        self.sampler = sampler
        self.store = store
        self.mixer = mixer
        if let text = store.setting("sampler.level"), let value = Double(text) { level = value }
        restore()
    }

    // MARK: Loading

    /// Puts an audio file on a pad, or a stretch of one. The file is read off the main thread.
    func load(path: String, name: String? = nil, from start: Double? = nil, to end: Double? = nil, on pad: Int, loops: Bool? = nil, gain: Double? = nil) {
        guard pads.indices.contains(pad) else { return }
        tickets[pad] += 1
        let ticket = tickets[pad]
        pads[pad].isLoading = true
        problem = nil
        let shown = name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        Task {
            let clip = await Task.detached(priority: .userInitiated) { () -> SampleClip? in
                guard let (audio, file) = try? TrackAudio.open(path: path) else { return nil }
                let first = max(0, Int(((start ?? 0) * audio.sampleRate).rounded()))
                let wanted = end.map { Int(($0 * audio.sampleRate).rounded()) } ?? audio.frames
                let last = min(audio.frames, wanted, first + Int(Sampler.longest * audio.sampleRate))
                guard last > first else { return nil }
                audio.decode(from: file, upTo: last)
                return SampleClip(audio: audio, range: first..<last)
            }.value
            guard tickets[pad] == ticket else { return }
            pads[pad].isLoading = false
            guard let clip else {
                problem = "Could not read “\(shown)” for the sampler."
                return
            }
            put(clip, named: shown, on: pad, loops: loops, gain: gain)
            saved[pad] = Saved(path: path, name: shown, loops: pads[pad].loops, gain: pads[pad].gain, start: start, end: end)
            save()
        }
    }

    /// Puts a library track on a pad: the first two minutes of it at most.
    func load(_ track: Track, on pad: Int) {
        guard let path = Volumes.resolvedPath(for: track) else {
            problem = "“\(track.title)” is not on this Mac, so it cannot go on the sampler."
            return
        }
        load(path: path, name: track.title, on: pad)
    }

    /// Takes what a deck is looping, or four beats from where it is, onto a pad as a loop.
    func capture(from deck: DeckModel, on pad: Int) {
        guard pads.indices.contains(pad), let track = deck.track, let audio = deck.deck.track else { return }
        let range: ClosedRange<Double>
        if let loop = deck.loop {
            range = loop
        } else if let grid = deck.grid {
            let start = max(0, grid.nearestBeat(to: deck.position))
            range = start...grid.time(atBeat: grid.beatPosition(at: start) + 4)
        } else {
            range = deck.position...(deck.position + 2)
        }
        guard range.upperBound > range.lowerBound else { return }
        tickets[pad] += 1
        pads[pad].isLoading = false
        // The deck's own audio, already in memory: nothing is read or copied.
        put(SampleClip(audio: audio, from: range.lowerBound, to: range.upperBound), named: track.title, on: pad, loops: true, gain: nil)
        if let path = Volumes.resolvedPath(for: track) {
            saved[pad] = Saved(path: path, name: track.title, loops: true, gain: pads[pad].gain, start: range.lowerBound, end: range.upperBound)
            save()
        }
    }

    private func put(_ clip: SampleClip, named name: String, on pad: Int, loops: Bool?, gain: Double?) {
        sampler.load(clip, on: pad)
        pads[pad].name = name
        pads[pad].isLoaded = true
        pads[pad].seconds = clip.duration
        if let loops { pads[pad].loops = loops }
        if let gain { pads[pad].gain = gain }
        sampler.set(gain: pads[pad].gain, loops: pads[pad].loops, on: pad)
    }

    func clear(_ pad: Int) {
        guard pads.indices.contains(pad) else { return }
        tickets[pad] += 1
        sampler.load(nil, on: pad)
        pads[pad] = Pad(id: pad)
        sampler.set(gain: 1, loops: false, on: pad)
        saved[pad] = nil
        save()
    }

    // MARK: Playing

    /// A pad hit. A one-shot starts from the top every time; a loop that is going round stops.
    func hit(_ pad: Int) {
        guard pads.indices.contains(pad), pads[pad].isLoaded else { return }
        if pads[pad].loops, pads[pad].isPlaying {
            stop(pad)
        } else {
            mixer?.startEngine()
            sampler.trigger(pad)
            pads[pad].isPlaying = true
            pads[pad].progress = 0
        }
    }

    /// Stops a pad, or all of them with nil.
    func stop(_ pad: Int? = nil) {
        sampler.stop(pad)
        for index in pads.indices where pad == nil || pad == index { pads[index].isPlaying = false }
    }

    func setLoops(_ loops: Bool, on pad: Int) {
        guard pads.indices.contains(pad) else { return }
        pads[pad].loops = loops
        sampler.set(loops: loops, on: pad)
        saved[pad]?.loops = loops
        save()
    }

    func setGain(_ gain: Double, on pad: Int) {
        guard pads.indices.contains(pad) else { return }
        pads[pad].gain = gain
        sampler.set(gain: gain, on: pad)
        saved[pad]?.gain = gain
        save()
    }

    /// Picks up from the audio thread which pads are sounding and how far through they are.
    func poll() {
        guard pads.contains(where: \.isPlaying) else { return }
        let states = sampler.state()
        for index in pads.indices where pads[index].isPlaying || states[index].isPlaying {
            if pads[index].isPlaying != states[index].isPlaying { pads[index].isPlaying = states[index].isPlaying }
            let progress = states[index].isPlaying ? states[index].progress : 0
            if abs(pads[index].progress - progress) > 0.004 { pads[index].progress = progress }
        }
    }

    // MARK: Keeping

    private func save() {
        guard let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) else { return }
        store.setSetting("sampler.pads", text)
    }

    /// Reloads the pads as they were when Crate was last open. Files that have gone are left off.
    private func restore() {
        guard let data = store.setting("sampler.pads")?.data(using: .utf8),
              let kept = try? JSONDecoder().decode([Saved?].self, from: data)
        else { return }
        for (pad, item) in kept.prefix(Sampler.padCount).enumerated() {
            // A pad whose file is away (its drive unplugged) stays empty for now but is not forgotten.
            saved[pad] = item
            guard let item, FileManager.default.fileExists(atPath: item.path) else { continue }
            load(path: item.path, name: item.name, from: item.start, to: item.end, on: pad, loops: item.loops, gain: item.gain)
        }
    }
}
