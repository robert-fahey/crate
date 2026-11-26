import Foundation

/// How a looping deck's track is laid along its scrolling wave.
///
/// A loop makes the deck's position drop back by the loop's length each time round. Drawn as it
/// stands, the wave would leap back with it. Instead the wave is drawn unrolled: every pass of the
/// loop laid end to end, as on a tape of what is heard, so that it scrolls on without a break.
/// Behind the playhead are the passes already played and, before the first of them, the track that
/// led into the loop. Ahead of it are the passes still to come.
///
/// A *place* is a moment along that tape, in seconds. In the pass being played a place is the
/// track's own time; a pass later it is a loop's length more.
public enum WaveUnroll {
    /// A stretch of the track and where it lies along the wave.
    public struct Segment: Equatable, Sendable {
        /// The stretch of the track, in seconds: from `from` up to, not including, `to`.
        public var from: Double
        public var to: Double
        /// Added to a time in the track to give its place.
        public var shift: Double
        /// One pass of the loop, rather than the track outside it.
        public var isPass: Bool

        public init(from: Double, to: Double, shift: Double = 0, isPass: Bool = false) {
            self.from = from
            self.to = to
            self.shift = shift
            self.isPass = isPass
        }
    }

    /// The most passes laid out. A loop so short that more would fit is drawn as the track stands:
    /// its passes would be too narrow to see.
    public static let mostPasses = 1500

    private static func length(of loop: ClosedRange<Double>?, within reach: Double) -> Double? {
        guard let loop else { return nil }
        let length = loop.upperBound - loop.lowerBound
        guard length > 0.001, 2 * reach / length <= Double(mostPasses) else { return nil }
        return length
    }

    /// What lies within `reach` seconds either side of `position`, from left to right.
    ///
    /// - Parameters:
    ///   - position: the deck's position in the track, which is its place too.
    ///   - loop: the loop the deck is in, if any.
    ///   - pass: how many times the deck has been round it (`DeckState.loopPass`).
    public static func segments(around position: Double, reach: Double, loop: ClosedRange<Double>?, pass: Int) -> [Segment] {
        let low = position - reach, high = position + reach
        guard let loop, let length = length(of: loop, within: reach) else { return [Segment(from: low, to: high)] }
        let start = loop.lowerBound, end = loop.upperBound

        var segments: [Segment] = []
        // Passes are numbered from the one being played: 0, with 1 the next and -1 the one before.
        var number = Int(((low - start) / length).rounded(.down))
        if pass >= 0, number < -pass {
            // Before the first pass comes the track that led into the loop.
            let shift = -Double(pass) * length
            segments.append(Segment(from: low - shift, to: min(start, high - shift), shift: shift))
            number = -pass
        }
        while start + Double(number) * length < high {
            let shift = Double(number) * length
            segments.append(Segment(from: max(start, low - shift), to: min(end, high - shift), shift: shift, isPass: true))
            number += 1
        }
        return segments
    }

    /// The time in the track that is drawn at a place.
    public static func time(at place: Double, reach: Double, loop: ClosedRange<Double>?, pass: Int) -> Double {
        guard let loop, let length = length(of: loop, within: reach) else { return place }
        let start = loop.lowerBound
        if pass >= 0, place < start - Double(pass) * length { return place + Double(pass) * length }
        let into = (place - start).truncatingRemainder(dividingBy: length)
        return start + (into < 0 ? into + length : into)
    }
}
