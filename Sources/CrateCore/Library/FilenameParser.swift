import Foundation

/// Guesses artist / title / album for files with no tags, from the file name
/// and its folders. Most WAV and AIFF files in a DJ library are like this.
public enum FilenameParser {
    public struct Guess: Equatable {
        public var artist: String
        public var title: String
        public var album: String

        public init(artist: String = "", title: String = "", album: String = "") {
            self.artist = artist
            self.title = title
            self.album = album
        }
    }

    /// - Parameters:
    ///   - path: the audio file.
    ///   - root: the library folder it was found under. Folders above the root say nothing about the track.
    public static func guess(path: String, root: String? = nil) -> Guess {
        let url = URL(fileURLWithPath: path)
        let name = clean(url.deletingPathExtension().lastPathComponent)

        var folders: [String] = []
        if let root {
            let rootParts = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
            let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            if parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts {
                folders = Array(parts.dropFirst(rootParts.count))
            }
        }

        let parts = name.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var guess = Guess()
        // Drop pieces that are only a track or side number: "03", "A1", "12.".
        let meaningful = parts.filter { !isTrackNumber($0) }

        switch meaningful.count {
        case 0:
            guess.title = name
        case 1:
            guess.title = stripLeadingNumber(meaningful[0])
        case 2:
            guess.artist = stripLeadingNumber(meaningful[0])
            guess.title = meaningful[1]
        default:
            guess.artist = stripLeadingNumber(meaningful[0])
            guess.album = meaningful[1..<(meaningful.count - 1)].joined(separator: " - ")
            guess.title = meaningful[meaningful.count - 1]
        }

        // No artist in the name: fall back to Artist/Album/Track or Artist/Track folders.
        if guess.artist.isEmpty {
            if folders.count >= 2 {
                guess.artist = clean(folders[folders.count - 2])
                if guess.album.isEmpty { guess.album = clean(folders[folders.count - 1]) }
            } else if folders.count == 1 {
                guess.artist = clean(folders[0])
            }
        } else if guess.album.isEmpty, folders.count >= 2 {
            guess.album = clean(folders[folders.count - 1])
        }
        if guess.title.isEmpty { guess.title = name }
        return guess
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isTrackNumber(_ text: String) -> Bool {
        text.wholeMatch(of: /(\d{1,3}|[A-Da-d]\d)\.?/) != nil
    }

    /// "01 Title", "01. Title", "1-03 Title", "A2 Title" -> "Title". Leaves
    /// names that merely start with a number ("808 State", "2 Bad Mice") alone
    /// unless the number is zero-padded or followed by a dot.
    private static func stripLeadingNumber(_ text: String) -> String {
        let patterns: [Regex<Substring>] = [
            /^\d{1,2}-\d{1,3}[\s.]+/,
            /^0\d{1,2}[\s.]+/,
            /^\d{1,3}\.\s+/,
            /^[A-Da-d]\d[\s.]+(?=\S)/,
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern) {
                let rest = String(text[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return text
    }
}
