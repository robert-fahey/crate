import Foundation

extension Track {
    // Sort keys for the track list: tracks with no value sort after those with one.
    public var sortBPM: Double { bpm ?? .infinity }
    /// Camelot order: 1A, 1B, 2A … 12B, so neighbours in a sorted list are keys that mix.
    public var sortKey: Int { camelot.map { $0.number * 2 + ($0.isMajor ? 1 : 0) } ?? .max }
    /// Tempo to the nearest whole beat a minute: 123.6 and 124.3 are the same tempo to a DJ.
    public var sortWholeBPM: Double { bpm.map { $0.rounded() } ?? .infinity }
}

/// Sorting the track list by two columns at once.
///
/// The column clicked last sorts the list; the one clicked before it orders the
/// tracks that tie. Click Key, then BPM: by tempo, and by key among tracks at the
/// same tempo. Click BPM, then Key: by key, and by tempo within each key.
public enum TrackSorting {
    public typealias Level = KeyPathComparator<Track>

    /// The sort after a column header is clicked: that column first, then the column that led before.
    public static func levels(clicking clicked: Level, after previous: [Level]) -> [Level] {
        Array(([clicked] + previous.filter { $0.keyPath != clicked.keyPath }).prefix(2))
    }

    /// What to sort with. Sorting by tempo and then key would do nothing if tempo were compared
    /// exactly, since hardly any two tracks share a tempo to the decimal; so there tempo is
    /// compared to the whole beat a minute, and the exact tempo only settles what is still level.
    public static func comparators(for levels: [Level]) -> [Level] {
        guard levels.count > 1, levels[0].keyPath == \Track.sortBPM, levels[1].keyPath == \Track.sortKey else { return levels }
        return [KeyPathComparator(\Track.sortWholeBPM, order: levels[0].order), levels[1], levels[0]]
    }

    /// "BPM, then key", for showing which two columns are in charge. Nil for a single level.
    public static func description(of levels: [Level]) -> String? {
        let names = levels.prefix(2).compactMap { name(of: $0.keyPath) }
        guard names.count == 2 else { return nil }
        return "by \(names[0]), then \(names[1])"
    }

    private static func name(of keyPath: PartialKeyPath<Track>) -> String? {
        switch keyPath {
        case \Track.title: return "title"
        case \Track.artist: return "artist"
        case \Track.sortBPM: return "BPM"
        case \Track.sortKey: return "key"
        case \Track.duration: return "time"
        case \Track.addedAt: return "date added"
        case \Track.format: return "source"
        default: return nil
        }
    }
}
