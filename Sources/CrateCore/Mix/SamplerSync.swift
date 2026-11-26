import Foundation

/// The tempo of a piece of audio on a sampler pad, and where its first beat is.
public struct SampleTiming: Equatable, Sendable {
    public var bpm: Double
    /// Seconds into the pad's audio of a beat. Zero for a loop cut on the beat.
    public var firstBeat: Double

    public init(bpm: Double, firstBeat: Double = 0) {
        self.bpm = bpm
        self.firstBeat = firstBeat
    }

    /// The tempo of audio that is `beats` long.
    public init(beats: Double, in duration: Double) {
        self.init(bpm: duration > 0 ? beats * 60 / duration : 0)
    }

    /// The timing of a stretch of a track, from the track's beat grid: a loop taken from a deck,
    /// or the start of a library track put on a pad.
    public init?(grid: BeatGrid, from start: Double, to end: Double) {
        guard grid.isUsable, end > start else { return nil }
        let first = grid.beatPosition(at: start), last = grid.beatPosition(at: end)
        guard last > first else { return nil }
        // The first beat at or after the start of the stretch.
        let beat = (first - 1e-6).rounded(.up)
        self.init(bpm: (last - first) * 60 / (end - start), firstBeat: max(0, grid.time(atBeat: beat) - start))
    }

    public func beats(in duration: Double) -> Double { duration * bpm / 60 }

    /// The tempo a file's name gives, as sample packs write it: "Drum Loop 124bpm", "break_93.5 BPM".
    public static func named(_ name: String) -> SampleTiming? {
        guard let match = name.range(of: #"(?<![0-9.])[0-9]{2,3}(\.[0-9]+)?[ _-]?bpm"#, options: [.regularExpression, .caseInsensitive]),
              let bpm = Double(name[match].prefix { $0.isNumber || $0 == "." }), (50...220).contains(bpm)
        else { return nil }
        return SampleTiming(bpm: bpm)
    }

    /// Whether a file's name says it is a loop: it has "loop" in it, or a tempo.
    public static func namesALoop(_ name: String) -> Bool {
        name.range(of: "loop", options: .caseInsensitive) != nil || named(name) != nil
    }

    /// The tempos a loop that is not from the library is taken to be within.
    public static let assumedRange = 80.0..<160.0
    /// The longest audio taken to be a loop cut to length, in seconds.
    public static let longestLoop = 50.0

    /// The tempo of a loop file, going by its length alone: a loop is cut to a whole number of
    /// beats, nearly always 1, 2, 4, 8, 16 and so on, and only one of those puts the tempo between
    /// 80 and 160. A loop that is really at half or double that still plays in time, because a pad
    /// is matched to the decks' tempo or to half or double it, whichever is nearest.
    /// Nil for audio too short to be a beat, or too long to be a loop.
    public static func assumed(duration: Double) -> SampleTiming? {
        guard duration > 0, duration <= longestLoop else { return nil }
        let doublings = (log2(assumedRange.lowerBound * duration / 60) - 1e-9).rounded(.up)
        guard doublings >= 0 else { return nil }
        return SampleTiming(beats: pow(2, doublings), in: duration)
    }
}

/// Keeps the sampler in time with the decks.
///
/// Two things, as on DJ gear. **Quantize** is for the whole sampler: a hit is moved onto the
/// grid of the deck being followed (a beat, a part of one, or a bar). **Sync** is a pad's: a
/// loop with Sync on is played at that deck's tempo (its pitch moves with its speed, like a
/// record's) and steered on every control step so that its beats stay on the deck's, as
/// `DeckSync` does for a deck.
///
/// A quantized loop goes to the nearest grid line. Just before one, it waits for it. Just
/// after, it starts at once from as far in as it would have reached, so it is in time from
/// its first sample. A one-shot is never started part-way through, which would cut off its
/// attack: it waits for the next grid line and plays whole. When nothing is playing to
/// follow, a hit sounds at once and a loop carries on at the tempo it had.
public final class SamplerSync: @unchecked Sendable {
    private let engine: DeckEngine
    private let decks: DeckSync
    private let lock = NSLock()
    private var timings: [SampleTiming?]
    private var synced: [Bool]
    private var errors: [Double?]
    private var rates: [Double]
    private var lastJump: [Int64]
    private var grid: Double? = 1

