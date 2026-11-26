import Accelerate
import AVFoundation
import CrateDSP
import Foundation

/// A piece of audio on a sampler pad: a whole file, or a stretch of one (a loop taken from a deck).
public struct SampleClip: @unchecked Sendable {
    public let audio: TrackAudio
    /// The frames of `audio` the pad plays.
    public let range: Range<Int>

    public init(audio: TrackAudio, range: Range<Int>? = nil) {
        self.audio = audio
        let whole = 0..<audio.frames
        self.range = range.map { $0.clamped(to: whole) } ?? whole
    }

    /// A stretch given in seconds.
    public init(audio: TrackAudio, from start: Double, to end: Double) {
        let first = max(0, Int((start * audio.sampleRate).rounded())), last = Int((end * audio.sampleRate).rounded())
        self.init(audio: audio, range: first..<max(first, last))
    }

    public var duration: Double { Double(range.count) / audio.sampleRate }

    /// The clip's outline for drawing: the loudest sample in each of `bins` equal stretches,
    /// scaled so that the loudest of all is 1.
    public func peaks(bins: Int) -> [Float] {
        guard bins > 0, !range.isEmpty else { return [] }
        var peaks = [Float](repeating: 0, count: bins)
        for bin in 0..<bins {
            let from = range.lowerBound + range.count * bin / bins, to = range.lowerBound + range.count * (bin + 1) / bins
            guard to > from else { continue }
            vDSP_maxmgv(audio.left + from, 1, &peaks[bin], vDSP_Length(to - from))
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}

/// The sampler: sixteen pads that each play a short piece of audio when hit, a bank of eight
/// for each deck. Pad `deck * 8 + slot` is that deck's pad `slot`.
///
/// The playing is done on the audio thread by C code; this is the handle on it.
public final class Sampler: @unchecked Sendable {
    public static let padCount = Int(CRATE_SAMPLER_PADS)
    /// The pad that is `slot` (0...7) of a deck's bank.
    public static func pad(_ slot: Int, of deck: DeckID) -> Int { deck.rawValue * SampleBank.size + slot }
    /// The longest piece of audio a pad takes, in seconds. A sampler is for hits and loops, not whole tracks.
    public static let longest = 120.0

    public struct PadState: Equatable, Sendable {
        /// Sounding, or hit and waiting for the beat it starts on.
        public var isPlaying = false
        /// Sound is coming out of it.
        public var isSounding = false
        /// How far through its audio the pad is, 0...1.
        public var progress = 0.0
        /// Seconds into its audio.
        public var position = 0.0
    }

    let node: AVAudioSourceNode
    private let core: OpaquePointer
    private let lock = NSLock()
    private var clips: [SampleClip?]
    private var gains: [Double]
    private var loops: [Bool]
    private var offset: Int64 = 0

    init(sampleRate: Double) {
        guard let core = crate_sampler_create(sampleRate) else { fatalError("out of memory creating the sampler") }
        self.core = core
        clips = Array(repeating: nil, count: Self.padCount)
        gains = Array(repeating: 1, count: Self.padCount)
        loops = Array(repeating: false, count: Self.padCount)
        // As for a deck: four channels, and the block holds only the C pointer.
        node = AVAudioSourceNode(format: DeckEngine.format(sampleRate: sampleRate)) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
            let phones = buffers.count >= 4 ? (buffers[2].mData, buffers[3].mData) : (nil, nil)
            crate_sampler_render(
                core, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self),
                phones.0?.assumingMemoryBound(to: Float.self), phones.1?.assumingMemoryBound(to: Float.self), Int32(frameCount))
            return noErr
        }
    }

    deinit {
        crate_sampler_destroy(core)
    }

    private func isPad(_ pad: Int) -> Bool { (0..<Self.padCount).contains(pad) }

    /// Puts audio on a pad, or takes it off with nil. Whatever the pad was playing fades out.
    public func load(_ clip: SampleClip?, on pad: Int) {
        guard isPad(pad) else { return }
        let old = lock.withLock { () -> SampleClip? in
            let old = clips[pad]
            clips[pad] = clip
            if let clip, !clip.range.isEmpty {
                let right = clip.audio.channels == 2 ? clip.audio.right : clip.audio.left
                crate_sampler_set_audio(
                    core, Int32(pad), clip.audio.left + clip.range.lowerBound, right + clip.range.lowerBound,
                    Int64(clip.range.count), clip.audio.sampleRate)
            } else {
                crate_sampler_set_audio(core, Int32(pad), nil, nil, 0, 0)
            }
            return old
        }
        // The audio thread may be part-way through the old audio, and fades what was sounding out of it
        // over a few milliseconds. Keeping the old audio a little longer costs nothing and makes that safe.
        if let old {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { _ = old }
        }
    }

