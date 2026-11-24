import Foundation

/// Something done on a DJ controller, in Crate's terms.
public enum ControlEvent: Equatable, Sendable {
    case play(DeckID)
    case cue(DeckID, down: Bool)
    case jumpToStart(DeckID)
    case sync(DeckID)
    /// Sync held down: make this deck the tempo master.
    case master(DeckID)
    case shift(DeckID, down: Bool)

    /// A hand on (or off) the top of the jog wheel.
    case jogTouch(DeckID, down: Bool)
    /// The wheel turned with a hand on top: scratch. `ticks` forwards, negative backwards.
    case jogScratch(DeckID, ticks: Int)
    /// The wheel turned by its edge: nudge.
    case jogBend(DeckID, ticks: Int)
    /// The wheel turned with Shift held: search through the track.
    case jogSearch(DeckID, ticks: Int)

    /// 0 at the "−" end of the slider, 1 at the "+" end.
    case tempo(DeckID, Double)
    /// Knobs and faders, 0...1 from one end of their travel to the other.
    case trim(DeckID, Double)
    case eq(DeckID, band: Int, Double)
    case fader(DeckID, Double)
    case filter(DeckID, Double)
    case crossfader(Double)
    case headphoneMix(Double)
    case headphoneCue(DeckID)

    case loopIn(DeckID, down: Bool)
    case loopOut(DeckID)
    case reloop(DeckID)
    case loopHalve(DeckID)
    case loopDouble(DeckID)
    case jump(DeckID, beats: Double)

    case padMode(DeckID, PadMode)
    case hotCue(DeckID, Int)
    case clearHotCue(DeckID, Int)
    case beatLoop(DeckID, beats: Double)
    /// A sampler pad, 0...7, hit; with SHIFT it stops the pad instead.
    case sample(Int, stop: Bool)

    /// The browse knob: rows down the track list, negative for up.
    case browse(Int)
    case browsePush
    case zoom(Int)
    case load(DeckID)

    case effect(DeckID)
    case effectBeats(longer: Bool)
}

public enum PadMode: Equatable, Sendable {
    case hotCue, beatLoop, beatJump, sampler, other
}

/// A light on the controller.
public enum ControlLight: Hashable, Sendable {
    case play(DeckID), cue(DeckID), sync(DeckID), headphoneCue(DeckID)
    case loopIn(DeckID), loopOut(DeckID), reloop(DeckID)
    case loaded(DeckID)
    case hotCue(DeckID, Int)
    case beatLoop(DeckID, Int)
    /// A pad in SAMPLER mode, 0...7, on either deck's side.
    case sample(DeckID, Int)
    case padMode(DeckID, PadMode)
    case effect(DeckID)
}

/// The Pioneer DJ DDJ-FLX4, as MIDI.
///
/// The numbers are the controller's published ones, as used by the Mixxx
/// project's mapping for it. Decks are MIDI channels 1 and 2, the mixer's
/// shared controls channel 7, the effects 5 and 6, and the pads 8 to 11 (each
/// deck's pads, then the same with Shift held). Faders and knobs send fourteen
/// bits as two messages, coarse then fine.
public enum DDJFLX4 {
    /// Sent when the controller is found and a few times a second after: it answers with
    /// where every knob and fader stands, and stays in its controller mode.
    public static let hello: [UInt8] = [0xF0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x04, 0x05, 0x00, 0x50, 0x02, 0xF7]

    public static func isThisController(_ name: String) -> Bool {
        name.uppercased().contains("DDJ-FLX4")
    }

    /// Turns the controller's messages into events. It remembers the coarse half of each fader's value until the fine half arrives.
    public struct Decoder: Sendable {
        private var coarse: [UInt16: UInt8] = [:]

        public init() {}

        public mutating func decode(status: UInt8, data1: UInt8, data2: UInt8) -> ControlEvent? {
            let kind = status & 0xF0, channel = Int(status & 0x0F)
            switch kind {
            case 0x90, 0x80:
                return note(channel: channel, number: data1, down: kind == 0x90 && data2 > 0)
            case 0xB0:
                return control(channel: channel, number: data1, value: data2)
            default:
                return nil
            }
        }

        private func note(channel: Int, number: UInt8, down: Bool) -> ControlEvent? {
            switch channel {
            case 0, 1:
                let deck: DeckID = channel == 0 ? .a : .b
                // These report letting go as well as pressing.
                switch number {
                case 0x0C: return .cue(deck, down: down)
                case 0x3F: return .shift(deck, down: down)
                case 0x36, 0x67: return .jogTouch(deck, down: down)
                case 0x10: return .loopIn(deck, down: down)
                default: break
                }
                guard down else { return nil }
                switch number {
                case 0x0B: return .play(deck)
                case 0x48: return .jumpToStart(deck)
                case 0x58: return .sync(deck)
                case 0x5C: return .master(deck)
                case 0x54: return .headphoneCue(deck)
                case 0x11: return .loopOut(deck)
                case 0x4D, 0x50: return .reloop(deck)
                case 0x51: return .loopHalve(deck)
                case 0x53: return .loopDouble(deck)
                case 0x3E: return .jump(deck, beats: -32)
                case 0x3D: return .jump(deck, beats: 32)
                case 0x1B: return .padMode(deck, .hotCue)
                case 0x6D: return .padMode(deck, .beatLoop)
                case 0x20: return .padMode(deck, .beatJump)
                case 0x22: return .padMode(deck, .sampler)
                case 0x69, 0x1E, 0x6B, 0x6F: return .padMode(deck, .other)
                default: return nil
                }
            case 4, 5:
                guard down else { return nil }
                switch number {
                case 0x47: return .effect(channel == 4 ? .a : .b)
                case 0x4A: return .effectBeats(longer: false)
                case 0x4B: return .effectBeats(longer: true)
                default: return nil
                }
            case 6:
                guard down else { return nil }
                switch number {
                case 0x41, 0x42: return .browsePush
                case 0x46: return .load(.a)
                case 0x47: return .load(.b)
                default: return nil
                }
            case 7, 8, 9, 10:
                guard down else { return nil }
                let deck: DeckID = channel < 9 ? .a : .b
                let shifted = channel == 8 || channel == 10
                switch number {
                case 0x00...0x07: return shifted ? .clearHotCue(deck, Int(number) + 1) : .hotCue(deck, Int(number) + 1)
                case 0x60...0x67: return .beatLoop(deck, beats: Self.loopBeats[Int(number - 0x60)])
                case 0x20...0x27:
                    let size = Double(1 << (Int(number - 0x20) / 2))
                    return .jump(deck, beats: number % 2 == 0 ? -size : size)
                // Both sides' pads play the same eight samples.
                case 0x30...0x37: return .sample(Int(number - 0x30), stop: shifted)
                default: return nil
                }
            default:
                return nil
            }
        }

