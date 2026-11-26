import Accelerate
import AVFoundation
import CrateDSP
import Foundation

/// Two channels of rendered audio.
public struct StereoAudio: Sendable {
    public var left: [Float] = []
    public var right: [Float] = []
    public var sampleRate: Double
    public var frames: Int { left.count }
}

/// The two decks and the mixer between them.
///
///     Deck A ─ (key lock) ─┐
///     Deck B ─ (key lock) ─┴─ mix ─ limiter ─ output
///
/// Everything along that path carries four channels: the master mix on the first
/// pair and what the headphones hear on the second. A deck renders both at once,
/// so the cue in the headphones is in step with the master to the sample, with
/// or without key lock. A sound card with four outputs (a DJ controller) gets
/// both pairs; an ordinary stereo output gets the first.
///
/// EQ, filter, echo and the channel gain are inside each deck's audio core, so
/// they can be automated to the sample. In `offline` mode nothing is played:
/// `render` produces the audio instead, which is how the timing is tested and
/// how a mix can be bounced to a file.
public final class DeckEngine: @unchecked Sendable {
    /// Decks run at this rate; tracks at 44.1 kHz play sample for sample. The
    /// mixer converts to whatever the output device wants.
    public static let sampleRate = 44100.0
    /// Offline rendering proceeds in slices of this many frames, with `tick` between them.
    public static let sliceFrames = 512

    public let decks: [Deck]
    public let sampler: Sampler
    public let isOffline: Bool
    private let engine = AVAudioEngine()
    private let limiter: AVAudioUnitEffect
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var mixer = MixerSettings()
    private var ticker: DispatchSourceTimer?
    private let startLock = NSLock()
    private let clock: OpaquePointer
    private let clockNode: AVAudioSourceNode
    private var offsetCandidates: [Int64] = [0, 0]
    /// Each deck's frame count minus the output's, as it stood with no pitch shifter in the path.
    private var offsetBaselines: [Int64] = [0, 0]
    private var needsBaseline = [false, false]
    private var samplerOffsetCandidate: Int64?
    private var configurationObserver: NSObjectProtocol?
    private var recording: AVAudioFile?
    private var recordedFrames: Int64 = 0
    /// The loudest sample of the master's left and right since they were last read, if anything
    /// has been measured since; and the latest measurement, with when it was made.
    private var peaksSinceRead: [Float]?
    private var latestPeaks: [Float] = [0, 0]
    private var latestPeaksAt: TimeInterval = 0
    private var tickHandlers: [() -> Void] = []
    private var deviceChannels = 2
    private var chosenDevice: AudioDeviceID?

    public struct MixerSettings: Equatable, Sendable {
        /// Channel faders, 0...1.
        public var fader: [Double] = [1, 1]
        /// Per-deck trim, linear gain.
        public var trim: [Double] = [1, 1]
        /// -1 is all deck A, 1 is all deck B. Both decks are at full level across the middle.
        public var crossfader = 0.0
        public var master = 1.0
        /// Which decks the headphones listen to before their faders.
        public var cue: [Bool] = [false, false]
        /// What the headphones hear: 0 is the cued decks only, 1 the master mix only, both in full at the middle.
        public var headphoneMix = 0.5
        public var headphoneLevel = 1.0
        /// The sampler's level into the mix, and whether the headphones listen to it whatever that level is.
        public var sampler = 1.0
        public var samplerCue = false
    }

    /// The format everything inside the engine uses: master left and right, headphones left and right.
    public static func format(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
    }

    public init(offline: Bool = false) throws {
        isOffline = offline
        format = Self.format(sampleRate: Self.sampleRate)
        decks = DeckID.allCases.map { Deck(id: $0, sampleRate: Self.sampleRate) }
        sampler = Sampler(sampleRate: Self.sampleRate)
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

        // A silent source wired straight to the mixer: it is asked for exactly the
        // frames the output gets, so it counts output time.
        guard let clock = crate_clock_create() else { fatalError("out of memory creating the clock") }
        self.clock = clock
        clockNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            crate_clock_advance(clock, Int32(frameCount))
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
            return noErr
        }

        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        engine.attach(limiter)
        engine.attach(clockNode)
        engine.connect(clockNode, to: engine.mainMixerNode, fromBus: 0, toBus: decks.count, format: format)
        engine.attach(sampler.node)
        engine.connect(sampler.node, to: engine.mainMixerNode, fromBus: 0, toBus: decks.count + 1, format: format)
        for deck in decks {
            engine.attach(deck.node)
            engine.attach(deck.keyLockUnit)
            wire(deck, keyLock: false)
            deck.rewire = { [weak self, weak deck] keyLock in
                guard let self, let deck else { return }
                self.rewire(deck, keyLock: keyLock)
            }
        }
        connectOutput()
        applyMixer()
        installOutputTap()
        if !offline {
            // Plugging in headphones or changing the output device stops the engine.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in self?.outputChanged() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        ticker?.cancel()
        engine.stop()
        crate_clock_destroy(clock)
    }

