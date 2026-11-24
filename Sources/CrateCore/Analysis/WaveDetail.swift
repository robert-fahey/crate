import Foundation

/// The detailed waveform of one track: how loud the bass, mids and highs are
/// in each short slice of time. Drawn as the scrolling, coloured waveform.
///
/// Levels are stored one byte per band, as the square root of the peak
/// amplitude, so quiet high-frequency detail survives the eight bits.
public struct WaveDetail: Equatable, Sendable {
    public static let defaultColumnsPerSecond = 50.0
    /// Below this the "bass" band, above `highCutoff` the "highs".
    static let lowCutoff = 180.0
    static let highCutoff = 2200.0

    public enum Band: Int, CaseIterable, Sendable {
        case low, mid, high
    }

    public let columnsPerSecond: Double
    /// Three bytes per column: low, mid, high.
    public let bytes: [UInt8]

    public init(columnsPerSecond: Double, bytes: [UInt8]) {
        self.columnsPerSecond = columnsPerSecond > 0 ? columnsPerSecond : Self.defaultColumnsPerSecond
        self.bytes = Array(bytes.prefix(bytes.count - bytes.count % 3))
    }

    public init(columnsPerSecond: Double, data: Data) {
        self.init(columnsPerSecond: columnsPerSecond, bytes: [UInt8](data))
    }

    public var data: Data { Data(bytes) }
    public var count: Int { bytes.count / 3 }
    public var duration: Double { Double(count) / columnsPerSecond }

    /// Level of one band in one column, 0...1 (square root of amplitude). Zero outside the track.
    @inlinable
    public func level(_ band: Band, at column: Int) -> Float {
        guard column >= 0, column < bytes.count / 3 else { return 0 }
        return Float(bytes[column * 3 + band.rawValue]) / 255
    }

    /// The loudest level of each band across `columns`, 0...1.
    public func peak(in columns: Range<Int>) -> (low: Float, mid: Float, high: Float) {
        let range = columns.clamped(to: 0..<count)
        var low: UInt8 = 0, mid: UInt8 = 0, high: UInt8 = 0
        var index = range.lowerBound * 3
        for _ in range {
            low = max(low, bytes[index])
            mid = max(mid, bytes[index + 1])
            high = max(high, bytes[index + 2])
            index += 3
        }
        return (Float(low) / 255, Float(mid) / 255, Float(high) / 255)
    }

    /// The average level of each band across `columns`, 0...1. Shows the shape of
    /// a long stretch better than its peak, which is nearly always a loud drum hit.
    public func mean(in columns: Range<Int>) -> (low: Float, mid: Float, high: Float) {
        let range = columns.clamped(to: 0..<count)
        guard !range.isEmpty else { return (0, 0, 0) }
        var low = 0, mid = 0, high = 0
        var index = range.lowerBound * 3
        for _ in range {
            low += Int(bytes[index])
            mid += Int(bytes[index + 1])
            high += Int(bytes[index + 2])
            index += 3
        }
        let scale = 1 / (255 * Float(range.count))
        return (Float(low) * scale, Float(mid) * scale, Float(high) * scale)
    }

    static func encode(_ amplitude: Float) -> UInt8 {
        UInt8((max(0, min(1, amplitude)).squareRoot() * 255).rounded())
    }
}

/// Splits audio into bass, mid and high bands and keeps each band's peak per
/// column. Each band edge is two one-pole filters in a row (12 dB an octave);
/// the mid band is filtered directly rather than found by subtraction, which
/// would leak bass into it through the filters' phase shift.
struct BandSplitter {
    private let lowCoefficient: Float
    private let highCoefficient: Float
    private var low1: Float = 0, low2: Float = 0
    private var top1: Float = 0, top2: Float = 0, topHigh: Float = 0
    private var midLow1: Float = 0, midLow2: Float = 0
    private let columnsPerSecond: Int
    private let sampleRate: Int
    private var frame = 0
    private var column = 0
    private var peaks: (Float, Float, Float) = (0, 0, 0)
    private(set) var bytes: [UInt8] = []

    init(sampleRate: Double, columnsPerSecond: Double = WaveDetail.defaultColumnsPerSecond) {
        self.sampleRate = max(1, Int(sampleRate.rounded()))
        self.columnsPerSecond = max(1, Int(columnsPerSecond.rounded()))
        lowCoefficient = Float(1 - exp(-2 * Double.pi * WaveDetail.lowCutoff / sampleRate))
        highCoefficient = Float(1 - exp(-2 * Double.pi * WaveDetail.highCutoff / sampleRate))
    }

    mutating func reserve(frames: Int) {
        bytes.reserveCapacity((frames / sampleRate + 1) * columnsPerSecond * 3)
    }

    @inline(__always)
    mutating func add(_ sample: Float) {
        // Bass: low-pass twice.
        low1 += lowCoefficient * (sample - low1)
        low2 += lowCoefficient * (low1 - low2)
        // Highs: high-pass twice (a one-pole high-pass is the input minus its low-pass).
        top1 += highCoefficient * (sample - top1)
        let highOnce = sample - top1
        topHigh += highCoefficient * (highOnce - topHigh)
        let high = highOnce - topHigh
        // Mids: low-pass twice at the upper edge, then high-pass twice at the lower.
        top2 += highCoefficient * (top1 - top2)
        midLow1 += lowCoefficient * (top2 - midLow1)
        let midOnce = top2 - midLow1
        midLow2 += lowCoefficient * (midOnce - midLow2)
        let mid = midOnce - midLow2

        let target = frame * columnsPerSecond / sampleRate
        if target != column { flush(upTo: target) }
        peaks.0 = max(peaks.0, abs(low2))
        peaks.1 = max(peaks.1, abs(mid))
        peaks.2 = max(peaks.2, abs(high))
        frame += 1
    }

    private mutating func flush(upTo target: Int) {
        while column < target {
            bytes.append(WaveDetail.encode(peaks.0))
            bytes.append(WaveDetail.encode(peaks.1))
            bytes.append(WaveDetail.encode(peaks.2))
            peaks = (0, 0, 0)
            column += 1
        }
    }

    mutating func finish() -> WaveDetail {
        if frame > 0 { flush(upTo: column + 1) }
        return WaveDetail(columnsPerSecond: Double(columnsPerSecond), bytes: bytes)
    }
}