    /// The grid sizes Quantize offers, in beats. Four is a bar.
    public static let grids = [0.25, 0.5, 1, 4]
    /// A one-shot hit no later than this after a grid line, in seconds, sounds at once: near enough on it.
    public static let justLate = 0.02

    /// How quickly a pad closes a timing gap, in seconds.
    public var pull = 0.35
    /// The most a pad's speed is bent to catch up, as a fraction.
    public var maximumCorrection = 0.06
    /// A pad further than this from the beat, in seconds, jumps onto it instead of creeping there.
    public var jumpBeyond = 0.03

    public init(engine: DeckEngine, decks: DeckSync) {
        self.engine = engine
        self.decks = decks
        let count = Sampler.padCount
        timings = Array(repeating: nil, count: count)
        synced = Array(repeating: false, count: count)
        errors = Array(repeating: nil, count: count)
        rates = Array(repeating: 1, count: count)
        lastJump = Array(repeating: 0, count: count)
        engine.onTick { [weak self] in self?.tick() }
    }

    private func isPad(_ pad: Int) -> Bool { (0..<Sampler.padCount).contains(pad) }

    // MARK: Settings

    /// The grid hits are moved onto, in beats of the deck being followed: 1 is a beat, 4 a bar
    /// (counted from the deck's own bar lines), a half and a quarter are parts of a beat. Nil is
    /// Quantize off. A one-shot goes by a beat at most: a bar is a long time to wait for a horn.
    public var quantize: Double? {
        get { lock.withLock { grid } }
        set { lock.withLock { grid = newValue.flatMap { $0 > 0 ? $0 : nil } } }
    }

    /// Whether a pad is kept at the decks' tempo and on their beat, and the tempo of its audio,
    /// without which there is nothing to keep. For loops: a one-shot plays at its own speed.
    public func set(synced on: Bool, timing: SampleTiming?, for pad: Int) {
        guard isPad(pad) else { return }
        let reset = lock.withLock { () -> Bool in
            let had = synced[pad] && timings[pad] != nil
            synced[pad] = on
            timings[pad] = timing.flatMap { $0.bpm > 0 ? $0 : nil }
            let has = synced[pad] && timings[pad] != nil
            if !has { errors[pad] = nil }
            // Let go of the decks' tempo: back to its own speed.
            if had, !has, rates[pad] != 1 {
                rates[pad] = 1
                return true
            }
            return false
        }
        if reset { engine.sampler.setRate(1, on: pad) }
    }

    public func isSynced(_ pad: Int) -> Bool { lock.withLock { isPad(pad) && synced[pad] } }

    /// How far a pad is from the beat it follows, in beats (positive: behind). Nil when it is not being steered.
    public func phaseError(for pad: Int) -> Double? { lock.withLock { isPad(pad) ? errors[pad] : nil } }

    /// The speed a pad was last given; 1 is as recorded.
    public func rate(of pad: Int) -> Double { lock.withLock { isPad(pad) ? rates[pad] : 1 } }

    // MARK: What is followed

    /// The deck the pads follow: the tempo master, unless it cannot be heard and the other deck
    /// can. A deck left running with its fader down after a mix does not lead the sampler astray.
    public var reference: DeckID? {
        let master = decks.currentMaster
        let settings = engine.settings
        let cross = DeckEngine.crossfaderGains(settings.crossfader)
        func plays(_ id: DeckID) -> Bool { decks.grid(for: id) != nil && engine.deck(id).state().isPlaying }
        func isHeard(_ id: DeckID) -> Bool { settings.fader[id.rawValue] * cross[id.rawValue] > 0.05 }
        if let master, plays(master), isHeard(master) { return master }
        if let other = DeckID.allCases.first(where: { $0 != master && plays($0) && isHeard($0) }) { return other }
        return master
    }

