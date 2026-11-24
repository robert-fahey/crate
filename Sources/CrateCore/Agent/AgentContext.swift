import Foundation

/// Which conversation with the agent: the library's, or a crate's own.
///
/// A crate has its own conversation so that what was said about it stays with it:
/// what the crate is for, what was tried, what the DJ did not like. The library's
/// conversation is the one for everything else.
public struct ConversationID: Hashable, Sendable {
    public let key: String

    public static let library = ConversationID(key: "library")

    /// A crate's conversation goes by the crate's identity, which survives a rename.
    public static func crate(_ crate: Crate) -> ConversationID {
        ConversationID(key: "crate." + (crate.uid.isEmpty ? "#\(crate.id)" : crate.uid))
    }

    public var isLibrary: Bool { self == .library }

    /// Where the conversation's history is kept in the library's settings. The library's keeps the
    /// name it had when there was only one conversation, so that one carries on as it was.
    public var historySetting: String { isLibrary ? "agent.history" : "agent.history." + key }
    /// Where the agent's own identifier for the conversation is kept; with it the agent remembers.
    public var agentSetting: String { isLibrary ? "agent.id" : "agent.id." + key }
}

/// What the DJ has in front of them when they speak to the agent.
///
/// It goes along with every request, so that "this crate", "these" and "what's playing"
/// mean what the DJ is looking at, and it decides what the agent bar suggests.
public struct AgentContext: Equatable, Sendable {
    public struct Deck: Equatable, Sendable {
        public var name: String
        public var track: Track?
        /// The tempo it is playing at, which differs from the track's own when the tempo slider is off centre.
        public var bpm: Double?
        public var isPlaying: Bool

        public init(name: String, track: Track?, bpm: Double? = nil, isPlaying: Bool = false) {
            self.name = name
            self.track = track
            self.bpm = bpm
            self.isPlaying = isPlaying
        }
    }

    /// The name of what the list shows: "All Tracks", "To Tag", or the crate's name.
    public var view: String
    /// The crate on screen, when it is one. Its conversation is the one being spoken in.
    public var crate: Crate?
    public var selection: [Track]
    public var decks: [Deck]
    /// What is typed in the search field, which narrows the list.
    public var search: String
    /// The list is the tracks still missing an artist, BPM or key.
    public var needsTagging: Bool

    public init(
        view: String, crate: Crate? = nil, selection: [Track] = [], decks: [Deck] = [], search: String = "", needsTagging: Bool = false
    ) {
        self.view = view
        self.crate = crate
        self.selection = selection
        self.decks = decks
        self.search = search
        self.needsTagging = needsTagging
    }

    /// The most tracks named one by one; a larger selection is given as these and a count.
    public static let selectionLimit = 12

    public static let opening = "<crate-context>"
    public static let closing = "</crate-context>"

    static func describe(_ track: Track, bpm: Double? = nil) -> String {
        var text = "id \(track.id) " + (track.artist.isEmpty ? track.title : "\(track.artist) – \(track.title)")
        var details: [String] = []
        if let bpm = bpm ?? track.bpm { details.append(String(format: "%.1f BPM", bpm)) }
        if let key = track.key { details.append(key) }
        if !details.isEmpty { text += " (\(details.joined(separator: ", ")))" }
        return text
    }

