import AVFoundation
import XCTest
@testable import CrateCore

/// Synthesized audio with known tempo and key, so the detectors are checked
/// against ground truth rather than against their own output.
enum Synth {
    /// A four-on-the-floor pattern: kick on each beat, noise hat on each off-beat.
    static func beat(bpm: Double, seconds: Double, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var generator = SystemRandomNumberGenerator()
        let beat = 60 / bpm
        var time = 0.0
        var index = 0
        while time < seconds {
            let isKick = index % 2 == 0
            let start = Int((time * sampleRate).rounded())
            let length = Int((isKick ? 0.12 : 0.03) * sampleRate)
            for offset in 0..<length where start + offset < samples.count {
                let t = Double(offset) / sampleRate
                if isKick {
                    samples[start + offset] += Float(sin(2 * .pi * 60 * t) * exp(-t * 30)) * 0.8
                } else {
                    samples[start + offset] += Float.random(in: -1...1, using: &generator) * Float(exp(-t * 150)) * 0.3
                }
            }
            index += 1
            time = Double(index) * beat / 2
        }
        return samples
    }

    /// Chords as MIDI note lists, each held for `chordSeconds`, with a few harmonics per note.
    static func chords(
        _ progression: [[Int]], chordSeconds: Double, repeats: Int, sampleRate: Double, detuneCents: Double = 0
    ) -> [Float] {
        let chordLength = Int(chordSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: chordLength * progression.count * repeats)
        for repetition in 0..<repeats {
            for (chordIndex, chord) in progression.enumerated() {
                let base = (repetition * progression.count + chordIndex) * chordLength
                for note in chord {
                    let frequency = 440 * pow(2, (Double(note - 69) + detuneCents / 100) / 12)
                    for offset in 0..<chordLength {
                        let t = Double(offset) / sampleRate
                        var value = 0.0
                        for harmonic in 1...3 { value += sin(2 * .pi * frequency * Double(harmonic) * t) / Double(harmonic * harmonic) }
                        samples[base + offset] += Float(value) * 0.15
                    }
                }
            }
        }
        return samples
    }

    static func writeWAV(_ mono: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(mono.count))!
        buffer.frameLength = AVAudioFrameCount(mono.count)
        for channel in 0..<2 {
            mono.withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: mono.count)
            }
        }
        try file.write(from: buffer)
    }
}

final class BPMDetectorTests: XCTestCase {
    func testFindsTheTempoOfASteadyBeat() throws {
        for bpm in [100.0, 118, 122, 124, 127.5, 128, 133, 140] {
            let samples = Synth.beat(bpm: bpm, seconds: 60, sampleRate: 11025)
            let estimate = try XCTUnwrap(BPMDetector.estimate(samples: samples, sampleRate: 11025), "no estimate at \(bpm)")
            XCTAssertEqual(estimate.bpm, bpm, accuracy: 0.15, "expected \(bpm), got \(estimate.bpm)")
        }
    }

    func testWorksAtTheDecimatedRateOf48kFiles() throws {
        let samples = Synth.beat(bpm: 126, seconds: 60, sampleRate: 12000)
        let estimate = try XCTUnwrap(BPMDetector.estimate(samples: samples, sampleRate: 12000))
        XCTAssertEqual(estimate.bpm, 126, accuracy: 0.15)
    }

    func testGivesNoAnswerForSilenceOrTooLittleAudio() {
        XCTAssertNil(BPMDetector.estimate(samples: [Float](repeating: 0, count: 11025 * 60), sampleRate: 11025))
        XCTAssertNil(BPMDetector.estimate(samples: Synth.beat(bpm: 120, seconds: 5, sampleRate: 11025), sampleRate: 11025))
    }
}

final class KeyDetectorTests: XCTestCase {
    private func key(_ progression: [[Int]]) -> String? {
        let samples = Synth.chords(progression, chordSeconds: 2, repeats: 3, sampleRate: 11025)
        return KeyDetector.estimate(samples: samples, sampleRate: 11025)?.key.description
    }

    func testMajorKeys() {
        // I - IV - V - I in C major, then the same shape up a fifth (G) and in E♭.
        XCTAssertEqual(key([[48, 52, 55], [53, 57, 60], [55, 59, 62], [48, 52, 55]]), "8B")
        XCTAssertEqual(key([[55, 59, 62], [60, 64, 67], [62, 66, 69], [55, 59, 62]]), "9B")
        XCTAssertEqual(key([[51, 55, 58], [56, 60, 63], [58, 62, 65], [51, 55, 58]]), "5B")
    }

    func testMinorKeys() {
        // i - iv - v - i in A minor and F♯ minor.
        XCTAssertEqual(key([[57, 60, 64], [50, 53, 57], [52, 55, 59], [57, 60, 64]]), "8A")
        XCTAssertEqual(key([[54, 57, 61], [59, 62, 66], [49, 52, 56], [54, 57, 61]]), "11A")
    }

