import Foundation

/// A mix as the agent asks for it. The app turns this into a `Transition` on the beat grid.
public struct MixRequest: Equatable, Sendable {
    public enum Start: Equatable, Sendable {
        case nextBar
        case nextPhrase
        /// At the bar nearest after this many seconds into the outgoing track.
        case time(Double)
        case barsFromNow(Int)
    }

    /// The track to bring in, or nil to use what is already on the other deck.
    public var trackID: Int64?
    public var style: Transition.Style = .bassSwap
    public var beats = 32.0
    public var start = Start.nextPhrase
    /// Where in the incoming track to start, in seconds; nil for its suggested mix-in point.
    public var incomingSeconds: Double?
    public var keepTempo = false

    public init(trackID: Int64? = nil) { self.trackID = trackID }
}

/// What the agent needs from the decks. The app implements this; tests use a stub.
public protocol MixControl: Sendable {
    func deckStatus() async -> JSON
    /// Loads a track on a deck (nil: whichever is free) without starting it.
    func load(trackID: Int64, deck: DeckID?) async throws -> JSON
    func control(deck: DeckID, settings: [String: JSON]) async throws -> JSON
    func structure(trackID: Int64) async throws -> JSON
    func transition(_ request: MixRequest) async throws -> JSON
    func cancelTransition() async -> JSON
    func startAutomix(trackIDs: [Int64], notes: String?) async throws -> JSON
    func stopAutomix() async -> JSON
    func record(_ on: Bool) async throws -> JSON
}

public enum DeckTools {
    static func deck(_ args: JSON, required: Bool = true) throws -> DeckID? {
        guard let name = args["deck"]?.stringValue else {
            if required { throw ToolError("Say which deck: \"A\" or \"B\".") }
            return nil
        }
        switch name.uppercased() {
        case "A": return .a
        case "B": return .b
        default: throw ToolError("Decks are \"A\" and \"B\".")
        }
    }

