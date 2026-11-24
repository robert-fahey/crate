import AVFoundation
import Foundation

/// A track decoded into memory for a deck to play. The decks read it at any
/// speed and in either direction, which a streaming decoder cannot offer.
///
/// About 20 MB per minute of stereo audio. The memory starts as silence and is
/// filled in by `decode`, so a deck can start playing before decoding finishes.
/// It is asked for already zeroed, which costs nothing until it is written to:
/// reserving an hour-long mix (over a gigabyte) takes no longer than a jingle.
public final class TrackAudio: @unchecked Sendable {
    public let frames: Int
    public let sampleRate: Double
    public let channels: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    private let state = NSLock()
    private var cancelled = false
    private var decoded = 0

    public var duration: Double { Double(frames) / sampleRate }
    /// How much has been decoded so far, 0...1.
    public var progress: Double { state.withLock { frames > 0 ? Double(decoded) / Double(frames) : 1 } }

    init(frames: Int, channels: Int, sampleRate: Double) {
        self.frames = max(0, frames)
        self.channels = max(1, min(2, channels))
        self.sampleRate = sampleRate
        let count = max(1, self.frames)
        func silence() -> UnsafeMutablePointer<Float> {
            guard let memory = calloc(count, MemoryLayout<Float>.stride) else { fatalError("Out of memory for a track of \(count) frames") }
            return memory.bindMemory(to: Float.self, capacity: count)
        }
        left = silence()
        right = self.channels == 2 ? silence() : left
    }

    deinit {
        if right != left { free(right) }
        free(left)
    }

    /// Audio already in memory, as for tests and for rendering.
    public convenience init(left: [Float], right: [Float]? = nil, sampleRate: Double) {
        self.init(frames: left.count, channels: right == nil ? 1 : 2, sampleRate: sampleRate)
        left.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { self.left.update(from: base, count: min(frames, source.count)) }
        }
        right?.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { self.right.update(from: base, count: min(frames, source.count)) }
        }
        state.withLock { decoded = frames }
    }

    // A slow drive serves one reader at a time. While a track is being fetched for a deck,
    // the background decoding of tracks already loaded stands aside, so the new track does
    // not queue behind tens of megabytes nobody is waiting for.
    private static let urgencyLock = NSLock()
    private static var urgentFetches = 0

    /// Runs work that someone is waiting on (a track's opening seconds), ahead of background decoding.
    public static func urgently<T>(_ work: () throws -> T) rethrows -> T {
        urgencyLock.withLock { urgentFetches += 1 }
        defer { urgencyLock.withLock { urgentFetches -= 1 } }
        return try work()
    }

    private static var isFetchWaiting: Bool { urgencyLock.withLock { urgentFetches > 0 } }

    /// Opens a file and reserves the memory. Call `decode` to fill it.
    public static func open(path: String) throws -> (audio: TrackAudio, file: AVAudioFile) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        } catch {
            throw AudioAnalyzer.AnalysisError.unreadable(path)
        }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0 else { throw AudioAnalyzer.AnalysisError.unreadable(path) }
        let audio = TrackAudio(frames: Int(file.length), channels: Int(format.channelCount), sampleRate: format.sampleRate)
        return (audio, file)
    }

    /// Decodes the file into memory, carrying on from wherever the last call
    /// stopped. Safe to run while a deck is already playing the start: decode the
    /// first second, start the deck, and decode the rest in the background.
    public func decode(from file: AVAudioFile, upTo limit: Int? = nil) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { return }
        var position = state.withLock { decoded }
        let end = min(frames, limit ?? frames)
        // Background decoding gives way to a fetch, but only once it is well ahead of where a deck
        // could be playing, and not for long: its own deck must never run out of audio.
        var stoodAside = 0.0
        let wellAhead = Int(sampleRate * 30)
        while position < end {
            if state.withLock({ cancelled }) { return }
            while limit == nil, position >= wellAhead, stoodAside < 2, Self.isFetchWaiting {
                usleep(5000)
                stoodAside += 0.005
                if state.withLock({ cancelled }) { return }
            }
            do { try file.read(into: buffer) } catch { break }  // a truncated file plays as far as it decodes
            let count = min(Int(buffer.frameLength), frames - position)
            guard count > 0, let data = buffer.floatChannelData else { break }
            (left + position).update(from: data[0], count: count)
            if channels == 2 { (right + position).update(from: data[1], count: count) }
            position += count
            state.withLock { decoded = position }
        }
        if limit == nil { state.withLock { decoded = frames } }
    }

    public func cancelDecoding() { state.withLock { cancelled = true } }

    /// Opens and fully decodes a file.
    public static func load(path: String) throws -> TrackAudio {
        let (audio, file) = try open(path: path)
        audio.decode(from: file)
        return audio
    }
}