    /// The beat being followed, as it stands at one output frame.
    private struct Clock {
        /// Position in beats along the deck's grid.
        var beat: Double
        var frame: Int64
        /// Tempo as heard.
        var bpm: Double
        /// The deck is playing, near enough its set speed: its beat can be started on and followed.
        var isRunning: Bool
        /// The deck's beat runs on evenly. Not so while it loops a part of a beat, or a beat and a half.
        var isEven: Bool
        /// A beat that starts a bar.
        var barLine: Double
        var beatsPerSecond: Double { bpm / 60 }

        func beat(at frame: Int64, rate: Double) -> Double {
            beat + Double(frame - self.frame) / rate * beatsPerSecond
        }
    }

    private func clock() -> Clock? {
        guard let id = reference, let grid = decks.grid(for: id) else { return nil }
        let deck = engine.deck(id)
        let state = deck.state()
        guard state.hasTrack else { return nil }
        let tempo = deck.value(of: .tempo)
        // Nudging counts as running; braking, spinning up and scratching do not.
        let isRunning = state.isPlaying && !state.isScratching && tempo > 0 && abs(state.speed - tempo) < 0.15 * tempo
        let bpm = grid.bpm(at: state.position) * (isRunning ? state.speed : tempo)
        guard bpm > 0 else { return nil }
        var isEven = true
        if let loop = state.loop {
            let length = grid.beatPosition(at: loop.upperBound) - grid.beatPosition(at: loop.lowerBound)
            isEven = length > 0.98 && abs(length - length.rounded()) < 0.02
        }
        return Clock(
            beat: grid.beatPosition(at: state.position), frame: state.frame - state.frameOffset, bpm: bpm,
            isRunning: isRunning, isEven: isEven, barLine: Double(grid.downbeat))
    }

    /// The speed at which a pad's beats are as long as the followed deck's, and how many of the
    /// deck's beats go by for each of the pad's: 1 as a rule, 2 or a half when that is the nearer.
    private static func match(_ timing: SampleTiming, to clock: Clock) -> (rate: Double, ratio: Double) {
        let ratio = DeckSync.beatRatio(masterBPM: clock.bpm, ownBPM: timing.bpm)
        return (clock.bpm / (timing.bpm * ratio), ratio)
    }

    // MARK: Starting in time

    /// A pad hit. With a deck playing, Quantize moves it onto that deck's grid, and a loop with
    /// Sync on starts at the deck's tempo.
    public func trigger(_ pad: Int) {
        guard isPad(pad) else { return }
        let sampler = engine.sampler
        let (timing, quantize) = lock.withLock { (synced[pad] ? timings[pad] : nil, grid) }
        let loops = sampler.loops(on: pad)
        // A loop that is held on the beat starts on one, Quantize or no: it would be pulled there anyway.
        var size = quantize ?? (timing == nil ? nil : 1)
        if !loops, let whole = size { size = min(whole, 1) }
        guard timing != nil || size != nil, let clock = clock() else {
            lock.withLock {
                rates[pad] = 1
                errors[pad] = nil
            }
            return sampler.trigger(pad)
        }
        let match = timing.map { Self.match($0, to: clock) } ?? (rate: 1, ratio: 1)
        lock.withLock {
            rates[pad] = match.rate
            errors[pad] = nil
        }
        // Nothing playing to start on: at once, at the tempo the stopped deck is set to.
        guard clock.isRunning, let size else { return sampler.trigger(pad, rate: match.rate) }

        let rate = DeckEngine.sampleRate
        let now = max(clock.frame, sampler.snapshot().frame - sampler.frameOffset)
        let frame = now + sampler.frameOffset
        // Where the deck is between grid lines, in beats: `since` the last one, `size - since` to the next.
        let lines = (clock.beat(at: now, rate: rate) - clock.barLine) / size
        let since = (lines - lines.rounded(.down)) * size
        lock.withLock { lastJump[pad] = frame }

        guard loops else {
            // A one-shot plays whole: now if the line has only just gone by, or else on the next.
            let wait = since / clock.beatsPerSecond <= Self.justLate ? 0 : (size - since) / clock.beatsPerSecond
            return sampler.trigger(pad, rate: match.rate, at: frame + Int64((wait * rate).rounded()))
        }
        // Where the loop would be now had it started on the nearest line: behind zero if that line is still to come.
        let past = since < size / 2 ? since : since - size
        let padBeatSeconds = timing.map { 60 / $0.bpm } ?? 1 / clock.beatsPerSecond
        let reached = (timing?.firstBeat ?? 0) + past / match.ratio * padBeatSeconds
        let wait = reached < 0 ? -reached / match.rate : 0
        sampler.trigger(pad, from: max(0, reached), rate: match.rate, at: frame + Int64((wait * rate).rounded()))
    }

