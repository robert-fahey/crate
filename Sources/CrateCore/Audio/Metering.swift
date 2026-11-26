import Foundation

/// The lights of a level meter: twenty of them, closer together towards the top, where it matters.
/// Green up to -8 dB, amber up to full scale, red over it.
public enum MeterScale {
    /// The level, in decibels against full scale, at which each light comes on, bottom to top.
    public static let thresholds: [Float] = [
        -48, -42, -36, -30, -27, -24, -21, -18, -15, -12, -10, -8,
        -6, -4.5, -3, -2, -1,
        1, 3, 5,
    ]
    public static let count = thresholds.count
    public static let firstAmber = 12
    public static let firstRed = 17
    /// Decibel marks worth printing beside a meter, and the light each sits level with. Full scale
    /// sits between the last amber light and the first red one.
    public static let marks: [(label: String, light: Double)] = [("0", 16.5), ("6", 12), ("12", 9), ("24", 5), ("48", 0)]

    public static func decibels(_ level: Float) -> Float { level > 0 ? 20 * log10(level) : -.infinity }

    /// How many lights a level puts on. `level` is linear: 1 is full scale.
    public static func lights(for level: Float) -> Int {
        let decibels = decibels(level)
        // The lights are in order, so the first one the level does not reach ends the count.
        return thresholds.firstIndex { decibels < $0 } ?? count
    }
}

/// What a meter is showing, in whole lights: it changes far less often than the level does,
/// so drawing from it redraws far less often.
public struct MeterLights: Hashable, Sendable {
    /// Lights on, from the bottom.
    public var lit = 0
    /// The light left on at the loudest recent peak; 0 for none.
    public var held = 0
    /// Over full scale a moment ago.
    public var isOver = false

    public init(lit: Int = 0, held: Int = 0, isOver: Bool = false) {
        self.lit = lit
        self.held = held
        self.isOver = isOver
    }
}

/// How a meter moves. It jumps to a peak at once and falls back at a steady rate, as a peak
/// programme meter does, with a light left behind at the loudest recent peak.
///
/// It is fed the loudest sample since the last time, together with how long ago that was, so the
/// fall is by the clock: feeding it late or unevenly changes nothing about what it shows.
public struct MeterBallistics: Sendable {
    /// How fast the level falls back, in decibels a second: 20 dB in about 1.7 seconds.
    public static let fall = 12.0
    /// How long the loudest peak stays lit before it too falls back, in seconds.
    public static let holdTime = 1.2
    /// How fast the held peak falls once its time is up.
    public static let heldFall = 36.0
    /// How long "over" stays on after the level was last over full scale.
    public static let overTime = 1.5
    /// Over full scale by enough to matter: the first red light.
    public static let overLevel = Float(pow(10, Double(MeterScale.thresholds[MeterScale.firstRed]) / 20))

    /// The level shown, linear.
    public private(set) var level: Float = 0
    /// The loudest recent peak, linear.
    public private(set) var held: Float = 0
    private var heldFor = 0.0
    private var sinceOver = Double.infinity

    public init() {}

    public var isOver: Bool { sinceOver < Self.overTime }

    public var lights: MeterLights {
        let lit = MeterScale.lights(for: level)
        let top = MeterScale.lights(for: held)
        return MeterLights(lit: lit, held: top > lit ? top : 0, isOver: isOver)
    }

    /// True once there is nothing left to show: the meter can be left alone until there is sound again.
    public var isAtRest: Bool { level == 0 && held == 0 && !isOver }

    /// Takes the loudest sample of the last `seconds`.
    public mutating func feed(_ peak: Float, after seconds: Double) {
        let seconds = max(0, min(1, seconds))
        let peak = peak.isFinite ? max(0, peak) : 0
        level = max(peak, Self.fallen(level, by: Self.fall * seconds))
        if peak >= held {
            held = peak
            heldFor = 0
        } else {
            heldFor += seconds
            if heldFor > Self.holdTime { held = max(level, Self.fallen(held, by: Self.heldFall * seconds)) }
        }
        if peak >= Self.overLevel { sinceOver = 0 } else if sinceOver.isFinite { sinceOver += seconds }
        if sinceOver > Self.overTime * 4 { sinceOver = .infinity }
    }

    /// Silence at once, for a deck that has been emptied.
    public mutating func reset() { self = MeterBallistics() }

    private static func fallen(_ level: Float, by decibels: Double) -> Float {
        let fallen = level * Float(pow(10, -decibels / 20))
        // Below the bottom light there is nothing to show: stop there, so a meter comes to rest.
        return fallen < 0.002 ? 0 : fallen
    }
}
