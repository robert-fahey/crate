import AVFoundation
import XCTest
@testable import CrateCore

/// Not a pass/fail test: measures the beat tracker on a real library.
/// Run with CRATE_EVAL_DB=/path/to/library.sqlite swift test --filter RealTrackEvaluation
final class RealTrackEvaluation: XCTestCase {
    func testBeatGridsOnRealTracks() throws {
        guard let path = ProcessInfo.processInfo.environment["CRATE_EVAL_DB"] else { throw XCTSkip("set CRATE_EVAL_DB to run") }
        let store = try LibraryStore(path: path)
        var query = TrackQuery()
        query.source = .local
        let limit = Int(ProcessInfo.processInfo.environment["CRATE_EVAL_LIMIT"] ?? "") ?? 100
        for track in try store.tracks(query).prefix(limit) {
            guard let file = Volumes.resolvedPath(for: track), let bpm = track.bpm else { continue }
            let started = Date()
            let audio = try AudioAnalyzer.decode(path: file)
            guard let grid = BeatTracker.track(samples: audio.samples, sampleRate: audio.sampleRate, bpm: bpm) else {
                print("EVAL \(track.title): no grid")
                continue
            }
            // How well the finished grid sits on the drums: for beats that have a clear attack nearby, how far off it is.
            let attacks = BeatTracker.attackTimes(near: grid.beats, samples: audio.samples, sampleRate: audio.sampleRate)
            let misses = zip(grid.beats, attacks).filter { $1.strength > 0.5 }.map { abs($1.time - $0) }.sorted()
            let within5 = Double(misses.filter { $0 <= 0.005 }.count) / Double(max(1, misses.count))
            let within10 = Double(misses.filter { $0 <= 0.010 }.count) / Double(max(1, misses.count))
            let median = misses.isEmpty ? 0 : misses[misses.count / 2]
            let early = grid.bpm(at: audio.duration * 0.15), late = grid.bpm(at: audio.duration * 0.85)
            print(String(
                format: "EVAL %@ | tag %.1f%@ grid %.2f %@ %d markers | start %.1f end %.1f | drums on %d of %d beats | median miss %.1f ms, within 5 ms %.0f%%, 10 ms %.0f%% | %.1fs",
                String(track.title.prefix(28)).padding(toLength: 28, withPad: " ", startingAt: 0), bpm,
                track.bpmSource == .tag ? "" : "~", grid.bpm, grid.isSteady ? "steady" : "follows", grid.markers.count, early, late,
                misses.count, grid.count, median * 1000, within5 * 100, within10 * 100, Date().timeIntervalSince(started)))
        }
    }
}

/// Not a pass/fail test: where the bar finder puts beat 1 on a real library, against the grids stored there.
/// Run with CRATE_EVAL_DB=/path/to/library.sqlite swift test --filter RealBarEvaluation
final class RealBarEvaluation: XCTestCase {
    func testBarStartsOnRealTracks() throws {
        guard let path = ProcessInfo.processInfo.environment["CRATE_EVAL_DB"] else { throw XCTSkip("set CRATE_EVAL_DB to run") }
        let store = try LibraryStore(path: path)
        var query = TrackQuery()
        query.source = .local
        let limit = Int(ProcessInfo.processInfo.environment["CRATE_EVAL_LIMIT"] ?? "") ?? 1000
        for track in try store.tracks(query).prefix(limit) {
            guard let grid = try store.beatGrid(id: track.id) else { continue }
            // CRATE_EVAL_AUDIO is a folder of tracks already decoded to 11025 Hz mono, 16 bits, as NumPy files named by track id.
            let audio: (samples: [Float], sampleRate: Double)
            if let folder = ProcessInfo.processInfo.environment["CRATE_EVAL_AUDIO"] {
                guard let data = FileManager.default.contents(atPath: "\(folder)/\(track.id).npy"), data.count > 12 else { continue }
                let header = 10 + Int(data[8]) + Int(data[9]) << 8
                let samples = data.withUnsafeBytes { bytes in
                    stride(from: header, to: data.count - 1, by: 2).map { Float(bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self)) / 32768 }
                }
                audio = (samples, 11025)
            } else {
                guard let file = Volumes.resolvedPath(for: track) else { continue }
                let decoded = try AudioAnalyzer.decode(path: file)
                audio = (decoded.samples, decoded.sampleRate)
            }
            let measures = BarFinder.measures(beats: grid.beats, samples: audio.samples, sampleRate: audio.sampleRate)
            let boundaries = BarFinder.boundaries(measures)
            let start = BarFinder.firstLoudBeat(measures)
            let scores = BarFinder.scores(measures, boundaries: boundaries, start: start)
            let found = BarFinder.find(grid: grid, samples: audio.samples, sampleRate: audio.sampleRate)
            print(String(
                format: "BARS %d | new %d phrase %d | stored %d | backbeat %+.3f | start %d | boundaries %d | scores %@ | %@",
                track.id, found.downbeat, found.phrase, grid.downbeat % 4, BarFinder.backbeat(measures, from: grid.downbeat % 4), start ?? -1,
                boundaries.count, scores.map { String(format: "%.2f", $0) }.joined(separator: " "), String(track.title.prefix(30))))
        }
    }
}

