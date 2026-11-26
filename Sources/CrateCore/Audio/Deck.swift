import AVFoundation
import CrateDSP
import Foundation

public enum DeckID: Int, CaseIterable, Sendable {
    case a, b
    public var name: String { self == .a ? "A" : "B" }
    public var other: DeckID { self == .a ? .b : .a }
}

extension DeckID: Identifiable {
    public var id: Int { rawValue }
}

/// A deck's continuous controls. Each glides to a new value rather than stepping.
public enum DeckParam: Int32, CaseIterable, Sendable {
    /// Playback speed; 1 is as recorded.
    case tempo
    /// Added to the tempo while nudging.
    case bend
    /// Gain after the trim: channel fader x crossfader x master. Set by the mixer.
    case gain
    /// Band gains, linear. 0 kills the band; 1 is flat.
    case eqLow, eqMid, eqHigh
    /// -1...0 closes a low-pass, 0 is off, 0...1 closes a high-pass.
    case filter
    /// Level of the deck itself after the filter; 0 leaves only the echo (an echo-out).
    case dry
    case echoSend, echoFeedback, echoLevel
    /// Echo time in engine frames.
    case echoFrames
    /// Metronome level; 0 is off.
    case click
    /// Gain before the fader. Set by the mixer.
    case trim
    /// How much of the deck, as it is before its fader, the headphones hear. Set by the mixer.
    case cue
    /// How much of the deck, as it is in the master mix, the headphones hear. Set by the mixer.
    case monitor
}

/// What a deck is doing right now.
public struct DeckState: Equatable, Sendable {
    public var hasTrack = false
    /// Seconds into the track.
    public var position = 0.0
    public var duration = 0.0
    /// Current speed including motor ramps and scratching; 1 is as recorded.
    public var speed = 0.0
    /// Engine frames this deck has rendered; the time base for scheduled commands.
    public var frame: Int64 = 0
    /// How many frames this deck is rendered ahead of what is heard. Zero unless
    /// key lock is on, whose pitch shifter buffers. `position` already allows for
    /// it.
    public var lead: Int64 = 0
    /// `frame` minus the engine's output frame. A command meant to be heard at
    /// output frame T is scheduled at T + frameOffset.
    public var frameOffset: Int64 = 0
    public var isPlaying = false
    public var isEnded = false
    public var isScratching = false
    /// The active loop, in seconds.
    public var loop: ClosedRange<Double>?
    /// How many times the deck has been round the loop since it was set, or since the deck last
    /// jumped; negative when it went round backwards. `position` drops back by the loop's length
    /// each time, and this is what tells that apart from a jump.
    public var loopPass = 0
    /// Seconds of the track the record has turned through since it went on, backwards counted
    /// against. Unlike `position` it does not jump: not at a cue, a seek or a loop's end.
    public var travel = 0.0
    /// Loudest output sample in the last render, linear.
    public var peak: Float = 0
    /// How much of the track is decoded, 0...1.
    public var loadProgress = 1.0
}

/// One deck: a track in memory, played by the C audio core at any speed.
///
/// All methods are safe to call from any thread. Anything with an `at` frame is
/// carried out on exactly that frame of the deck's own render count
/// (`DeckState.frame`); 0 means straight away.
public final class Deck: @unchecked Sendable {
    public let id: DeckID
    public let sampleRate: Double

    let core: OpaquePointer
    let node: AVAudioSourceNode
    let keyLockUnit = AVAudioUnitTimePitch()

    private let lock = NSLock()
    private var audio: TrackAudio?
    private var retired: [(generation: UInt64, audio: TrackAudio)] = []
    private var generation: UInt64 = 0
    private var values: [DeckParam: Double] = [
        .tempo: 1, .bend: 0, .gain: 1, .trim: 1, .cue: 0, .monitor: 0, .eqLow: 1, .eqMid: 1, .eqHigh: 1, .filter: 0, .dry: 1,
        .echoSend: 0, .echoFeedback: 0.5, .echoLevel: 1,
    ]
    private var keyLockOn = false
    private var scratching = false
    private var lead: Int64 = 0
    private var frameOffset: Int64 = 0
    /// Set by the engine: puts the pitch shifter in or out of this deck's path.
    var rewire: ((Bool) -> Void)?

