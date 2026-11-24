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
}

/// The sampler: eight pads that each play a short piece of audio when hit.
///
/// The playing is done on the audio thread by C code; this is the handle on it.
public final class Sampler: @unchecked Sendable {
    public static let padCount = Int(CRATE_SAMPLER_PADS)
    /// The longest piece of audio a pad takes, in seconds. A sampler is for hits and loops, not whole tracks.
    public static let longest = 120.0

    public struct PadState: Equatable, Sendable {
        public var isPlaying = false
        /// How far through its audio the pad is, 0...1.
        public var progress = 0.0
    }

    let node: AVAudioSourceNode
    private let core: OpaquePointer
    private let lock = NSLock()
    private var clips: [SampleClip?]
    private var gains: [Double]
    private var loops: [Bool]

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

    /// Plays a pad from its start. Hit again while sounding, it starts again.
    public func trigger(_ pad: Int) {
        guard isPad(pad) else { return }
        lock.withLock { _ = crate_sampler_trigger(core, Int32(pad)) }
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

    /// The sampler's level into the mix and its way to the headphones; the engine sets these from the mixer.
    func setLevels(master: Double, cue: Double, monitor: Double) {
        crate_sampler_set_levels(core, master, cue, monitor)
    }

    public func state() -> [PadState] {
        var snapshot = CrateSamplerSnapshot()
        crate_sampler_snapshot(core, &snapshot)
        let playing = withUnsafeBytes(of: snapshot.playing) { Array($0.bindMemory(to: Bool.self)) }
        let progress = withUnsafeBytes(of: snapshot.progress) { Array($0.bindMemory(to: Float.self)) }
        return (0..<Self.padCount).map { PadState(isPlaying: playing[$0], progress: Double(progress[$0])) }
    }
}