/// Renders a synced blend of two real tracks to a WAV file and measures how well their drums line up.
/// CRATE_EVAL_DB=… CRATE_EVAL_MIX=/path/out.wav CRATE_EVAL_A="title" CRATE_EVAL_B="title" swift test --filter RealMixEvaluation
final class RealMixEvaluation: XCTestCase {
    private func write(_ audio: StereoAudio, to path: String) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 2)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frames))!
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        audio.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.frames) }
        audio.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: audio.frames) }
        try file.write(from: buffer)
    }

    /// The sharpness-of-attack level of a signal at about 11 kHz, as the beat tracker measures it.
    private func attackLevel(_ samples: [Float]) -> [Float] {
        var mono = [Float](repeating: 0, count: samples.count / 4)
        for index in mono.indices {
            let base = index * 4
            mono[index] = (samples[base] + samples[base + 1] + samples[base + 2] + samples[base + 3]) / 4
        }
        var level = [Float](repeating: 0, count: mono.count)
        var running: Float = 0
        for index in 1..<mono.count {
            let change: Float = abs(mono[index] - mono[index - 1])
            running += (change - running) * 0.06
            level[index] = running
        }
        // Keep only the rises: where attacks are.
        var rises = [Float](repeating: 0, count: level.count)
        for index in 33..<level.count { rises[index] = max(0, level[index] - level[index - 33]) }
        return rises
    }

    func testRenderASyncedBlend() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CRATE_EVAL_DB"], let output = environment["CRATE_EVAL_MIX"] else { throw XCTSkip("set CRATE_EVAL_DB and CRATE_EVAL_MIX") }
        let store = try LibraryStore(path: path)
        func find(_ key: String, _ fallback: String) throws -> Track {
            let wanted = environment[key] ?? fallback
            return try XCTUnwrap(try store.tracks(TrackQuery()).first { $0.title.localizedCaseInsensitiveContains(wanted) }, "no track matching \(wanted)")
        }
        let trackA = try find("CRATE_EVAL_A", "I Got My Mind Made Up (12"), trackB = try find("CRATE_EVAL_B", "Dancer")
        func prepare(_ track: Track) throws -> (TrackAudio, BeatGrid) {
            let file = try XCTUnwrap(Volumes.resolvedPath(for: track))
            let decoded = try AudioAnalyzer.decode(path: file)
            let grid = try XCTUnwrap(BeatTracker.track(samples: decoded.samples, sampleRate: decoded.sampleRate, bpm: try XCTUnwrap(track.bpm)))
            return (try TrackAudio.load(path: file), grid)
        }
        let (audioA, gridA) = try prepare(trackA), (audioB, gridB) = try prepare(trackB)

        /// The same performance each time; `solo` mutes the other deck without changing any timing.
        func perform(solo: DeckID?) throws -> (audio: StereoAudio, errors: [Double]) {
            let engine = try DeckEngine(offline: true)
            let sync = DeckSync(engine: engine)
            let a = engine.deck(.a), b = engine.deck(.b)
            a.load(audioA)
            b.load(audioB)
            sync.setGrid(gridA, for: .a)
            sync.setGrid(gridB, for: .b)
            var settings = engine.settings
            settings.trim = [solo == .b ? 0 : 0.8, solo == .a ? 0 : 0.8]
            engine.settings = settings
            _ = try engine.render(seconds: 0.05)
            // A from the first bar after a minute in; B from the first phrase after 30 seconds, bass out.
            a.seek(to: gridA.time(atBeat: gridA.boundary(atOrAfter: 60, every: 4, anchoredAt: gridA.downbeat)))
            b.seek(to: gridB.time(atBeat: gridB.boundary(atOrAfter: 30, every: 32, anchoredAt: gridB.phrase)))
            b.set(.eqLow, to: 0)
            a.play()
            var result = try engine.render(seconds: 8)
            var errors: [Double] = []
            func run(_ seconds: Double) throws {
                for _ in 0..<Int(seconds * 10) {
                    let slice = try engine.render(seconds: 0.1)
                    result.left += slice.left
                    result.right += slice.right
                    if let error = sync.phaseError(for: .b), let beat = sync.beat(for: .a) { errors.append(error * 60 / beat.bpm * 1000) }
                }
            }
            sync.setSync(true, for: .b)
            sync.play(.b)
            try run(16)
            a.set(.eqLow, to: 0, over: 0.05)   // bass swap
            b.set(.eqLow, to: 1, over: 0.05)
            try run(16)
            settings.fader[0] = 0
            a.set(.gain, to: 0, over: 4)
            try run(4)
            a.pause()
            try run(10)
            return (result, errors)
        }

        let mix = try perform(solo: nil)
        try write(mix.audio, to: output)
        let soloA = try perform(solo: .a).audio, soloB = try perform(solo: .b).audio
        // Slide B's attacks against A's over the blend (10 s to 38 s) and find where they line up best.
        let from = 10 * 11025, to = 38 * 11025
        let levelA = attackLevel(soloA.left), levelB = attackLevel(soloB.left)
        var best = 0, bestScore: Float = -1
        var scores: [Int: Float] = [:]
        for lag in -660...660 {
            var score: Float = 0
            for index in stride(from: from, to: to, by: 2) { score += levelA[index] * levelB[index + lag] }
            scores[lag] = score
            if score > bestScore { bestScore = score; best = lag }
        }
        let sorted = mix.errors.map(abs).sorted()
        print(String(
            format: "MIX %@ (%.2f BPM) into %@ (%.2f BPM) → %@ | grids held within %.1f ms (median %.1f) | drum attacks line up best at %+.1f ms (B after A), %.0f%% stronger than half a beat away | peak %.2f",
            trackA.title, gridA.bpm, trackB.title, gridB.bpm, output, sorted.last ?? 0, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
            Double(best) / 11.025, (bestScore / max(1e-9, scores[-660] ?? 1) - 1) * 100,
            max(mix.audio.left.map(abs).max() ?? 0, mix.audio.right.map(abs).max() ?? 0)))
    }
}