    private func outputChanged() {
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 else { return }
        connectOutput()
        try? engine.start()
        // Reconnecting can put the mixer's volume back to full; the knob must still mean what it shows.
        applyMixer()
        onOutputChange?()
    }

    /// Joins the mix to the output device at the device's sample rate, and says which of the
    /// engine's four channels go to which of the device's outputs.
    private func connectOutput() {
        let device = isOffline ? nil : engine.outputNode.outputFormat(forBus: 0)
        let rate = device.map { $0.sampleRate > 0 ? $0.sampleRate : Self.sampleRate } ?? Self.sampleRate
        let outputFormat = Self.format(sampleRate: rate)
        engine.connect(engine.mainMixerNode, to: limiter, format: outputFormat)
        engine.connect(limiter, to: engine.outputNode, format: outputFormat)
        installMeterTap()
        guard let device else {
            lock.withLock { deviceChannels = 4 }  // offline, the headphone pair is simply rendered
            return
        }
        let channels = max(1, Int(device.channelCount))
        // Master to the first pair of outputs, headphones to the second if the device has one. Any further outputs stay silent.
        engine.outputNode.auAudioUnit.channelMap = (0..<channels).map { NSNumber(value: $0 < 4 ? $0 : -1) }
        lock.withLock { deviceChannels = channels }
    }

    /// Called after the output device or its format has changed.
    public var onOutputChange: (() -> Void)?

    /// True when the output has a second stereo pair for headphones.
    public var hasHeadphoneOutput: Bool { lock.withLock { deviceChannels >= 4 } }

    /// The device sound is going to, once one has been chosen with `setOutputDevice`.
    public var outputDevice: AudioDeviceID? { lock.withLock { chosenDevice } }

    /// Sends sound to a particular device. The decks carry on from where they were.
    public func setOutputDevice(_ device: AudioDeviceID) throws {
        guard !isOffline, lock.withLock({ chosenDevice }) != device else { return }
        startLock.lock()
        defer { startLock.unlock() }
        // "Running" includes having been stopped by the system because the old device went away.
        let wasRunning = engine.isRunning || ticker != nil
        engine.stop()
        try engine.outputNode.auAudioUnit.setDeviceID(device)
        lock.withLock { chosenDevice = device }
        connectOutput()
        applyMixer()
        if wasRunning { try engine.start() }
        onOutputChange?()
    }

    /// Output frames rendered so far.
    public var outputFrame: Int64 { crate_clock_frames(clock) }

    private func wire(_ deck: Deck, keyLock: Bool) {
        let bus = deck.id.rawValue
        if keyLock {
            engine.connect(deck.node, to: deck.keyLockUnit, format: format)
            engine.connect(deck.keyLockUnit, to: engine.mainMixerNode, fromBus: 0, toBus: bus, format: format)
        } else {
            engine.connect(deck.node, to: engine.mainMixerNode, fromBus: 0, toBus: bus, format: format)
        }
    }

    /// Moves the pitch shifter into or out of a deck's path. The shifter holds a
    /// buffer of audio; taking it out would drop that buffer and skip the track
    /// forward, so the deck is wound back by the same amount.
    private func rewire(_ deck: Deck, keyLock: Bool) {
        let before = deck.state()
        engine.disconnectNodeOutput(deck.node)
        engine.disconnectNodeOutput(deck.keyLockUnit)
        if !keyLock { deck.keyLockUnit.reset() }
        wire(deck, keyLock: keyLock)
        if !keyLock {
            // The frames the shifter had buffered were rendered but will never be heard:
            // from here on the deck's count is simply that much ahead of the output's.
            // Rewiring can pull a few more, so the new baseline is taken from the next measurement.
            lock.withLock { needsBaseline[deck.id.rawValue] = true }
            deck.setTiming(lead: 0, frameOffset: before.frameOffset)
            if before.hasTrack, before.lead > 0 { deck.seek(to: before.position) }
        }
    }

