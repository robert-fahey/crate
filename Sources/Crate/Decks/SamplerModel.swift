import CrateCore
import Foundation
import Observation

/// The sampler as the window shows it: a bank of eight pads for each deck, what is on each pad,
/// and whether it is sounding. Which bank a deck has up can be changed, and a bank can be tied
/// to a track so that it comes up when the track is loaded.
@MainActor
@Observable
final class SamplerModel {
    struct Pad: Identifiable, Equatable {
        /// 0...7 are deck A's bank, 8...15 deck B's.
        let id: Int
        var deck: DeckID { id < SampleBank.size ? .a : .b }
        /// Its place in its bank, 0...7.
        var slot: Int { id % SampleBank.size }
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
        /// A loop played at the decks' tempo and kept on their beat. Nothing to a one-shot.
        var syncs = false
        /// The tempo of its audio, where Crate knows it or can tell it from the length.
        var bpm: Double?
        /// The tempo it is being played at, to a tenth, while it is kept at the decks'.
        var playedBPM: Double?
        /// Its outline, for the mini deck's waveform.
        var peaks: [Float] = []

        /// How many beats long it is, if that is one of the lengths a loop is cut to.
        var beatCount: Int? {
            guard let bpm, seconds > 0 else { return nil }
            let beats = bpm * seconds / 60
            return SamplerModel.beatCounts.first { abs(Double($0) - beats) < 0.01 * beats }
        }
    }

    /// How many bars a mini deck's waveform is drawn with.
    nonisolated static let waveBins = 72

    /// The lengths offered for a loop, in beats.
    nonisolated static let beatCounts = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    /// Of those, the ones that give audio of this length a tempo music is played at.
    nonisolated static func beatCounts(for seconds: Double) -> [(beats: Int, bpm: Double)] {
        guard seconds > 0 else { return [] }
        return beatCounts.map { ($0, Double($0) * 60 / seconds) }.filter { (50...220).contains($0.1) }
    }

    /// Every bank there is, for the menus, and the one each deck has up.
    private(set) var banks: [SampleBank] = []
    private(set) var bankOn: [Int64] = [0, 0]
    /// Whether the track on each deck is tied to the bank that deck has up.
    private(set) var bankIsTied = [false, false]

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
    /// Quantize: hits are moved onto the grid of the deck that is playing.
    var isQuantized = true { didSet { applyQuantize() } }
    /// The size of that grid in beats; 4 is a bar.
    var quantum = 1.0 { didSet { applyQuantize() } }
    var problem: String?

    @ObservationIgnored private let sampler: Sampler
    @ObservationIgnored private let syncer: SamplerSync
    @ObservationIgnored private var timings: [SampleTiming?] = Array(repeating: nil, count: Sampler.padCount)
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private weak var mixer: DJMixer?
    /// What each pad's bank keeps of it: where its audio is, not the audio.
    @ObservationIgnored private var saved: [SampleBank.Pad?] = Array(repeating: nil, count: Sampler.padCount)
    /// A bank waiting to come up on a deck once that deck's pads have stopped sounding.
    @ObservationIgnored private var waitingBank: [Int64?] = [nil, nil]
    /// Counts loads per pad, so a slow one that has been overtaken does not land on top of a later one.
    @ObservationIgnored private var tickets = Array(repeating: 0, count: Sampler.padCount)

    init(sampler: Sampler, syncer: SamplerSync, store: LibraryStore, mixer: DJMixer) {
        self.sampler = sampler
        self.syncer = syncer
        self.store = store
        self.mixer = mixer
        if let text = store.setting("sampler.level"), let value = Double(text) { level = value }
        if let text = store.setting("sampler.quantize") {
            // "off", or "off:<beats>" to remember the size, or the size alone when on.
            let size = Double(text.replacingOccurrences(of: "off", with: "").replacingOccurrences(of: ":", with: ""))
            if let size, SamplerSync.grids.contains(size) { quantum = size }
            isQuantized = !text.hasPrefix("off")
        }
        syncer.quantize = isQuantized ? quantum : nil
        restore()
    }

    // MARK: Loading

