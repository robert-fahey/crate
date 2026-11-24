import Foundation

/// A musical key on the Camelot wheel: number 1...12, letter A (minor) or B (major).
public struct CamelotKey: Hashable, CustomStringConvertible, Sendable {
    public let number: Int
    public let isMajor: Bool

    public init?(number: Int, isMajor: Bool) {
        guard (1...12).contains(number) else { return nil }
        self.number = number
        self.isMajor = isMajor
    }

    public var description: String { "\(number)\(isMajor ? "B" : "A")" }

    // Camelot number for each pitch class (C = 0 ... B = 11).
    private static let majorNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    private static let minorNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
    private static let noteNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    public init(pitchClass: Int, isMajor: Bool) {
        let index = ((pitchClass % 12) + 12) % 12
        self.number = isMajor ? Self.majorNumbers[index] : Self.minorNumbers[index]
        self.isMajor = isMajor
    }

    public var pitchClass: Int {
        (isMajor ? Self.majorNumbers : Self.minorNumbers).firstIndex(of: number) ?? 0
    }

    /// "A minor", "E♭ major".
    public var musicalName: String { "\(Self.noteNames[pitchClass]) \(isMajor ? "major" : "minor")" }

    /// Keys that mix harmonically: the same key, one step either way round the
    /// wheel, and the relative major or minor.
    public var compatible: [CamelotKey] {
        let down = number == 1 ? 12 : number - 1
        let up = number == 12 ? 1 : number + 1
        return [
            self,
            CamelotKey(number: down, isMajor: isMajor)!,
            CamelotKey(number: up, isMajor: isMajor)!,
            CamelotKey(number: number, isMajor: !isMajor)!,
        ]
    }

    /// Reads the notations found in tags and typed by people: Camelot ("8A"),
    /// Open Key ("1m", "1d"), and note names ("Am", "A minor", "F#", "Bbm", "G# min").
    public init?(parsing raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let upper = text.uppercased()

        if let match = upper.wholeMatch(of: /0?(\d{1,2})\s*([AB])/), let number = Int(match.1) {
            guard let key = CamelotKey(number: number, isMajor: match.2 == "B") else { return nil }
            self = key
            return
        }
        // Open Key: 1d = C major = 8B, 1m = A minor = 8A.
        if let match = upper.wholeMatch(of: /0?(\d{1,2})\s*([MD])/), let number = Int(match.1), (1...12).contains(number) {
            let camelot = (number + 6) % 12 + 1
            self = CamelotKey(number: camelot, isMajor: match.2 == "D")!
            return
        }

        guard let match = text.wholeMatch(of: /([A-Ga-g])\s*([#♯b♭]?)\s*(.*)/) else { return nil }
        let base: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pitch = base[Character(match.1.uppercased())] else { return nil }
        switch match.2 {
        case "#", "♯": pitch += 1
        case "b", "♭": pitch -= 1
        default: break
        }
        let quality = match.3.lowercased().trimmingCharacters(in: .whitespaces)
        let isMajor: Bool
        switch quality {
        case "", "maj", "major", "dur": isMajor = true
        case "m", "min", "minor", "moll": isMajor = false
        default: return nil
        }
        self.init(pitchClass: pitch, isMajor: isMajor)
    }
}