    /// Measures how far each deck is rendered ahead of the output. A reading is
    /// trusted once it has been seen twice running, as the two counters are
    /// updated at slightly different moments of a render.
    private func measureLeads() {
        for deck in decks {
            let before = crate_clock_frames(clock)
            let frame = deck.state().frame
            guard crate_clock_frames(clock) == before else { continue }
            let offset = frame - before
            let index = deck.id.rawValue
            let (confirmed, baseline) = lock.withLock { () -> (Bool, Int64) in
                defer { offsetCandidates[index] = offset }
                let confirmed = offsetCandidates[index] == offset
                if confirmed, needsBaseline[index] {
                    needsBaseline[index] = false
                    offsetBaselines[index] = offset
                }
                return (confirmed, offsetBaselines[index])
            }
            if confirmed, deck.state().frameOffset != offset {
                deck.setTiming(lead: max(0, offset - baseline), frameOffset: offset)
            }
        }
    }

    /// The same for the sampler, which is wired straight to the mix: how its frame count stands to the output's.
    private func measureSamplerOffset() {
        let before = crate_clock_frames(clock)
        let frame = sampler.snapshot().frame
        guard crate_clock_frames(clock) == before else { return }
        let offset = frame - before
        let confirmed = lock.withLock { () -> Bool in
            defer { samplerOffsetCandidate = offset }
            return samplerOffsetCandidate == offset
        }
        if confirmed, sampler.frameOffset != offset { sampler.frameOffset = offset }
    }

    public func deck(_ id: DeckID) -> Deck { decks[id.rawValue] }

    /// Starts the audio hardware if it is not running. Safe from any thread: decks call it
    /// from the background while a track loads, because it can take a noticeable moment.
    public func start() throws {
        startLock.lock()
        defer { startLock.unlock() }
        guard !engine.isRunning else { return }
        try engine.start()
        guard !isOffline, ticker == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "crate.deck-engine.tick", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        engine.stop()
    }

    public var isRunning: Bool { engine.isRunning }

    // MARK: Mixer

    public var settings: MixerSettings {
        get { lock.withLock { mixer } }
        set {
            lock.withLock { mixer = newValue }
            applyMixer()
        }
    }

    /// The gain the crossfader gives each deck: full across the middle, falling to nothing at the far side.
    public static func crossfaderGains(_ position: Double) -> [Double] {
        let x = (max(-1, min(1, position)) + 1) / 2
        return [min(1, 2 * (1 - x)), min(1, 2 * x)]
    }

    private func applyMixer() {
        let (mixer, hasPhones) = lock.withLock { (self.mixer, deviceChannels >= 4) }
        let cross = Self.crossfaderGains(mixer.crossfader)
        // Like a crossfader: cue and master are both in full at the middle of the headphone mix.
        let level = hasPhones ? max(0, mixer.headphoneLevel) : 0
        let cueShare = min(1, 2 * (1 - mixer.headphoneMix)) * level, masterShare = min(1, 2 * mixer.headphoneMix) * level
        for deck in decks {
            let index = deck.id.rawValue
            deck.set(.trim, to: mixer.trim[index])
            // The master volume is part of each deck's gain, not the mixer's, so it leaves the headphones' cue alone.
            deck.set(.gain, to: mixer.fader[index] * cross[index] * max(0, min(1, mixer.master)))
            deck.set(.cue, to: mixer.cue[index] ? cueShare : 0)
            deck.set(.monitor, to: masterShare)
        }
        // The sampler goes straight to the mix, past the crossfader.
        sampler.setLevels(
            master: max(0, mixer.sampler) * max(0, min(1, mixer.master)), cue: mixer.samplerCue ? cueShare : 0, monitor: masterShare)
        engine.mainMixerNode.outputVolume = 1
    }

    // MARK: Master level and recording