    // MARK: Steering

    func tick() {
        let (synced, timings, rates) = lock.withLock { (self.synced, self.timings, self.rates) }
        let followers = (0..<Sampler.padCount).filter { synced[$0] && timings[$0] != nil }
        guard !followers.isEmpty else { return }
        let sampler = engine.sampler
        let snapshot = sampler.snapshot()
        guard followers.contains(where: { snapshot.pads[$0].isSounding }), let clock = clock() else { return }
        let rate = DeckEngine.sampleRate
        let samplerFrame = snapshot.frame - sampler.frameOffset

        for pad in followers {
            guard snapshot.pads[pad].isSounding, let timing = timings[pad], let clip = sampler.clip(on: pad) else {
                lock.withLock { errors[pad] = nil }
                continue
            }
            // The deck stopped, braking or in someone's hand: the pad carries on at the tempo it has.
            guard clock.isRunning else {
                lock.withLock { errors[pad] = nil }
                continue
            }
            let match = Self.match(timing, to: clock)
            guard clock.isEven else {
                sampler.setRate(match.rate, on: pad)
                lock.withLock {
                    self.rates[pad] = match.rate
                    errors[pad] = nil
                }
                continue
            }

            // Compare the two at the same output frame; their snapshots can be a render apart.
            let common = min(clock.frame, samplerFrame)
            let masterBeat = clock.beat(at: common, rate: rate)
            let position = snapshot.pads[pad].position + Double(common - samplerFrame) / rate * rates[pad]
            let ownBeat = (position - timing.firstBeat) * timing.bpm / 60
            let error = DeckSync.phaseError(master: masterBeat, own: ownBeat, ratio: match.ratio)
            let beatsPerSecond = max(0.5, clock.beatsPerSecond)

            // Far off the beat (the deck jumped, or started up under a pad already going): jump onto it.
            // Creeping there at a few percent takes seconds and sounds like a mistake.
            if abs(error) / beatsPerSecond > jumpBeyond, snapshot.frame - lock.withLock({ lastJump[pad] }) > Int64(0.25 * rate) {
                var landing = snapshot.pads[pad].position + error / match.ratio * 60 / timing.bpm
                let duration = clip.duration
                let loops = sampler.loops(on: pad)
                if loops, duration > 0 {
                    landing = landing.truncatingRemainder(dividingBy: duration)
                    if landing < 0 { landing += duration }
                }
                if landing >= 0, landing < duration {
                    sampler.trigger(pad, from: landing, rate: match.rate, at: snapshot.frame)
                    lock.withLock {
                        lastJump[pad] = snapshot.frame
                        self.rates[pad] = match.rate
                        errors[pad] = 0
                    }
                    continue
                }
            }
            let correction = max(-maximumCorrection, min(maximumCorrection, error / (pull * beatsPerSecond)))
            let steered = match.rate * (1 + correction)
            sampler.setRate(steered, on: pad)
            lock.withLock {
                self.rates[pad] = steered
                errors[pad] = error
            }
        }
    }
}