    func testARecordingThatIsSlightlyOffConcertPitchKeepsItsKey() {
        let progression = [[57, 60, 64], [50, 53, 57], [52, 55, 59], [57, 60, 64]]  // A minor
        for cents in [-25.0, 20, 28] {
            let samples = Synth.chords(progression, chordSeconds: 2, repeats: 3, sampleRate: 11025, detuneCents: cents)
            XCTAssertEqual(
                KeyDetector.estimate(samples: samples, sampleRate: 11025)?.key.description, "8A", "detuned \(Int(cents)) cents")
        }
    }

    func testGivesNoAnswerForSilence() {
        XCTAssertNil(KeyDetector.estimate(samples: [Float](repeating: 0, count: 11025 * 10), sampleRate: 11025))
    }
}

final class WaveDetailTests: XCTestCase {
    private func detail(of hertz: Double, amplitude: Float = 0.5, seconds: Double = 2, rate: Double = 44100) -> WaveDetail {
        var splitter = BandSplitter(sampleRate: rate)
        for frame in 0..<Int(seconds * rate) {
            splitter.add(amplitude * Float(sin(2 * Double.pi * hertz * Double(frame) / rate)))
        }
        return splitter.finish()
    }

    func testEachToneLandsInItsOwnBand() {
        // Skip the first columns while the filters settle.
        let bass = detail(of: 60).peak(in: 10..<100)
        XCTAssertGreaterThan(bass.low, bass.mid * 2)
        XCTAssertGreaterThan(bass.low, bass.high * 4)

        let voice = detail(of: 700).peak(in: 10..<100)
        XCTAssertGreaterThan(voice.mid, voice.low * 2)
        XCTAssertGreaterThan(voice.mid, voice.high * 1.5)

        let hat = detail(of: 9000).peak(in: 10..<100)
        XCTAssertGreaterThan(hat.high, hat.mid * 2)
        XCTAssertGreaterThan(hat.high, hat.low * 10)
    }

    func testColumnsFollowTimeAtAnySampleRate() {
        for rate in [22050.0, 44100, 48000, 96000] {
            let wave = detail(of: 440, seconds: 3, rate: rate)
            XCTAssertEqual(wave.count, 150, "at \(rate) Hz")
            XCTAssertEqual(wave.duration, 3, accuracy: 0.02)
        }
    }

    func testLevelsAreSquareRootEncodedAndSafeOutsideTheTrack() {
        // A full-scale tone in the mids stores close to 255; a quarter-amplitude one close to half that.
        XCTAssertEqual(detail(of: 700, amplitude: 1).peak(in: 10..<100).mid, 1, accuracy: 0.1)
        XCTAssertEqual(detail(of: 700, amplitude: 0.25).peak(in: 10..<100).mid, 0.5, accuracy: 0.06)

        let wave = WaveDetail(columnsPerSecond: 50, bytes: [10, 20, 30, 40, 50, 60, 99])
        XCTAssertEqual(wave.count, 2, "a trailing partial column is dropped")
        XCTAssertEqual(wave.level(.high, at: 1), 60.0 / 255)
        XCTAssertEqual(wave.level(.low, at: -1), 0)
        XCTAssertEqual(wave.level(.low, at: 2), 0)
        XCTAssertEqual(wave.peak(in: -5..<50).mid, 50.0 / 255)
        XCTAssertEqual(wave.mean(in: 0..<2).mid, 35.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(wave.mean(in: 5..<9).low, 0, "an empty stretch is silent, not a crash")
        XCTAssertEqual(WaveDetail(columnsPerSecond: 50, data: wave.data), wave)
    }
}

final class TagTests: XCTestCase {
    private func flac(comments: [String], leadingID3: Bool = false) -> Data {
        func le32(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]) }
        func be24(_ value: Int) -> Data { Data([UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        var block = Data()
        let vendor = Data("test".utf8)
        block += le32(vendor.count) + vendor + le32(comments.count)
        for comment in comments {
            let bytes = Data(comment.utf8)
            block += le32(bytes.count) + bytes
        }
        var data = Data()
        if leadingID3 { data += Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 5]) + Data(repeating: 0, count: 5) }
        data += Data("fLaC".utf8)
        data += Data([0x00]) + be24(34) + Data(repeating: 0, count: 34)       // STREAMINFO
        data += Data([0x06]) + be24(3000) + Data(repeating: 7, count: 3000)   // a picture to skip over
        data += Data([0x84]) + be24(block.count) + block                      // VORBIS_COMMENT, last block
        return data
    }

