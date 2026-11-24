import AVFoundation
import Foundation

/// Decoded audio prepared for analysis: a waveform overview of the whole
/// track, and a low-rate mono copy for tempo and key detection.
public struct DecodedAudio: Sendable {
    /// Peak level per slice of the track, 0...255.
    public var waveform: Data
    /// Bass, mid and high levels at 50 slices a second, for the scrolling waveform.
    public var detail: WaveDetail
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: Double
}

public struct AnalysisResult: Equatable, Sendable {
    public var bpm: BPMDetector.Estimate?
    public var key: KeyDetector.Estimate?
    public var waveformBins: Int
    public var grid: BeatGrid?
}

public enum AudioAnalyzer {
    public static let waveformBins = 1200
    /// Tempo and key are measured on at most this much audio, taken from the middle of the track.
    static let analysisSeconds = 240.0

    public enum AnalysisError: Error, LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Could not decode \(path)."
            }
        }
    }

    public static func decode(path: String) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        } catch {
            throw AnalysisError.unreadable(path)
        }
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536)
        else { throw AnalysisError.unreadable(path) }

        // Decimate by averaging whole groups of samples; crude, but the detectors only need the low end.
        let ratio = max(1, Int((format.sampleRate / 11025).rounded()))
        let analysisRate = format.sampleRate / Double(ratio)
        let framesPerBin = max(1, Int((Double(totalFrames) / Double(waveformBins)).rounded(.up)))

        var peaks = [Float](repeating: 0, count: waveformBins)
        var bands = BandSplitter(sampleRate: format.sampleRate)
        bands.reserve(frames: totalFrames)
        var samples: [Float] = []
        samples.reserveCapacity(totalFrames / ratio + 1)
        var carry: Float = 0
        var carried = 0
        var position = 0

        while position < totalFrames {
            do {
                try file.read(into: buffer)
            } catch {
                break  // A truncated file still yields what could be read.
            }
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for frame in 0..<count {
                var mono: Float = 0
                for channel in 0..<channelCount { mono += channels[channel][frame] }
                mono /= Float(channelCount)

                let bin = min(waveformBins - 1, (position + frame) / framesPerBin)
                let magnitude = abs(mono)
                if magnitude > peaks[bin] { peaks[bin] = magnitude }
                bands.add(mono)

                carry += mono
                carried += 1
                if carried == ratio {
                    samples.append(carry / Float(ratio))
                    carry = 0
                    carried = 0
                }
            }
            position += count
        }
        guard position > 0 else { throw AnalysisError.unreadable(path) }

        let waveform = Data(peaks.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
        return DecodedAudio(
            waveform: waveform, detail: bands.finish(), samples: samples, sampleRate: analysisRate,
            duration: Double(position) / format.sampleRate)
    }

    public static func analyze(_ audio: DecodedAudio) -> AnalysisResult {
        var window = audio.samples[...]
        let limit = Int(analysisSeconds * audio.sampleRate)
        if window.count > limit {
            let start = (window.count - limit) / 2
            window = window[start..<(start + limit)]
        }
        let samples = Array(window)
        return AnalysisResult(
            bpm: BPMDetector.estimate(samples: samples, sampleRate: audio.sampleRate),
            key: KeyDetector.estimate(samples: samples, sampleRate: audio.sampleRate),
            waveformBins: audio.waveform.count, grid: nil)
    }

    /// Analyses one local track and saves the result. Returns nil if its file cannot be reached.
    @discardableResult
    public static func analyze(track: Track, store: LibraryStore) throws -> AnalysisResult? {
        guard let path = Volumes.resolvedPath(for: track) else { return nil }
        let audio = try decode(path: path)
        var result = analyze(audio)
        // The beat grid starts from the best tempo known: a tag or a hand-entered value beats the estimate.
        let trusted = track.bpmSource == .tag || track.bpmSource == .manual ? track.bpm : nil
        if let tempo = trusted ?? result.bpm?.bpm ?? track.bpm {
            result.grid = BeatTracker.track(samples: audio.samples, sampleRate: audio.sampleRate, bpm: tempo)
        }
        // The grid measures tempo over the whole track, so it improves on the estimate where there is no tag.
        let bpm = result.grid.map { ($0.bpm * 100).rounded() / 100 } ?? result.bpm?.bpm
        try store.setAnalysis(
            id: track.id, bpm: bpm, key: result.key?.key.description, waveform: audio.waveform,
            detail: audio.detail)
        try store.setBeatGrid(id: track.id, result.grid, edited: false)
        return result
    }
}