    public func clip(on pad: Int) -> SampleClip? {
        lock.withLock { isPad(pad) ? clips[pad] : nil }
    }

    /// Plays a pad. Hit again while sounding, it starts again.
    ///
    /// - Parameters:
    ///   - seconds: where in its audio to start. Anywhere but the top is faded in.
    ///   - rate: its speed; 1 is as recorded.
    ///   - frame: the frame of the sampler's own count (`snapshot().frame`) to start on; 0 is straight
    ///     away. A frame that has gone by still comes out in time for a pad that loops: it starts as far
    ///     in as it would have got. A one-shot starts where it was told to, late but whole.
    public func trigger(_ pad: Int, from seconds: Double = 0, rate: Double = 1, at frame: Int64 = 0) {
        guard isPad(pad) else { return }
        lock.withLock {
            let sourceRate = clips[pad]?.audio.sampleRate ?? 0
            _ = crate_sampler_trigger_at(core, Int32(pad), frame, max(0, seconds) * sourceRate, rate > 0 ? rate : 1)
        }
    }

    /// Changes the speed of a pad as it plays; 1 is as recorded. The next hit sets it again.
    public func setRate(_ rate: Double, on pad: Int) {
        guard isPad(pad), rate > 0 else { return }
        lock.withLock { _ = crate_sampler_set_rate(core, Int32(pad), rate) }
    }

    /// Stops a pad, or every pad with nil. The sound fades over a few milliseconds.
    public func stop(_ pad: Int? = nil) {
        lock.withLock { _ = crate_sampler_stop(core, Int32(pad ?? -1)) }
    }

    /// A pad's own level, and whether it goes round and round until stopped.
    public func set(gain: Double? = nil, loops: Bool? = nil, on pad: Int) {
        guard isPad(pad) else { return }
        lock.withLock {
            if let gain { gains[pad] = gain }
            if let loops { self.loops[pad] = loops }
            _ = crate_sampler_set_pad(core, Int32(pad), gains[pad], self.loops[pad])
        }
    }

    /// Whether a pad goes round and round until stopped.
    public func loops(on pad: Int) -> Bool { lock.withLock { isPad(pad) && loops[pad] } }

    /// The sampler's level into the mix and its way to the headphones; the engine sets these from the mixer.
    func setLevels(master: Double, cue: Double, monitor: Double) {
        crate_sampler_set_levels(core, master, cue, monitor)
    }

    public func state() -> [PadState] { snapshot().pads }

    /// What every pad is doing, as of `frame` of the sampler's own count of the frames it has rendered.
    public func snapshot() -> (frame: Int64, pads: [PadState]) {
        var snapshot = CrateSamplerSnapshot()
        crate_sampler_snapshot(core, &snapshot)
        let playing = withUnsafeBytes(of: snapshot.playing) { Array($0.bindMemory(to: Bool.self)) }
        let sounding = withUnsafeBytes(of: snapshot.sounding) { Array($0.bindMemory(to: Bool.self)) }
        let progress = withUnsafeBytes(of: snapshot.progress) { Array($0.bindMemory(to: Float.self)) }
        let position = withUnsafeBytes(of: snapshot.position) { Array($0.bindMemory(to: Double.self)) }
        let rates = lock.withLock { clips.map { $0?.audio.sampleRate ?? 0 } }
        return (snapshot.frame, (0..<Self.padCount).map {
            PadState(
                isPlaying: playing[$0], isSounding: sounding[$0], progress: Double(progress[$0]),
                position: rates[$0] > 0 ? position[$0] / rates[$0] : 0)
        })
    }

    /// The sampler's frame count minus the engine's output frame: a start meant to be heard at
    /// output frame T is asked for at T + frameOffset. Measured by the engine.
    public var frameOffset: Int64 {
        get { lock.withLock { offset } }
        set { lock.withLock { offset = newValue } }
    }
}