    private func read(_ data: Data) throws -> AudioTags? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return FLACTags.read(path: url.path)
    }

    func testReadsVorbisCommentsFromFLAC() throws {
        let tags = try read(flac(comments: [
            "TITLE=Paradise", "artist=Change", "ALBUM=The Glow of Love", "BPM=118,5", "INITIALKEY=Am", "COMMENT=x",
        ]))
        XCTAssertEqual(tags, AudioTags(title: "Paradise", artist: "Change", album: "The Glow of Love", bpm: 118.5, key: "Am"))
    }

    func testJoinsMultipleArtistsAndSkipsALeadingID3Tag() throws {
        let tags = try read(flac(comments: ["ARTIST=Grace Jones", "ARTIST=Sly & Robbie", "BPM=fast"], leadingID3: true))
        XCTAssertEqual(tags?.artist, "Grace Jones, Sly & Robbie")
        XCTAssertNil(tags?.bpm)
    }

    func testRejectsFilesThatAreNotFLACAndSurvivesTruncation() throws {
        XCTAssertNil(try read(Data("RIFFxxxxWAVE".utf8)))
        let whole = flac(comments: ["TITLE=Paradise"])
        XCTAssertNil(try read(whole.prefix(whole.count - 10)))
    }
}

final class ScanAndAnalyzeTests: XCTestCase {
    private var folder: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("crate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Test Artist"), withIntermediateDirectories: true)
        store = try LibraryStore(path: ":memory:")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testScanKeepsFullTracksSkipsSamplesAndAnalysisFindsTempoAndWaveform() async throws {
        let track = folder.appendingPathComponent("Test Artist/Test Artist - Click 124.wav")
        try Synth.writeWAV(Synth.beat(bpm: 124, seconds: 70, sampleRate: 44100), sampleRate: 44100, to: track)
        try Synth.writeWAV(
            Synth.beat(bpm: 124, seconds: 6, sampleRate: 44100), sampleRate: 44100,
            to: folder.appendingPathComponent("one shot loop.wav"))
        try Data(repeating: 0, count: 600_000).write(to: folder.appendingPathComponent("._Test Artist - Click 124.wav"))
        try Data(repeating: 0, count: 600_000).write(to: folder.appendingPathComponent("broken.mp3"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let scanner = LibraryScanner(store: store)
        let summary = try await scanner.scan(folder: folder.path)
        XCTAssertEqual(summary, .init(found: 3, added: 1, updated: 0, unchanged: 0, tooShort: 1, unreadable: 1))

        let tracks = try store.tracks()
        XCTAssertEqual(tracks.map(\.title), ["Click 124"])
        XCTAssertEqual(tracks[0].artist, "Test Artist")
        XCTAssertEqual(tracks[0].duration, 70, accuracy: 0.1)
        XCTAssertEqual(tracks[0].format, "wav")
        XCTAssertEqual(try store.folders().count, 1)

        // Nothing changed on disk: a second scan does no work.
        let again = try await scanner.scan(folder: folder.path)
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertEqual(again.added, 0)

        let result = try XCTUnwrap(AudioAnalyzer.analyze(track: tracks[0], store: store))
        XCTAssertEqual(try XCTUnwrap(result.bpm).bpm, 124, accuracy: 0.2)
        let stored = try XCTUnwrap(store.track(id: tracks[0].id))
        XCTAssertEqual(try XCTUnwrap(stored.bpm), 124, accuracy: 0.2)
        XCTAssertEqual(stored.bpmSource, .estimated)
        XCTAssertTrue(stored.analyzed)

        let waveform = try XCTUnwrap(store.waveform(id: stored.id))
        XCTAssertEqual(waveform.count, AudioAnalyzer.waveformBins)
        XCTAssertGreaterThan(waveform.max() ?? 0, 100, "kicks at 0.8 amplitude should show as tall peaks")
        XCTAssertTrue(try store.unanalyzedLocalTracks().isEmpty)

        // The detailed waveform covers the whole track at 50 columns a second.
        let detail = try XCTUnwrap(store.waveDetail(id: stored.id))
        XCTAssertEqual(detail.columnsPerSecond, 50)
        XCTAssertEqual(detail.duration, 70, accuracy: 0.1)
        XCTAssertGreaterThan(detail.peak(in: 0..<detail.count).low, 0.5, "the kicks are bass")
    }

    func testScanningAMissingFolderExplainsItself() async {
        let scanner = LibraryScanner(store: store)
        do {
            _ = try await scanner.scan(folder: "/Volumes/NotConnected/Music")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("external drive"))
        }
    }

    func testATrackWhoseFileIsGoneIsReportedAsUnreachable() throws {
        let id = try store.upsertLocal(ScannedFile(path: "/nowhere/gone.wav", title: "gone", duration: 300, format: "wav"))
        let track = try XCTUnwrap(store.track(id: id))
        XCTAssertNil(Volumes.resolvedPath(for: track))
        XCTAssertNil(try AudioAnalyzer.analyze(track: track, store: store))
    }
}