    /// Puts an audio file on a pad, or a stretch of one. The file is read off the main thread.
    /// Its tempo comes from `timing`, or from the beat grid of the track it is, or failing both from its length.
    func load(
        path: String, name: String? = nil, from start: Double? = nil, to end: Double? = nil, on pad: Int, loops: Bool? = nil,
        gain: Double? = nil, sync: Bool? = nil, timing: SampleTiming? = nil, grid: BeatGrid? = nil
    ) {
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
            let from = start ?? 0
            let known = timing ?? grid.flatMap { SampleTiming(grid: $0, from: from, to: from + clip.duration) }
            put(clip, named: shown, on: pad, loops: loops, gain: gain, sync: sync, timing: known)
            saved[pad] = SampleBank.Pad(path: path, name: shown, loops: pads[pad].loops, gain: pads[pad].gain, start: start, end: end)
            save()
        }
    }

    /// Puts a library track on a pad: the first two minutes of it at most.
    func load(_ track: Track, on pad: Int) {
        guard let path = Volumes.resolvedPath(for: track) else {
            problem = "“\(track.title)” is not on this Mac, so it cannot go on the sampler."
            return
        }
        // Its tempo and where its beats are come from its beat grid, if it has been analysed.
        let grid = try? store.beatGrid(id: track.id)
        load(path: path, name: track.title, on: pad, timing: grid == nil ? track.bpm.map { SampleTiming(bpm: $0) } : nil, grid: grid)
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
        // The deck's own audio, already in memory: nothing is read or copied. Its tempo is the deck's grid's.
        let timing = deck.grid.flatMap { SampleTiming(grid: $0, from: range.lowerBound, to: range.upperBound) }
        put(
            SampleClip(audio: audio, from: range.lowerBound, to: range.upperBound), named: track.title, on: pad, loops: true,
            gain: nil, sync: true, timing: timing)
        if let path = Volumes.resolvedPath(for: track) {
            saved[pad] = SampleBank.Pad(path: path, name: track.title, loops: true, gain: pads[pad].gain, start: range.lowerBound, end: range.upperBound)
            save()
        }
    }

    private func put(_ clip: SampleClip, named name: String, on pad: Int, loops: Bool?, gain: Double?, sync: Bool?, timing: SampleTiming?) {
        let wasLoaded = pads[pad].isLoaded
        sampler.load(clip, on: pad)
        pads[pad].name = name
        pads[pad].isLoaded = true
        pads[pad].seconds = clip.duration
        if let loops { pads[pad].loops = loops }
        if let gain { pads[pad].gain = gain }
        // New audio on a pad keeps the pad's Sync; a pad that was empty syncs if it loops.
        if let sync { pads[pad].syncs = sync } else if !wasLoaded { pads[pad].syncs = pads[pad].loops }
        // A pad that was empty becomes a mini deck if the file's name says it is a loop.
        if loops == nil, !wasLoaded, SampleTiming.namesALoop(name) {
            pads[pad].loops = true
            if sync == nil { pads[pad].syncs = true }
        }
        // Its tempo: what it was given, what its name says, or what its length implies.
        timings[pad] = timing ?? SampleTiming.named(name) ?? SampleTiming.assumed(duration: clip.duration)
        pads[pad].bpm = timings[pad]?.bpm
        pads[pad].playedBPM = nil
        pads[pad].peaks = clip.peaks(bins: Self.waveBins)
        sampler.set(gain: pads[pad].gain, loops: pads[pad].loops, on: pad)
        applySync(pad)
    }

    /// Tells the sync what a pad wants. Only a loop is kept at the decks' tempo.
    private func applySync(_ pad: Int) {
        syncer.set(synced: pads[pad].isLoaded && pads[pad].syncs && pads[pad].loops, timing: timings[pad], for: pad)
    }

    private func applyQuantize() {
        syncer.quantize = isQuantized ? quantum : nil
        store.setSetting("sampler.quantize", (isQuantized ? "" : "off:") + String(quantum))
    }

    /// What a grid size is called: "1 beat", "¼ beat", "1 bar".
    nonisolated static func gridName(_ beats: Double) -> String {
        switch beats {
        case 0.25: return "¼ beat"
        case 0.5: return "½ beat"
        case 4: return "1 bar"
        default: return "1 beat"
        }
    }

    func clear(_ pad: Int) {
        guard pads.indices.contains(pad) else { return }
        tickets[pad] += 1
        sampler.load(nil, on: pad)
        pads[pad] = Pad(id: pad)
        timings[pad] = nil
        sampler.set(gain: 1, loops: false, on: pad)
        applySync(pad)
        saved[pad] = nil
        save()
    }

    // MARK: Playing

    /// A pad hit. A one-shot starts from the top every time; a loop that is going round stops.
    /// With Quantize on and a deck playing, the start is moved onto the deck's grid.
    func hit(_ pad: Int) {
        guard pads.indices.contains(pad), pads[pad].isLoaded else { return }
        if pads[pad].loops, pads[pad].isPlaying {
            stop(pad)
        } else {
            mixer?.startEngine()
            syncer.trigger(pad)
            pads[pad].isPlaying = true
            pads[pad].progress = 0
        }
    }

    /// Stops a pad, or all of them with nil.
    func stop(_ pad: Int? = nil) {
        sampler.stop(pad)
        for index in pads.indices where pad == nil || pad == index {
            pads[index].isPlaying = false
            pads[index].playedBPM = nil
        }
    }

    /// A loop is wanted in time as a rule and a one-shot at once, so Sync goes on and off with Loop.
    /// `setSync` says otherwise for a pad.
    func setLoops(_ loops: Bool, on pad: Int) {
        guard pads.indices.contains(pad) else { return }
        pads[pad].loops = loops
        pads[pad].syncs = loops
        sampler.set(loops: loops, on: pad)
        applySync(pad)
        save()
    }

    func setSync(_ syncs: Bool, on pad: Int) {
        guard pads.indices.contains(pad) else { return }
        pads[pad].syncs = syncs
        applySync(pad)
        save()
    }

    /// Says how many beats long a pad's audio is, which is what gives it its tempo.
    func setBeats(_ beats: Int, on pad: Int) {
        guard pads.indices.contains(pad), pads[pad].isLoaded, beats > 0, pads[pad].seconds > 0 else { return }
        timings[pad] = SampleTiming(beats: Double(beats), in: pads[pad].seconds)
        pads[pad].bpm = timings[pad]?.bpm
        applySync(pad)
        save()
    }

    /// How far a pad is from the beat it follows, in beats, and the speed it is being played at; for the debug driver.
    func syncState(of pad: Int) -> (error: Double?, rate: Double) { (syncer.phaseError(for: pad), syncer.rate(of: pad)) }

    func setGain(_ gain: Double, on pad: Int) {
        guard pads.indices.contains(pad) else { return }
        pads[pad].gain = gain
        sampler.set(gain: gain, on: pad)
        save()
    }

    /// Picks up from the audio thread which pads are sounding and how far through they are.
    func poll() {
        // A bank that came with a newly loaded track comes up once its deck's pads are quiet.
        for deck in DeckID.allCases {
            if let bank = waitingBank[deck.rawValue], !pads(of: deck).contains(where: \.isPlaying) { show(bank, on: deck) }
        }
        guard pads.contains(where: \.isPlaying) else { return }
        let states = sampler.state()
        for index in pads.indices where pads[index].isPlaying || states[index].isPlaying {
            if pads[index].isPlaying != states[index].isPlaying { pads[index].isPlaying = states[index].isPlaying }
            let progress = states[index].isPlaying ? states[index].progress : 0
            if abs(pads[index].progress - progress) > 0.004 { pads[index].progress = progress }
            // The tempo a mini deck shows while it follows the decks: to a tenth, so it is steady to read.
            var played: Double?
            if states[index].isPlaying, pads[index].loops, pads[index].syncs, let bpm = pads[index].bpm {
                played = (bpm * syncer.rate(of: index) * 10).rounded() / 10
            }
            if pads[index].playedBPM != played { pads[index].playedBPM = played }
        }
    }

    // MARK: Banks

    /// A deck's eight pads.
    func pads(of deck: DeckID) -> [Pad] { Array(pads[range(of: deck)]) }

    private func range(of deck: DeckID) -> Range<Int> { Sampler.pad(0, of: deck)..<Sampler.pad(SampleBank.size, of: deck) }

    func bank(on deck: DeckID) -> SampleBank? { banks.first { $0.id == bankOn[deck.rawValue] } }

    /// Puts a bank up on a deck in place of the one there, whose pads stop. A bank is up on one
    /// deck at a time: asked for the one the other deck has, this does nothing.
    func show(_ bankID: Int64, on deck: DeckID) {
        waitingBank[deck.rawValue] = nil
        guard bankID != bankOn[deck.other.rawValue], let bank = (try? store.sampleBank(id: bankID)) ?? nil else { return }
        guard bankID != bankOn[deck.rawValue] else { return refreshTie(deck) }
        for pad in range(of: deck) {
            tickets[pad] += 1
            sampler.load(nil, on: pad)
            pads[pad] = Pad(id: pad)
            timings[pad] = nil
            sampler.set(gain: 1, loops: false, on: pad)
            applySync(pad)
            // A pad whose file is away (its drive unplugged) stays empty for now but is not forgotten.
            saved[pad] = bank.pads[pad - range(of: deck).lowerBound]
        }
        bankOn[deck.rawValue] = bankID
        store.setSetting("sampler.bank.\(deck.name)", String(bankID))
        refreshTie(deck)
        for pad in range(of: deck) {
            guard let item = saved[pad], FileManager.default.fileExists(atPath: item.path) else { continue }
            load(
                path: item.path, name: item.name, from: item.start, to: item.end, on: pad, loops: item.loops, gain: item.gain,
                sync: item.sync ?? item.loops, timing: item.bpm.map { SampleTiming(bpm: $0, firstBeat: item.firstBeat ?? 0) })
        }
    }

    /// A track has landed on a deck. If it is tied to a bank, that bank comes up on the deck: at
    /// once if the deck's pads are quiet, and otherwise when they next are, so a loop that is
    /// playing is not cut off by loading a track. A track tied to no bank leaves the deck's bank alone.
    func trackLanded(_ track: Track, on deck: DeckID) {
        waitingBank[deck.rawValue] = nil
        defer { refreshTie(deck) }
        guard let bank = (try? store.sampleBankID(forTrack: track.id)) ?? nil, bank != bankOn[deck.rawValue],
              bank != bankOn[deck.other.rawValue]
        else { return }
        if pads(of: deck).contains(where: \.isPlaying) {
            waitingBank[deck.rawValue] = bank
        } else {
            show(bank, on: deck)
        }
    }

    /// Makes an empty bank and puts it up on a deck.
    func newBank(on deck: DeckID) {
        guard let bank = try? store.addSampleBank() else { return }
        banks.append(bank)
        show(bank.id, on: deck)
    }

    /// Makes a copy of the bank a deck has up and puts the copy up instead.
    func duplicateBank(on deck: DeckID) {
        save()
        guard let current = bank(on: deck), let copy = try? store.addSampleBank(name: current.name + " copy", pads: current.pads) else { return }
        banks.append(copy)
        show(copy.id, on: deck)
    }

    func renameBank(on deck: DeckID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = banks.firstIndex(where: { $0.id == bankOn[deck.rawValue] }) else { return }
        banks[index].name = name
        save()
    }

    /// Deletes the bank a deck has up. The deck takes another that is not in use, or a new empty one.
    func deleteBank(on deck: DeckID) {
        let gone = bankOn[deck.rawValue]
        let next = banks.first { $0.id != gone && $0.id != bankOn[deck.other.rawValue] }?.id ?? (try? store.addSampleBank())?.id
        guard let next else { return }
        banks = (try? store.sampleBanks()) ?? banks
        show(next, on: deck)
        try? store.deleteSampleBank(id: gone)
        banks.removeAll { $0.id == gone }
        for each in DeckID.allCases { refreshTie(each) }
    }

    /// Ties the track on a deck to the bank the deck has up, so the bank comes up whenever that
    /// track is loaded; or unties it.
    func setBankTied(_ tied: Bool, on deck: DeckID) {
        guard let track = mixer?.deck(deck).track else { return }
        try? store.setSampleBank(tied ? bankOn[deck.rawValue] : nil, forTrack: track.id)
        for each in DeckID.allCases { refreshTie(each) }
    }

    private func refreshTie(_ deck: DeckID) {
        let bank = mixer?.deck(deck).track.flatMap { (try? store.sampleBankID(forTrack: $0.id)) ?? nil }
        let tied = bank != nil && bank == bankOn[deck.rawValue]
        if bankIsTied[deck.rawValue] != tied { bankIsTied[deck.rawValue] = tied }
    }

    // MARK: Keeping

    private func save() {
        // What a pad is set to is kept with where its audio is.
        for pad in pads.indices where saved[pad] != nil && pads[pad].isLoaded {
            saved[pad]?.loops = pads[pad].loops
            saved[pad]?.gain = pads[pad].gain
            saved[pad]?.sync = pads[pad].syncs
            saved[pad]?.bpm = timings[pad]?.bpm
            saved[pad]?.firstBeat = timings[pad]?.firstBeat
        }
        for deck in DeckID.allCases {
            guard let index = banks.firstIndex(where: { $0.id == bankOn[deck.rawValue] }) else { continue }
            let kept = Array(saved[range(of: deck)])
            guard banks[index].pads != kept || (try? store.sampleBank(id: banks[index].id))??.name != banks[index].name else { continue }
            banks[index].pads = kept
            try? store.saveSampleBank(banks[index])
        }
    }

    /// Puts up the banks the decks had when Crate was last open, making them if there are none yet.
    /// Files that have gone are left off their pads.
    private func restore() {
        banks = (try? store.sampleBanks()) ?? []
        var chosen: [Int64] = []
        for deck in DeckID.allCases {
            let last = store.setting("sampler.bank.\(deck.name)").flatMap { Int64($0) }
            let free = banks.filter { !chosen.contains($0.id) }
            if let bank = free.first(where: { $0.id == last }) ?? free.first {
                chosen.append(bank.id)
            } else if let made = try? store.addSampleBank() {
                banks.append(made)
                chosen.append(made.id)
            }
        }
        for (deck, bank) in zip(DeckID.allCases, chosen) { show(bank, on: deck) }
    }
}