    init(id: DeckID, sampleRate: Double) {
        self.id = id
        self.sampleRate = sampleRate
        guard let core = crate_deck_create(sampleRate) else { fatalError("out of memory creating a deck") }
        self.core = core
        // Four channels: the deck's part of the master mix, and its part of what the headphones hear.
        // The block captures only the C pointer: nothing here touches the Swift runtime while rendering.
        node = AVAudioSourceNode(format: DeckEngine.format(sampleRate: sampleRate)) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
            let phones = buffers.count >= 4 ? (buffers[2].mData, buffers[3].mData) : (nil, nil)
            crate_deck_render(
                core, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self),
                phones.0?.assumingMemoryBound(to: Float.self), phones.1?.assumingMemoryBound(to: Float.self), Int32(frameCount))
            return noErr
        }
        values[.echoFrames] = sampleRate * 0.375
    }

    deinit {
        crate_deck_destroy(core)
    }

    private func send(_ type: CrateCommandType, param: DeckParam? = nil, a: Double = 0, b: Double = 0, at frame: Int64 = 0) {
        // Called with the lock held. A full queue (the engine is stopped and nothing drains it) drops the command.
        _ = crate_deck_send(
            core, CrateCommand(type: Int32(type.rawValue), param: param?.rawValue ?? 0, atFrame: frame, a: a, b: b))
    }

    // MARK: Loading

    /// Puts a track on the deck, stopped at its start. The previous track's memory
    /// is released once the audio thread has let go of it.
    public func load(_ track: TrackAudio?) {
        lock.withLock {
            if let audio { retired.append((generation, audio)) }
            generation += 1
            audio = track
            scratching = false
            updateKeyLock()
            if let track {
                _ = crate_deck_set_audio(core, track.left, track.right, Int64(track.frames), track.sampleRate, generation)
            } else {
                _ = crate_deck_set_audio(core, nil, nil, 0, sampleRate, generation)
            }
        }
    }

    public var track: TrackAudio? { lock.withLock { audio } }

    // MARK: State

    /// The loudest sample the deck has made before its fader (after trim, EQ, filter and echo) since
    /// this was last read; 1 is full scale. For the channel's level meter, and for it alone: reading
    /// starts the next measurement.
    public func takeLevel() -> Float { crate_deck_take_level(core) }

    public func state() -> DeckState {
        var snapshot = CrateDeckSnapshot()
        crate_deck_snapshot(core, &snapshot)
        return lock.withLock {
            // Old audio can go once the audio thread reports a newer generation.
            retired.removeAll { $0.generation < snapshot.audioGeneration }
            var state = DeckState()
            state.frame = snapshot.frame
            state.lead = lead
            state.frameOffset = frameOffset
            state.peak = snapshot.peak
            guard let audio else { return state }
            state.hasTrack = true
            state.duration = audio.duration
            state.loadProgress = audio.progress
            // Until the audio thread has picked the new track up, its snapshot describes the old one.
            guard snapshot.audioGeneration == generation else { return state }
            // What is heard now left the deck `lead` frames ago.
            state.position = max(0, snapshot.position / audio.sampleRate - Double(lead) / sampleRate * snapshot.speed)
            state.speed = snapshot.speed
            state.travel = snapshot.travel / audio.sampleRate
            state.isPlaying = snapshot.playing && !snapshot.ended
            state.isEnded = snapshot.ended
            state.isScratching = snapshot.scratching
            if snapshot.looping {
                state.loop = (snapshot.loopStart / audio.sampleRate)...(snapshot.loopEnd / audio.sampleRate)
                state.loopPass = Int(snapshot.loopWraps)
            }
            return state
        }
    }

    // MARK: Transport

    /// Starts the platter. `spinUp` is how long it takes to reach speed.
    public func play(spinUp: Double = 0, at frame: Int64 = 0) {
        lock.withLock { send(CrateCmdMotor, a: 1, b: spinUp, at: frame) }
    }

    /// Stops the platter. A `brake` of a second or so is a tape stop.
    public func pause(brake: Double = 0, at frame: Int64 = 0) {
        lock.withLock { send(CrateCmdMotor, a: 0, b: brake, at: frame) }
    }

    /// Runs the platter at any speed, negative for backwards (a rewind).
    public func spin(speed: Double, reaching: Double = 0, at frame: Int64 = 0) {
        lock.withLock { send(CrateCmdMotor, a: speed, b: reaching, at: frame) }
    }

    public func seek(to seconds: Double, at frame: Int64 = 0) {
        lock.withLock {
            guard let audio else { return }
            send(CrateCmdSeek, a: max(0, min(seconds, audio.duration)) * audio.sampleRate, at: frame)
        }
    }

    /// Loops between two points, in seconds.
    public func loop(from start: Double, to end: Double, at frame: Int64 = 0) {
        lock.withLock {
            guard let audio, end > start else { return }
            send(CrateCmdLoop, a: start * audio.sampleRate, b: end * audio.sampleRate, at: frame)
        }
    }

    public func endLoop(at frame: Int64 = 0) {
        lock.withLock { send(CrateCmdLoopOff, at: frame) }
    }

    // MARK: Controls

    /// Moves a control to `value`. `over` is the glide in seconds (0: a few milliseconds, enough not to click).
    public func set(_ param: DeckParam, to value: Double, over seconds: Double = 0, at frame: Int64 = 0) {
        lock.withLock {
            values[param] = value
            send(CrateCmdRamp, param: param, a: value, b: seconds > 0 ? max(1, seconds * sampleRate) : 0, at: frame)
            if param == .tempo { updateKeyLock() }
        }
    }

    /// The last value each control was set to (its target, if it is still gliding).
    public func value(of param: DeckParam) -> Double { lock.withLock { values[param] ?? 0 } }

    /// Gives the deck its metronome: a click on each of `beats` (seconds into the
    /// track), a higher one where `accents` is true. `level` 0 turns it off.
    public func setMetronome(beats: [Double], accents: [Bool], level: Double) {
        lock.withLock {
            guard let audio else { return }
            let positions = beats.map { $0 * audio.sampleRate }
            let flags = accents.map { UInt8($0 ? 1 : 0) }
            if positions.count == flags.count {
                _ = positions.withUnsafeBufferPointer { positionBuffer in
                    flags.withUnsafeBufferPointer { flagBuffer in
                        crate_deck_set_clicks(core, positionBuffer.baseAddress, flagBuffer.baseAddress, Int32(positions.count))
                    }
                }
            }
            values[.click] = level
            send(CrateCmdRamp, param: .click, a: level, b: 1)
        }
    }

    public func clearEcho(at frame: Int64 = 0) {
        lock.withLock { send(CrateCmdEchoClear, at: frame) }
    }

    // MARK: Key lock

    /// With key lock on, changing the tempo keeps the track's pitch. Off is
    /// varispeed, like a turntable, and the cleaner sound. Apple's pitch shifter
    /// buffers about 80 ms even when idle, so it is only in the deck's path while
    /// key lock is on; the deck then answers the controls that much later.
    public var keyLock: Bool {
        get { lock.withLock { keyLockOn } }
        set {
            let changed: Bool = lock.withLock {
                guard keyLockOn != newValue else { return false }
                keyLockOn = newValue
                updateKeyLock()
                return true
            }
            if changed { rewire?(newValue) }
        }
    }

    /// Called by the engine with what it measured, in frames.
    func setTiming(lead: Int64, frameOffset: Int64) {
        lock.withLock {
            self.lead = lead
            self.frameOffset = frameOffset
        }
    }

    private func updateKeyLock() {
        // Called with the lock held. The speed change raised the pitch by log2(tempo) octaves; shift it back.
        // While scratching the pitch should follow the hand, so the correction is dropped.
        let tempo = max(0.25, min(4, values[.tempo] ?? 1))
        keyLockUnit.pitch = keyLockOn && !scratching ? Float(-1200 * log2(tempo)) : 0
    }

    // MARK: Scratching

    /// Takes hold of the record. It then follows `scratch(to:)` until `endScratch`.
    public func beginScratch(at seconds: Double) {
        lock.withLock {
            guard let audio else { return }
            scratching = true
            updateKeyLock()  // a scratch is always pitch and speed together
            crate_deck_set_scratch_target(core, seconds * audio.sampleRate)
            send(CrateCmdScratch, a: 1)
        }
    }

    public func scratch(to seconds: Double) {
        lock.withLock {
            guard let audio, scratching else { return }
            crate_deck_set_scratch_target(core, max(0, min(seconds, audio.duration)) * audio.sampleRate)
        }
    }

    /// Lets go. The record carries on at the speed it was moving and settles to the motor's speed over `settle` seconds.
    public func endScratch(settle: Double = 0.25) {
        lock.withLock {
            guard scratching else { return }
            scratching = false
            send(CrateCmdScratch, a: 0, b: settle)
            updateKeyLock()
        }
    }
}
