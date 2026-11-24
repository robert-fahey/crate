import Foundation

/// Works out cue points and loops worth having from a track's shape.
///
/// The cues are the places a DJ jumps to: where the track starts, where the bass comes in, each
/// breakdown and the drop after it, and where the outro begins. The loops are four bars at the
/// start and four at the outro, for holding a track in place while another is brought in or out.
/// Everything sits on a phrase line of the beat grid, so it is only as right as the grid is.
public enum CueSuggester {
    /// How many beats a suggested loop goes round.
    public static let loopBeats = 16.0
    /// Pads 1 to 6 are for cues in the order they come in the track; 7 and 8 are the two loops.
    public static let cueSlots = 6
    public static let introLoopSlot = 7, outroLoopSlot = 8

    public static func suggest(structure: TrackStructure, grid: BeatGrid) -> [CuePoint] {
        let phrases = structure.phrases
        guard let start = structure.mixIn else { return [] }

        // Each candidate with how much it matters: when there are more than fit, the least go.
        var found: [(phrase: TrackStructure.Phrase, name: String, rank: Int)] = [(start, "Start", 0)]
        let firstFull = phrases.first { $0.label == "full" }
        if let firstFull, firstFull.index != start.index { found.append((firstFull, "Bass in", 1)) }
        var breaks = 0
        if let firstFull {
            for index in phrases.indices where index > firstFull.index {
                let phrase = phrases[index], before = phrases[index - 1]
                if phrase.label == "breakdown", before.label != "breakdown" {
                    breaks += 1
                    found.append((phrase, breaks == 1 ? "Break" : "Break \(breaks)", breaks * 2))
                } else if phrase.label == "full", before.label == "breakdown" {
                    found.append((phrase, breaks <= 1 ? "Drop" : "Drop \(breaks)", breaks * 2 + 1))
                }
            }
        }
        let outro = phrases.first { $0.label == "outro, no bass" && $0.index > (firstFull?.index ?? -1) }
        let ending = outro ?? structure.mixOut
        if let ending, !found.contains(where: { $0.phrase.index == ending.index }) {
            found.append((ending, outro == nil ? "Mix out" : "Outro", 1))
        }

        let kept = found.sorted { ($0.rank, $0.phrase.index) < ($1.rank, $1.phrase.index) }.prefix(cueSlots)
            .sorted { $0.phrase.index < $1.phrase.index }
        var cues = kept.enumerated().map { CuePoint(slot: $0.offset + 1, position: $0.element.phrase.time, name: $0.element.name) }

        func loop(_ slot: Int, _ name: String, at phrase: TrackStructure.Phrase) -> CuePoint? {
            let end = grid.time(atBeat: phrase.startBeat + loopBeats)
            guard end <= structure.duration, end > phrase.time else { return nil }
            return CuePoint(slot: slot, position: phrase.time, name: name, loopEnd: end)
        }
        if let intro = loop(introLoopSlot, "Intro loop", at: start) { cues.append(intro) }
        if let ending, ending.index != start.index, let outroLoop = loop(outroLoopSlot, "Outro loop", at: ending) { cues.append(outroLoop) }
        return cues
    }

    /// Suggested cues laid over the ones a track already has: only pads that are empty are filled,
    /// and nothing is suggested where there is a cue within a beat already.
    public static func filling(_ existing: [CuePoint], with suggested: [CuePoint], beat: Double) -> [CuePoint] {
        var result = existing
        for cue in suggested {
            let taken = Set(result.map(\.slot))
            if result.contains(where: { abs($0.position - cue.position) < beat && $0.isLoop == cue.isLoop }) { continue }
            let slot = taken.contains(cue.slot) ? CuePoint.slots.first { !taken.contains($0) } : cue.slot
            guard let slot else { break }
            var placed = cue
            placed.slot = slot
            result.append(placed)
        }
        return result.sorted { $0.slot < $1.slot }
    }
}