/// Decoded analysis audio, kept on disk between runs so that trying a change on a whole library takes seconds.
enum EvaluationCache {
    static func samples(for track: Track, in directory: String) throws -> (samples: [Float], sampleRate: Double)? {
        let file = URL(fileURLWithPath: directory).appendingPathComponent("\(track.id).f32")
        if let data = try? Data(contentsOf: file), data.count > 8 {
            let rate = data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            var samples = [Float](repeating: 0, count: (data.count - 8) / 4)
            _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 8..<data.count) }
            return (samples, rate)
        }
        guard let path = Volumes.resolvedPath(for: track) else { return nil }
        let audio = try AudioAnalyzer.decode(path: path)
        var data = withUnsafeBytes(of: audio.sampleRate) { Data($0) }
        audio.samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: file)
        return (audio.samples, audio.sampleRate)
    }
}

/// Prints, for every track, the fixed-tempo grids its drums could fit.
/// CRATE_EVAL_DB=… CRATE_EVAL_CACHE=<dir> swift test --filter SteadyTempoEvaluation
final class SteadyTempoEvaluation: XCTestCase {
    func testSteadyTempoOnRealTracks() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CRATE_EVAL_DB"], let cache = environment["CRATE_EVAL_CACHE"] else { throw XCTSkip("set CRATE_EVAL_DB and CRATE_EVAL_CACHE") }
        let store = try LibraryStore(path: path)
        var query = TrackQuery()
        query.source = .local
        let only = environment["CRATE_EVAL_ONLY"].map { Set($0.split(separator: ",").compactMap { Int64($0) }) }
        let tracks = try store.tracks(query).filter { $0.duration < 1200 && (only?.contains($0.id) ?? true) }.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        let lines = NSLock()
        var output = [String](repeating: "", count: tracks.count)
        DispatchQueue.concurrentPerform(iterations: tracks.count) { index in
            let track = tracks[index]
            guard let bpm = track.bpm, let audio = try? EvaluationCache.samples(for: track, in: cache) else { return }
            let started = Date()
            let found = SteadyTempo.candidates(samples: audio.samples, sampleRate: audio.sampleRate, bpm: bpm)
            let stored = try? store.beatGrid(id: track.id)
            let chosen = SteadyTempo.grid(samples: audio.samples, sampleRate: audio.sampleRate, bpm: bpm)
            var verdict = "follow"
            if chosen == nil, let grid = BeatTracker.follow(samples: audio.samples, sampleRate: audio.sampleRate, bpm: bpm) {
                let bass = SteadyTempo.bassLevel(samples: audio.samples, sampleRate: audio.sampleRate)
                let between = zip(grid.beats, grid.beats.dropFirst()).map { ($0 + $1) / 2 }
                let old = stored?.beats ?? []
                let agreeing = old.filter { abs(grid.nearestBeat(to: $0) - $0) < 0.02 }.count
                verdict = String(
                    format: "follow %.2f, %d markers, bass on beats %.2f between %.2f, old grid agrees %.0f%%", grid.bpm, grid.markers.count,
                    SteadyTempo.bassRise(bass, sampleRate: audio.sampleRate, at: grid.beats), SteadyTempo.bassRise(bass, sampleRate: audio.sampleRate, at: between),
                    Double(agreeing) / Double(max(1, old.count)) * 100)
            }
            if let chosen {
                // How much of the old grid agrees with the new one, to within 20 ms.
                let old = stored?.beats ?? []
                let agreeing = old.filter { abs(chosen.grid.nearestBeat(to: $0) - $0) < 0.02 }.count
                let straight = chosen.grid.beats.enumerated().map { abs($1 - (chosen.grid.beats[0] + Double($0) * (chosen.grid.beats[chosen.grid.count - 1] - chosen.grid.beats[0]) / Double(chosen.grid.count - 1))) }.max() ?? 0
                verdict = String(format: "%@ %.3f first beat %.0f ms, %d markers, wanders %.1f ms, old grid agrees %.0f%%", chosen.kind.rawValue, chosen.grid.bpm, chosen.grid.beats[0] * 1000, chosen.grid.markers.count, straight * 1000, Double(agreeing) / Double(max(1, old.count)) * 100)
            }
            var text = String(format: "STEADY %3d %@ | given %.2f | %.1fs | %@", track.id, String(track.title.prefix(26)).padding(toLength: 26, withPad: " ", startingAt: 0), bpm, Date().timeIntervalSince(started), verdict)
            for candidate in found {
                // Where the stored grid's beats sit against this candidate, as a share of a beat.
                var onIt = 0.0
                if let stored {
                    let near = stored.beats.filter { beat in
                        let offset = (beat - candidate.anchor) / candidate.period
                        return abs(offset - offset.rounded()) * candidate.period < 0.02
                    }
                    onIt = Double(near.count) / Double(max(1, stored.count))
                }
                text += String(
                    format: "\n        %@ %.3f BPM at %5.0f ms | weight %.2f bass %.2f | covered %.2f tight %.2f spread %.1f ms | old grid on it %.0f%%",
                    candidate.isSteady ? "STEADY" : "  no  ", candidate.bpm, candidate.anchor * 1000, candidate.weight, candidate.bass, candidate.covered,
                    candidate.tight, candidate.spread * 1000, onIt * 100)
            }
            lines.withLock { output[index] = text }
        }
        print(output.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

/// Renders synced blends of pairs of real tracks, once with the grids stored in the library and once with
/// grids from the beat tracker as it is now, and measures how far apart the two tracks' drums land.
/// CRATE_EVAL_DB=… CRATE_EVAL_CACHE=<dir> CRATE_EVAL_PAIRS=115:66,80:51 swift test -c release --filter RealPairEvaluation
final class RealPairEvaluation: XCTestCase {
    /// Kick drums, at about 11 kHz: sharp attacks with the bass rising under them. Lining up two tracks'
    /// loudest attacks instead would match one track's off-beat hats to the other's kicks.
    private func attacks(_ samples: [Float]) -> [Float] {
        var mono = [Float](repeating: 0, count: samples.count / 4)
        for index in mono.indices {
            let base = index * 4
            mono[index] = (samples[base] + samples[base + 1] + samples[base + 2] + samples[base + 3]) / 4
        }
        let bass = SteadyTempo.bassLevel(samples: mono, sampleRate: 11025)
        let level = BeatTracker.attackLevel(samples: mono, sampleRate: 11025)
        var kicks = [Float](repeating: 0, count: level.count)
        for index in 33..<(level.count - 441) {
            kicks[index] = max(0, level[index] - level[index - 33]) * max(0, bass[index + 440] - bass[index])
        }
        return kicks
    }

    private func perform(_ audioA: TrackAudio, _ gridA: BeatGrid, _ audioB: TrackAudio, _ gridB: BeatGrid, solo: DeckID) throws -> StereoAudio {
        let engine = try DeckEngine(offline: true)
        let sync = DeckSync(engine: engine)
        let a = engine.deck(.a), b = engine.deck(.b)
        a.load(audioA)
        b.load(audioB)
        sync.setGrid(gridA, for: .a)
        sync.setGrid(gridB, for: .b)
        var settings = engine.settings
        settings.trim = [solo == .b ? 0 : 0.8, solo == .a ? 0 : 0.8]
        engine.settings = settings
        _ = try engine.render(seconds: 0.05)
        a.seek(to: gridA.time(atBeat: gridA.boundary(atOrAfter: 60, every: 4, anchoredAt: gridA.downbeat)))
        b.seek(to: gridB.time(atBeat: gridB.boundary(atOrAfter: 60, every: 4, anchoredAt: gridB.downbeat)))
        a.play()
        var result = try engine.render(seconds: 4)
        sync.setSync(true, for: .b)
        sync.play(.b)
        for _ in 0..<600 {
            let slice = try engine.render(seconds: 0.1)
            result.left += slice.left
            result.right += slice.right
        }
        return result
    }

    func testSyncedPairs() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CRATE_EVAL_DB"], let cache = environment["CRATE_EVAL_CACHE"], let wanted = environment["CRATE_EVAL_PAIRS"]
        else { throw XCTSkip("set CRATE_EVAL_DB, CRATE_EVAL_CACHE and CRATE_EVAL_PAIRS") }
        let store = try LibraryStore(path: path)
        let pairs = wanted.split(separator: ",").map { $0.split(separator: ":").compactMap { Int64($0) } }.filter { $0.count == 2 }
        let lines = NSLock()
        var output = [String](repeating: "", count: pairs.count)
        DispatchQueue.concurrentPerform(iterations: pairs.count) { index in
            do {
                let tracks = try pairs[index].map { try XCTUnwrap(try store.track(id: $0)) }
                let audio = try tracks.map { try TrackAudio.load(path: try XCTUnwrap(Volumes.resolvedPath(for: $0))) }
                let old = try tracks.map { try XCTUnwrap(try store.beatGrid(id: $0.id)) }
                let new = try tracks.map { track -> BeatGrid in
                    let decoded = try XCTUnwrap(try EvaluationCache.samples(for: track, in: cache))
                    return try XCTUnwrap(BeatTracker.track(samples: decoded.samples, sampleRate: decoded.sampleRate, bpm: try XCTUnwrap(track.bpm)))
                }
                var text = "PAIR \(tracks[0].title.prefix(28)) (\(String(format: "%.2f", new[0].bpm))) + \(tracks[1].title.prefix(28)) (\(String(format: "%.2f", new[1].bpm)))"
                for (label, grids) in [("old grids", old), ("new grids", new)] {
                    let soloA = attacks(try perform(audio[0], grids[0], audio[1], grids[1], solo: .a).left)
                    let soloB = attacks(try perform(audio[0], grids[0], audio[1], grids[1], solo: .b).left)
                    // Every four seconds of the minute they play together: where B's attacks best line up with A's,
                    // searched across a whole beat, so a deck half a beat out shows as about 230 ms.
                    let reach = Int(60 / grids[0].bpm / 2 * 11025)
                    var lags: [Double] = []
                    for window in 0..<14 {
                        let from = (6 + window * 4) * 11025, to = from + 4 * 11025
                        guard to + reach < min(soloA.count, soloB.count) else { break }
                        var best = 0, bestScore: Float = -1, total: Float = 0
                        for lag in stride(from: -reach, through: reach, by: 2) {
                            var score: Float = 0
                            for position in stride(from: from, to: to, by: 2) { score += soloA[position] * soloB[position + lag] }
                            total += score
                            if score > bestScore { bestScore = score; best = lag }
                        }
                        // Only where both decks have drums: a clear best place, well above the average.
                        if bestScore > total / Float(reach) * 3 { lags.append(Double(best) / 11.025) }
                    }
                    let sorted = lags.map(abs).sorted()
                    text += String(
                        format: "\n     %@: drums apart by median %.0f ms, worst %.0f ms over %d stretches | %@", label,
                        sorted.isEmpty ? -1 : sorted[sorted.count / 2], sorted.last ?? -1, sorted.count,
                        lags.map { String(format: "%+.0f", $0) }.joined(separator: " "))
                }
                lines.withLock { output[index] = text }
            } catch {
                lines.withLock { output[index] = "PAIR \(pairs[index]): \(error)" }
            }
        }
        print(output.joined(separator: "\n"))
    }
}

/// For each track, a map along its length of where the kick-like hits fall against the grid:
/// "0" on the beats, "5" half a beat away, "." no kicks, "?" unclear. One character per four bars.
/// CRATE_EVAL_DB=… CRATE_EVAL_CACHE=<dir> CRATE_EVAL_ONLY=1,2 swift test -c release --filter KickMapEvaluation
final class KickMapEvaluation: XCTestCase {
    func testKickMaps() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CRATE_EVAL_DB"], let cache = environment["CRATE_EVAL_CACHE"] else { throw XCTSkip("set CRATE_EVAL_DB and CRATE_EVAL_CACHE") }
        let store = try LibraryStore(path: path)
        var query = TrackQuery()
        query.source = .local
        let only = environment["CRATE_EVAL_ONLY"].map { Set($0.split(separator: ",").compactMap { Int64($0) }) }
        let tracks = try store.tracks(query).filter { $0.duration < 1200 && (only?.contains($0.id) ?? true) }.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        let lines = NSLock()
        var output = [String](repeating: "", count: tracks.count)
        DispatchQueue.concurrentPerform(iterations: tracks.count) { index in
            let track = tracks[index]
            guard let bpm = track.bpm, let audio = try? EvaluationCache.samples(for: track, in: cache),
                  let grid = BeatTracker.track(samples: audio.samples, sampleRate: audio.sampleRate, bpm: bpm)
            else { return }
            let rate = audio.sampleRate
            let bass = SteadyTempo.bassLevel(samples: audio.samples, sampleRate: rate)
            let level = BeatTracker.attackLevel(samples: audio.samples, sampleRate: rate)
            let lag = Int(0.003 * rate), ahead = Int(0.04 * rate)
            func kick(around time: Double) -> Float {
                let center = Int(time * rate), reach = Int(0.025 * rate)
                guard center - reach - lag >= 0, center + reach + ahead < level.count else { return 0 }
                var best: Float = 0
                for position in (center - reach)...(center + reach) {
                    best = max(best, max(0, level[position] - level[position - lag]) * max(0, bass[position + ahead] - bass[position]))
                }
                return best
            }
            var map = "", on = 0, off = 0
            var overall: Float = 0
            var stretches: [(Float, Float)] = []
            for start in stride(from: 0, to: grid.count - 1, by: 16) {
                var onBeat: Float = 0, between: Float = 0
                for beat in start..<min(grid.count - 1, start + 16) {
                    onBeat += kick(around: grid.beats[beat])
                    between += kick(around: (grid.beats[beat] + grid.beats[beat + 1]) / 2)
                }
                stretches.append((onBeat, between))
                overall = max(overall, onBeat, between)
            }
            for (onBeat, between) in stretches {
                if max(onBeat, between) < overall * 0.05 { map += "." }
                else if onBeat > between * 2 { map += "0"; on += 1 }
                else if between > onBeat * 2 { map += "5"; off += 1 }
                else { map += "?" }
            }
            let text = String(format: "KICKS %3d %@ %7.3f %@ | on %2d off %2d | %@", track.id, String(track.title.prefix(24)).padding(toLength: 24, withPad: " ", startingAt: 0), grid.bpm, grid.isSteady ? "fixed " : "moving", on, off, map)
            lines.withLock { output[index] = text }
        }
        print(output.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
