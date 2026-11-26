import Foundation

/// Crates written as a rekordbox XML library: the file rekordbox reads under
/// Preferences > Advanced > Database > rekordbox xml.
///
/// It carries each crate as a playlist, in the crate's order, and for every track what rekordbox
/// would otherwise have to work out again or be told by hand: title, artist, album, tempo, key,
/// the beat grid, and the hot cues and saved loops with their names. The music itself is not
/// copied: each track points at its file where it is on this Mac.
///
/// The format is Pioneer's "XML file format for playlists sharing", version 1.0.0.
public enum Rekordbox {
    /// A track and what Crate knows about it.
    public struct Entry: Sendable {
        public var track: Track
        /// The file's size in bytes, when known.
        public var size: Int64
        public var grid: BeatGrid?
        public var cues: [CuePoint]

        public init(track: Track, size: Int64 = 0, grid: BeatGrid? = nil, cues: [CuePoint] = []) {
            self.track = track
            self.size = size
            self.grid = grid
            self.cues = cues
        }
    }

    public struct Playlist: Sendable {
        public var name: String
        public var trackIDs: [Int64]

        public init(name: String, trackIDs: [Int64]) {
            self.name = name
            self.trackIDs = trackIDs
        }
    }

    /// What an export came to.
    public struct Export: Sendable {
        public var xml: String
        public var playlists: Int
        /// How many different tracks are in the file.
        public var tracks: Int
        /// Tracks in the crates that rekordbox could not be pointed at: streaming tracks, and
        /// tracks whose file is only on another Mac.
        public var leftOut: [Track]
    }

    /// One stretch of a beat grid at one tempo, as rekordbox describes a grid.
    public struct Tempo: Equatable, Sendable {
        /// Where a beat of the stretch falls, in seconds.
        public var start: Double
        public var bpm: Double
        /// Which beat of the bar that is, 1...4.
        public var beatInBar: Int
    }

    /// True for a track rekordbox can be pointed at: a file on this Mac.
    public static func canExport(_ track: Track) -> Bool { track.source == .local && track.path != nil }

    // MARK: Beat grid

    /// A grid as rekordbox takes it: a first beat and a tempo, and another of each wherever the
    /// tempo changes. Crate's grid is even between its markers, so each stretch between two
    /// markers is one of these; a drum-machine track is a single one.
    public static func tempos(_ grid: BeatGrid) -> [Tempo] {
        let beats = grid.beats
        guard beats.count > 1 else { return [] }
        var anchors = grid.markers
        if anchors.count < 2 { anchors = [0, beats.count - 1] }

        var tempos: [Tempo] = []
        for (from, to) in zip(anchors, anchors.dropFirst()) where beats[to] > beats[from] {
            let bpm = 60 * Double(to - from) / (beats[to] - beats[from])
            // Before the first marker the first stretch's tempo carries on, so it starts at the first beat.
            var index = tempos.isEmpty ? 0 : from
            // rekordbox has no time before the start of the file.
            while index < to, beats[index] < 0 { index += 1 }
            guard beats[index] >= 0 else { continue }
            // Two stretches at one tempo are one line of beats.
            if let last = tempos.last, abs(last.bpm - bpm) < 0.0005 { continue }
            tempos.append(Tempo(start: beats[index], bpm: bpm, beatInBar: grid.beatInBar(index)))
        }
        return tempos
    }

    // MARK: Text

    private static let noteNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// A key as rekordbox writes it itself: "Am", "F#", "Bbm".
    public static func keyName(_ key: CamelotKey) -> String { noteNames[key.pitchClass] + (key.isMajor ? "" : "m") }

    /// A file's address as rekordbox writes it: "file://localhost/Users/…", with everything but
    /// letters, digits and a few marks percent-encoded.
    public static func location(path: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~/")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file://localhost" + (encoded.hasPrefix("/") ? "" : "/") + encoded
    }

    static func kind(format: String) -> String {
        switch format.lowercased() {
        case "mp3": return "MP3 File"
        case "wav", "wave": return "WAV File"
        case "aif", "aiff", "aifc": return "AIFF File"
        case "flac": return "FLAC File"
        case "m4a", "aac", "mp4", "alac": return "M4A File"
        default: return format.isEmpty ? "" : format.uppercased() + " File"
        }
    }

    /// The colours of Crate's eight pads, so a cue keeps its colour.
    private static let padColors: [(Int, Int, Int)] = [
        (255, 77, 77), (255, 158, 51), (255, 230, 64), (89, 230, 102), (64, 217, 242), (102, 140, 255), (191, 115, 255), (255, 115, 204),
    ]

    /// Text made safe inside an XML attribute. Characters XML does not allow at all are dropped.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            case "\t": result += "&#9;"
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// A number as XML wants it whatever the Mac's region: a point, no grouping.
    private static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// A tempo to six places, without the noughts that say nothing beyond the second.
    static func bpmText(_ bpm: Double) -> String {
        var text = number(bpm, decimals: 6)
        for _ in 0..<4 where text.hasSuffix("0") { text.removeLast() }
        return text
    }

    // MARK: The file