        /// The eight beat-loop pads, left to right, top row first.
        public static let loopBeats: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]

        private mutating func control(channel: Int, number: UInt8, value: UInt8) -> ControlEvent? {
            let deck: DeckID = channel == 0 ? .a : .b
            if channel <= 1 {
                // The jog wheel sends 64 plus or minus how far it turned.
                let ticks = Int(value) - 64
                switch number {
                case 0x22: return .jogScratch(deck, ticks: ticks)
                case 0x21, 0x23: return .jogBend(deck, ticks: ticks)
                case 0x29: return .jogSearch(deck, ticks: ticks)
                default: break
                }
            }
            if channel == 6 {
                // The browse knob sends small numbers one way and numbers just under 128 the other.
                switch number {
                case 0x40: return .browse(value < 64 ? Int(value) : Int(value) - 128)
                case 0x64: return .zoom(value < 64 ? Int(value) : Int(value) - 128)
                default: break
                }
            }
            // Everything else is a fader or a knob: coarse half on a low number, fine half thirty-two above it.
            guard channel <= 1 || channel == 6 else { return nil }
            if number < 0x20 {
                coarse[UInt16(channel) << 8 | UInt16(number)] = value
                return nil
            }
            guard number < 0x40, let high = coarse[UInt16(channel) << 8 | UInt16(number - 0x20)] else { return nil }
            let position = Double(Int(high) << 7 | Int(value)) / 16383
            switch (channel, number - 0x20) {
            case (0...1, 0x00): return .tempo(deck, position)
            case (0...1, 0x04): return .trim(deck, position)
            case (0...1, 0x07): return .eq(deck, band: 2, position)
            case (0...1, 0x0B): return .eq(deck, band: 1, position)
            case (0...1, 0x0F): return .eq(deck, band: 0, position)
            case (0...1, 0x13): return .fader(deck, position)
            case (6, 0x17): return .filter(.a, position)
            case (6, 0x18): return .filter(.b, position)
            case (6, 0x1F): return .crossfader(position)
            case (6, 0x0C): return .headphoneMix(position)
            default: return nil
            }
        }
    }

    // MARK: Lights

    /// The message that turns a light on or off.
    public static func message(for light: ControlLight, on: Bool) -> [UInt8] {
        let value: UInt8 = on ? 0x7F : 0x00
        func deckNote(_ deck: DeckID, _ number: UInt8) -> [UInt8] { [0x90 + UInt8(deck.rawValue), number, value] }
        func pad(_ deck: DeckID, _ number: UInt8) -> [UInt8] { [deck == .a ? 0x97 : 0x99, number, value] }
        switch light {
        case .play(let deck): return deckNote(deck, 0x0B)
        case .cue(let deck): return deckNote(deck, 0x0C)
        case .sync(let deck): return deckNote(deck, 0x58)
        case .headphoneCue(let deck): return deckNote(deck, 0x54)
        case .loopIn(let deck): return deckNote(deck, 0x10)
        case .loopOut(let deck): return deckNote(deck, 0x11)
        case .reloop(let deck): return deckNote(deck, 0x4D)
        case .loaded(let deck): return [0x9F, UInt8(deck.rawValue), value]
        case .hotCue(let deck, let slot): return pad(deck, UInt8(max(1, min(8, slot)) - 1))
        case .beatLoop(let deck, let index): return pad(deck, 0x60 + UInt8(max(0, min(7, index))))
        case .sample(let deck, let index): return pad(deck, 0x30 + UInt8(max(0, min(7, index))))
        case .effect(let deck): return [deck == .a ? 0x94 : 0x95, 0x47, value]
        case .padMode(let deck, let mode):
            switch mode {
            case .hotCue: return deckNote(deck, 0x1B)
            case .beatLoop: return deckNote(deck, 0x6D)
            case .beatJump: return deckNote(deck, 0x20)
            case .sampler: return deckNote(deck, 0x22)
            case .other: return []
            }
        }
    }

    /// A channel's level meter, 0...1.
    public static func meter(_ deck: DeckID, level: Double) -> [UInt8] {
        [0xB0 + UInt8(deck.rawValue), 0x02, UInt8(max(0, min(127, (level * 127).rounded())))]
    }
}