    /// Listens to the mix as it goes into the limiter, for the master meter. Measured there and not
    /// after it, so the meter can show how far over full scale the mix is being pushed: what comes
    /// out of the limiter never is. Put back whenever the output is reconnected, as its format may have changed.
    private func installMeterTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            // The master is the first pair; the headphones' pair is not metered.
            let channels = min(2, Int(buffer.format.channelCount))
            guard channels > 0 else { return }
            var peaks: [Float] = [0, 0]
            for channel in 0..<channels {
                var peak: Float = 0
                vDSP_maxmgv(data[channel], 1, &peak, vDSP_Length(buffer.frameLength))
                peaks[channel] = peak
            }
            if channels == 1 { peaks[1] = peaks[0] }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.withLock {
                let held = self.peaksSinceRead ?? [0, 0]
                self.peaksSinceRead = [max(held[0], peaks[0]), max(held[1], peaks[1])]
                self.latestPeaks = peaks
                self.latestPeaksAt = now
            }
        }
    }

    /// Listens to what leaves the limiter, for recording.
    private func installOutputTap() {
        limiter.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            // The master is the first pair; the headphones' pair is not recorded.
            let masterChannels = min(2, Int(buffer.format.channelCount))
            let file: AVAudioFile? = self.lock.withLock {
                if self.recording != nil { self.recordedFrames += Int64(buffer.frameLength) }
                return self.recording
            }
            guard let file, let stereo = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2),
                  let master = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: buffer.frameLength), let copy = master.floatChannelData
            else { return }
            master.frameLength = buffer.frameLength
            for channel in 0..<2 {
                copy[channel].update(from: data[min(channel, masterChannels - 1)], count: Int(buffer.frameLength))
            }
            try? file.write(from: master)
        }
    }

    /// The loudest sample of the master mix, left and right, since this was last read. 1.0 is full
    /// scale; more than that is the mix being pushed into the limiter. Reading starts the next
    /// measurement, so no peak is missed however irregularly it is read.
    ///
    /// The mix is handed over for measuring a tenth of a second at a time, which is less often
    /// than a meter asks. Asked again before the next piece has come, this gives the latest
    /// measurement again rather than silence: a steady sound reads steady. With no piece for
    /// a third of a second the output has stopped, and that is silence.
    public func takeMasterPeaks() -> (left: Float, right: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            if let peaks = peaksSinceRead {
                peaksSinceRead = nil
                return (peaks[0], peaks[1])
            }
            return now - latestPeaksAt < 0.3 ? (latestPeaks[0], latestPeaks[1]) : (0, 0)
        }
    }

    /// The louder of the two.
    public func takeMasterPeak() -> Float {
        let peaks = takeMasterPeaks()
        return max(peaks.left, peaks.right)
    }

    /// Records the master output to a 16-bit WAV file until `stopRecording`.
    public func startRecording(to url: URL) throws {
        let format = limiter.outputFormat(forBus: 0)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            recording = file
            recordedFrames = 0
        }
    }

    /// Stops recording and returns how many seconds were written.
    @discardableResult
    public func stopRecording() -> Double {
        let rate = limiter.outputFormat(forBus: 0).sampleRate
        return lock.withLock {
            recording = nil  // releasing the file finishes it
            return rate > 0 ? Double(recordedFrames) / rate : 0
        }
    }

    public var isRecording: Bool { lock.withLock { recording != nil } }
    public var recordedSeconds: Double {
        let rate = limiter.outputFormat(forBus: 0).sampleRate
        return lock.withLock { rate > 0 ? Double(recordedFrames) / rate : 0 }
    }

    // MARK: Control step

    /// Adds work to run on every control step (about 100 times a second; once per slice offline).
    public func onTick(_ handler: @escaping () -> Void) {
        lock.withLock { tickHandlers.append(handler) }
    }

    /// One control step: stops decks that have run off the end, then runs the tick handlers (sync, automation).
    public func tick() {
        measureLeads()
        measureSamplerOffset()
        for deck in decks {
            let state = deck.state()
            if state.isEnded { deck.pause() }
        }
        for handler in lock.withLock({ tickHandlers }) { handler() }
    }

    // MARK: Offline rendering

    /// Renders the next stretch of audio. Offline mode only.
    public func render(seconds: Double) throws -> StereoAudio {
        try render(frames: Int((seconds * Self.sampleRate).rounded()))
    }

    /// The master mix.
    public func render(frames: Int) throws -> StereoAudio {
        try renderBoth(frames: frames).master
    }

    /// The master mix and what the headphones hear over the same stretch.
    public func renderBoth(seconds: Double) throws -> (master: StereoAudio, phones: StereoAudio) {
        try renderBoth(frames: Int((seconds * Self.sampleRate).rounded()))
    }

    public func renderBoth(frames: Int) throws -> (master: StereoAudio, phones: StereoAudio) {
        precondition(isOffline, "render is for offline engines")
        if !engine.isRunning { try engine.start() }
        var output = StereoAudio(sampleRate: Self.sampleRate), phones = StereoAudio(sampleRate: Self.sampleRate)
        output.left.reserveCapacity(frames)
        output.right.reserveCapacity(frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return (output, phones) }
        var remaining = frames
        while remaining > 0 {
            tick()
            let count = min(remaining, Self.sliceFrames)
            let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            guard status == .success, let data = buffer.floatChannelData else {
                throw NSError(domain: "DeckEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline render failed (\(status.rawValue))."])
            }
            let got = Int(buffer.frameLength)
            output.left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: got))
            output.right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: got))
            if buffer.format.channelCount >= 4 {
                phones.left.append(contentsOf: UnsafeBufferPointer(start: data[2], count: got))
                phones.right.append(contentsOf: UnsafeBufferPointer(start: data[3], count: got))
            }
            remaining -= got
            if got == 0 { break }
        }
        return (output, phones)
    }
}