    /// Seconds from a number, or from text like "4:32".
    static func seconds(_ value: JSON?) -> Double? {
        if let number = value?.doubleValue { return number }
        guard let text = value?.stringValue else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == text.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    public static func register(into registry: ToolRegistry, context: LibraryToolContext, mix: MixControl) {
        registry.register(AgentTool(
            name: "deck_status",
            description: """
                The two decks and the mixer: what is loaded, where each deck is, tempo, sync, EQ and faders, any mix \
                in progress, and whether the auto DJ is on. Check this before mixing.
                """,
            readOnly: true
        ) { _ in
            await mix.deckStatus()
        })

        registry.register(AgentTool(
            name: "deck_load",
            description: """
                Put a local track on a deck, stopped at its first bar, ready to mix. Does not interrupt the other \
                deck. Leave out "deck" to use whichever is free. Spotify and TIDAL tracks cannot go on a deck.
                """,
            properties: [
                "track": ["type": ["integer", "string"], "description": "A library track id."],
                "deck": Schema.choice("Which deck.", ["A", "B"]),
            ],
            required: ["track"]
        ) { args in
            guard let track = args["track"] else { throw ToolError("Give the track to load.") }
            let id = try context.resolve(.array([track]))[0]
            return try await mix.load(trackID: id, deck: try deck(args, required: false))
        })

        registry.register(AgentTool(
            name: "deck_control",
            description: """
                Work one deck by hand. Give only the settings you want to change. For bringing a track in over \
                several bars use mix_transition instead: it moves the controls on the beat, which you cannot.
                """,
            properties: [
                "deck": Schema.choice("Which deck.", ["A", "B"]),
                "action": Schema.choice(
                    "play: start (on the other deck's beat if sync is on). pause: stop. cue: back to the cue point and stop.",
                    ["play", "pause", "cue"]),
                "seek_seconds": Schema.number("Jump to this many seconds into the track."),
                "tempo_percent": Schema.number("Tempo fader, -16 to 16. Turns sync off for this deck."),
                "sync": Schema.boolean("Follow the other deck's tempo and beat."),
                "key_lock": Schema.boolean("Keep the pitch when the tempo changes. Off (varispeed) sounds cleaner."),
                "eq_low": Schema.number("Bass: -1 removes it, 0 is flat, 1 is +6 dB."),
                "eq_mid": Schema.number("Mids: -1 removes them, 0 is flat, 1 is +6 dB."),
                "eq_high": Schema.number("Highs: -1 removes them, 0 is flat, 1 is +6 dB."),
                "filter": Schema.number("-1 to 0 closes a low-pass, 0 is off, 0 to 1 closes a high-pass."),
                "fader": Schema.number("Channel volume, 0 to 1."),
                "loop_beats": Schema.number("Loop this many beats from the current beat. 0 ends the loop."),
                "echo": Schema.boolean("Beat-timed echo on or off."),
                "effect": Schema.choice(
                    "A one-off move: echo_out (drops away on the next beat and echoes out), cut_echo (silences the echo tail), tape_stop, rewind.",
                    ["echo_out", "cut_echo", "tape_stop", "rewind"]),
            ],
            required: ["deck"]
        ) { args in
            guard let which = try deck(args), case .object(var settings) = args else { throw ToolError("Say which deck.") }
            settings["deck"] = nil
            guard !settings.isEmpty else { throw ToolError("Give at least one setting to change.") }
            return try await mix.control(deck: which, settings: settings)
        })

        registry.register(AgentTool(
            name: "track_structure",
            description: """
                A track's shape in 8-bar phrases: where the bass comes in and leaves, breakdowns, and suggested \
                points to mix in and out. Use it to choose where a mix should start. Needs an analysed local track.
                """,
            properties: ["track": ["type": ["integer", "string"], "description": "A library track id."]],
            required: ["track"],
            readOnly: true
        ) { args in
            guard let track = args["track"] else { throw ToolError("Give the track.") }
            return try await mix.structure(trackID: try context.resolve(.array([track]))[0])
        })

        registry.register(AgentTool(
            name: "mix_transition",
            description: """
                Mix out of the deck that is playing into another track. Crate starts the new track exactly on the \
                beat, keeps the two in time and moves faders and EQ as the bars go by; you only choose what and \
                when. It returns at once with when the mix will start. Styles: bass_swap (new track enters without \
                bass, the bass changes hands halfway: the safe default), blend (plain crossfade), filter (as \
                bass_swap with the old track filtered away), echo_out (old track echoes out on one beat), cut (hard \
                switch on the beat), tape_stop (old track slows to a stop, new one starts a bar later).
                """,
            properties: [
                "track": ["type": ["integer", "string"], "description": "The track to bring in. Leave out to use the one already on the other deck."],
                "style": Schema.choice("How to mix. Default bass_swap.", Transition.Style.allCases.map(\.rawValue)),
                "beats": Schema.integer("Length of the mix in beats: 16, 32 or 64 are usual. Default 32. Ignored for cut and tape_stop."),
                "start": Schema.choice(
                    "When to start, if start_at is not given. next_phrase (default) waits for the next 8-bar boundary; next_bar is the next bar.",
                    ["next_phrase", "next_bar"]),
                "start_at": ["type": ["number", "string"], "description": "Start at this point in the playing track, as seconds or \"m:ss\". Moved to the next bar line."],
                "start_in_bars": Schema.integer("Start this many bars from now."),
                "incoming_from": ["type": ["number", "string"], "description": "Where in the new track to start it, as seconds or \"m:ss\". Default: its suggested mix-in point."],
                "keep_tempo": Schema.boolean("True: the new track stays at the old track's tempo. False (default): it eases back to its own tempo after the mix."),
            ]
        ) { args in
            var request = MixRequest()
            if let track = args["track"] { request.trackID = try context.resolve(.array([track]))[0] }
            if let style = args["style"]?.stringValue {
                guard let parsed = Transition.Style(rawValue: style) else {
                    throw ToolError("Unknown style \"\(style)\". Use one of: \(Transition.Style.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                request.style = parsed
            }
            if let beats = try args.optionalDouble("beats") {
                guard beats >= 1, beats <= 256 else { throw ToolError("\"beats\" must be between 1 and 256.") }
                request.beats = beats
            }
            if let at = args["start_at"] {
                guard let time = seconds(at), time >= 0 else { throw ToolError("\"start_at\" must be seconds or \"m:ss\".") }
                request.start = .time(time)
            } else if let bars = try args.optionalDouble("start_in_bars") {
                request.start = .barsFromNow(max(0, Int(bars)))
            } else if args["start"]?.stringValue == "next_bar" {
                request.start = .nextBar
            }
            if let from = args["incoming_from"] {
                guard let time = seconds(from), time >= 0 else { throw ToolError("\"incoming_from\" must be seconds or \"m:ss\".") }
                request.incomingSeconds = time
            }
            request.keepTempo = args["keep_tempo"]?.boolValue ?? false
            return try await mix.transition(request)
        })

        registry.register(AgentTool(
            name: "mix_cancel",
            description: "Stop a mix that is scheduled or under way. The controls stay where they are."
        ) { _ in
            await mix.cancelTransition()
        })

        registry.register(AgentTool(
            name: "automix_start",
            description: """
                Start the auto DJ on a list of local tracks. If nothing is playing the first one starts now. Before \
                each track runs out Crate asks you to pick the next one and schedule the mix with mix_transition; \
                if you do not answer in time it mixes in the next track in order itself.
                """,
            properties: [
                "tracks": Schema.trackRefs("The set, in a sensible playing order."),
                "notes": Schema.string("What the DJ asked for in this set, to remind you each time you are asked for the next mix."),
            ],
            required: ["tracks"]
        ) { args in
            try await mix.startAutomix(trackIDs: try context.resolve(args["tracks"]), notes: args["notes"]?.stringValue)
        })

        registry.register(AgentTool(
            name: "automix_stop",
            description: "Turn the auto DJ off. The music keeps playing; the tracks stay queued."
        ) { _ in
            await mix.stopAutomix()
        })

        registry.register(AgentTool(
            name: "mix_record",
            description: "Start or stop recording the mixer's output to a WAV file in the Music folder.",
            properties: ["on": Schema.boolean("True to start, false to stop.")],
            required: ["on"]
        ) { args in
            guard let on = args["on"]?.boolValue else { throw ToolError("\"on\" must be true or false.") }
            return try await mix.record(on)
        })
    }
}