    /// The block put in front of each request. The DJ does not see it; the agent's instructions explain it.
    public func preamble() -> String {
        var lines: [String] = []
        if let crate {
            let count = crate.trackCount == 1 ? "1 track" : "\(crate.trackCount) tracks"
            lines.append(
                "The DJ is looking at the crate \"\(crate.name)\" (\(crate.trackCount == 0 ? "empty" : count)). "
                    + "This conversation belongs to that crate.")
        } else {
            lines.append("The DJ is looking at \"\(view)\". This is the library's conversation, not a crate's.")
        }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("The list is narrowed by the search \"\(search)\".")
        }
        if selection.isEmpty {
            lines.append("Nothing is selected in the list.")
        } else {
            let named = selection.prefix(Self.selectionLimit).map { Self.describe($0) }.joined(separator: "; ")
            let more = selection.count > Self.selectionLimit ? "; and \(selection.count - Self.selectionLimit) more" : ""
            lines.append("Selected in the list (\(selection.count)): \(named)\(more).")
        }
        for deck in decks {
            if let track = deck.track {
                lines.append("Deck \(deck.name): \(deck.isPlaying ? "playing" : "loaded, not playing") \(Self.describe(track, bpm: deck.bpm)).")
            } else {
                lines.append("Deck \(deck.name): empty.")
            }
        }
        return ([Self.opening] + lines + [Self.closing]).joined(separator: "\n") + "\n\n"
    }

    /// A request with the block in front of it taken off again: what the DJ typed.
    public static func withoutPreamble(_ text: String) -> String {
        guard text.hasPrefix(opening), let end = text.range(of: closing) else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: What to offer

    private var playing: Deck? { decks.first { $0.isPlaying && $0.track != nil } }

    /// What the empty text field says, so it is plain what a request would be about.
    public var placeholder: String {
        if selection.count == 1, let track = selection.first { return "Ask about “\(track.title)”…" }
        if selection.count > 1 { return "Ask about the \(selection.count) selected tracks…" }
        if let crate {
            return crate.trackCount == 0
                ? "Say what “\(crate.name)” is for, and it will be filled from your library…"
                : "Ask about “\(crate.name)”: add to it, put it in order, play it as a set…"
        }
        return "Ask for music: “find everything around 122 BPM in 5A”, “mix into the next track”…"
    }

    /// Up to four things worth asking with what is on screen, the most particular first.
    public var suggestions: [AgentSuggestion] {
        var found: [AgentSuggestion] = []
        if selection.count == 1, let track = selection.first {
            found.append(.question("What mixes with this?", "What in my library mixes well with the selected track?"))
            if let playing, playing.track?.id != track.id {
                found.append(.action("Mix into this", "Mix from what is playing into the selected track."))
            }
            found.append(.question("More like this", "Find more tracks in my library like the selected one."))
        } else if selection.count > 1 {
            found.append(.question("Order these for a set", "In what order would the selected tracks mix best? Tell me the order and why."))
            found.append(.action("Make a crate from these…", "Make a crate from the selected tracks called "))
        } else if playing != nil {
            found.append(.question(
                "What should I play next?", "What should I play after the track that is playing? Give me a few options from my library."))
        }

        if let crate {
            if crate.trackCount == 0 {
                found.append(.action("Fill this crate…", "Fill this crate with "))
            } else {
                if selection.isEmpty { found.append(.question("Find more that fit", "What else in my library would fit this crate? Show me before adding anything.")) }
                if crate.trackCount > 1 {
                    found.append(.action("Plan the mix", "Plan a mix of this crate: put it in an order that flows and save a transition for every pair of tracks."))
                    found.append(.action("Put in mixing order", "Put this crate in an order that mixes well, by tempo and key."))
                    found.append(.action("DJ this crate", "DJ this crate."))
                }
            }
        } else if needsTagging {
            found.append(.action("Tidy these up", "Fix the artist and title of the tracks that need tagging, working from their file names."))
        } else if selection.isEmpty {
            found.append(.action("Make a crate of…", "Make a crate of "))
            if playing == nil {
                found.append(.question("What's in my library?", "Give me a quick picture of my library: how many tracks, and the spread of tempos and keys."))
            }
        }
        return Array(found.prefix(4))
    }
}

/// Something the agent bar offers to ask, so the DJ need not know what to type.
public struct AgentSuggestion: Equatable, Sendable, Identifiable {
    public var label: String
    public var request: String
    /// A question is sent as it stands. Anything that would change a crate or touch the decks is put
    /// in the text field instead, for the DJ to finish or send: one click must not start a mix.
    public var sendsAtOnce: Bool

    public var id: String { label }

    static func question(_ label: String, _ request: String) -> AgentSuggestion {
        AgentSuggestion(label: label, request: request, sendsAtOnce: true)
    }

    static func action(_ label: String, _ request: String) -> AgentSuggestion {
        AgentSuggestion(label: label, request: request, sendsAtOnce: false)
    }
}

/// A link to a track in one of the agent's replies: `crate://track/14`.
public enum TrackLink {
    public static func url(for trackID: Int64) -> String { "crate://track/\(trackID)" }

    public static func trackID(from url: URL) -> Int64? {
        guard url.scheme == "crate", url.host == "track" else { return nil }
        return Int64(url.lastPathComponent)
    }
}