    /// - Parameters:
    ///   - entries: the tracks, each once. Those rekordbox cannot be pointed at are left out.
    ///   - playlists: the crates, naming their tracks by id in order.
    ///   - folder: a folder to put the playlists in, so that many can be taken into rekordbox in one go.
    public static func xml(entries: [Entry], playlists: [Playlist], folder: String? = nil) -> String {
        let entries = entries.filter { canExport($0.track) }
        let included = Set(entries.map(\.track.id))
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<DJ_PLAYLISTS Version=\"1.0.0\">")
        lines.append("  <PRODUCT Name=\"rekordbox\" Version=\"6.0.0\" Company=\"AlphaTheta\"/>")
        lines.append("  <COLLECTION Entries=\"\(entries.count)\">")
        for entry in entries {
            let track = entry.track
            let tempos = entry.grid.map(Self.tempos) ?? []
            let bpm = track.bpm ?? entry.grid.map(\.bpm) ?? 0
            let attributes: [(String, String)] = [
                ("TrackID", "\(track.id)"), ("Name", track.title), ("Artist", track.artist), ("Composer", ""),
                ("Album", track.album), ("Grouping", ""), ("Genre", ""), ("Kind", kind(format: track.format)),
                ("Size", "\(max(0, entry.size))"), ("TotalTime", "\(Int(track.duration.rounded()))"), ("DiscNumber", "0"),
                ("TrackNumber", "0"), ("Year", "0"), ("AverageBpm", number(bpm, decimals: 2)),
                ("DateAdded", dates.string(from: track.addedAt)), ("Comments", track.notes), ("PlayCount", "0"), ("Rating", "0"),
                ("Location", location(path: track.path ?? "")), ("Remixer", ""),
                ("Tonality", track.camelot.map(keyName) ?? ""), ("Label", ""), ("Mix", ""),
            ]
            let opening = "    <TRACK " + attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
            // A cue outside the file would land nowhere.
            let cues = entry.cues
                .filter { CuePoint.slots.contains($0.slot) && $0.position >= 0 && (track.duration <= 0 || $0.position < track.duration) }
                .sorted { $0.slot < $1.slot }
            if tempos.isEmpty, cues.isEmpty {
                lines.append(opening + "/>")
                continue
            }
            lines.append(opening + ">")
            for tempo in tempos {
                lines.append(
                    "      <TEMPO Inizio=\"\(number(tempo.start, decimals: 3))\" Bpm=\"\(bpmText(tempo.bpm))\" Metro=\"4/4\" Battito=\"\(tempo.beatInBar)\"/>")
            }
            for cue in cues {
                // Hot cue A is 0. A saved loop is a mark of type 4 with an end.
                let color = padColors[(cue.slot - 1) % padColors.count]
                var mark = "      <POSITION_MARK Name=\"\(escape(cue.name))\" Type=\"\(cue.isLoop ? 4 : 0)\" Start=\"\(number(cue.position, decimals: 3))\""
                if let end = cue.loopEnd { mark += " End=\"\(number(end, decimals: 3))\"" }
                mark += " Num=\"\(cue.slot - 1)\" Red=\"\(color.0)\" Green=\"\(color.1)\" Blue=\"\(color.2)\"/>"
                lines.append(mark)
            }
            lines.append("    </TRACK>")
        }
        lines.append("  </COLLECTION>")

        lines.append("  <PLAYLISTS>")
        let indent = folder == nil ? "      " : "        "
        lines.append("    <NODE Type=\"0\" Name=\"ROOT\" Count=\"\(folder == nil ? playlists.count : 1)\">")
        if let folder { lines.append("      <NODE Type=\"0\" Name=\"\(escape(folder))\" Count=\"\(playlists.count)\">") }
        for playlist in playlists {
            let ids = playlist.trackIDs.filter(included.contains)
            lines.append("\(indent)<NODE Name=\"\(escape(playlist.name))\" Type=\"1\" KeyType=\"0\" Entries=\"\(ids.count)\">")
            for id in ids { lines.append("\(indent)  <TRACK Key=\"\(id)\"/>") }
            lines.append("\(indent)</NODE>")
        }
        if folder != nil { lines.append("      </NODE>") }
        lines.append("    </NODE>")
        lines.append("  </PLAYLISTS>")
        lines.append("</DJ_PLAYLISTS>")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension LibraryStore {
    /// Crates as a rekordbox XML library. More than one crate goes into a folder, so that they can
    /// be dragged into rekordbox together.
    public func rekordboxExport(crates: [Crate], folder: String = "Crate") throws -> Rekordbox.Export {
        var entries: [Rekordbox.Entry] = []
        var seen = Set<Int64>()
        var leftOut: [Track] = []
        var playlists: [Rekordbox.Playlist] = []
        for crate in crates {
            let tracks = try tracks(inCrate: crate.id)
            playlists.append(Rekordbox.Playlist(name: crate.name, trackIDs: tracks.map(\.id)))
            for track in tracks where seen.insert(track.id).inserted {
                guard Rekordbox.canExport(track) else {
                    leftOut.append(track)
                    continue
                }
                let size = try db.query("SELECT size FROM tracks WHERE id = ?", [.int(track.id)]).first?.int("size") ?? 0
                entries.append(
                    Rekordbox.Entry(track: track, size: size, grid: try beatGrid(id: track.id), cues: try cuePoints(id: track.id)))
            }
        }
        return Rekordbox.Export(
            xml: Rekordbox.xml(entries: entries, playlists: playlists, folder: crates.count > 1 ? folder : nil),
            playlists: playlists.count, tracks: entries.count, leftOut: leftOut)
    }
}
