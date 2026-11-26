import Foundation

/// The agent's view of the mix history: what was played, when, and what went into what.
public enum HistoryTools {
    public static func register(into registry: ToolRegistry, context: LibraryToolContext) {
        let store = context.store

        @Sendable func time(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }

        registry.register(AgentTool(
            name: "mix_history",
            description: """
                What has been played on the decks. A track is in the history once it has been in the mix for \
                half a minute. Without `track`: the latest sessions, each with its tracks in the order played; \
                `mixed_from` is the track that was playing as it came in, absent for a track started cold. With \
                `track`: every time that track was played, with what was played before and after it, which says \
                what it has been mixed with. Use it for "what did I play", "make a crate of last night's set", \
                or to prefer (or avoid repeating) combinations that have been played before.
                """,
            properties: [
                "track": ["type": ["integer", "string"], "description": "A library track id, to ask about one track."],
                "sessions": ["type": "integer", "description": "How many sessions to give, latest first. Default 3, at most 20."],
            ],
            readOnly: true
        ) { args in
            let sessions = try store.mixSessions()
            var tracks: [Int64: Track] = [:]
            func track(_ id: Int64) -> Track? {
                if let known = tracks[id] { return known }
                let found = try? store.track(id: id)
                tracks[id] = found
                return found
            }
            func brief(_ id: Int64?) -> JSON {
                guard let id, let track = track(id) else { return .null }
                return ["id": .number(Double(track.id)), "title": .string(track.title), "artist": .string(track.artist)]
            }

            if let ref = args["track"], ref != .null {
                let id = try context.resolve(.array([ref]))[0]
                guard let wanted = try store.track(id: id) else { throw ToolError("There is no track with id \(id).") }
                var plays: [JSON] = []
                for session in sessions {
                    for (index, play) in session.plays.enumerated() where play.trackID == id {
                        var entry: [String: JSON] = ["played": .string(time(play.playedAt)), "deck": .string(play.deck)]
                        if index > 0 { entry["before"] = brief(session.plays[index - 1].trackID) }
                        if index + 1 < session.plays.count { entry["after"] = brief(session.plays[index + 1].trackID) }
                        if let from = play.fromTrackID { entry["mixed_from"] = brief(from) }
                        if index + 1 < session.plays.count, session.plays[index + 1].fromTrackID == id {
                            entry["mixed_into"] = brief(session.plays[index + 1].trackID)
                        }
                        plays.append(.object(entry))
                    }
                }
                return ["track": TrackFormat.json(wanted), "times_played": .number(Double(plays.count)), "plays": .array(plays)]
            }

            let wanted = max(1, min(20, args["sessions"]?.intValue ?? 3))
            let shown = sessions.prefix(wanted).map { session -> JSON in
                [
                    "started": .string(time(session.startedAt)),
                    "tracks": .array(session.plays.map { play in
                        var entry: [String: JSON] = ["played": .string(time(play.playedAt))]
                        if let track = track(play.trackID) {
                            entry["track"] = TrackFormat.json(track)
                        }
                        if let from = play.fromTrackID { entry["mixed_from"] = .number(Double(from)) }
                        return .object(entry)
                    }),
                ]
            }
            return ["sessions_in_all": .number(Double(sessions.count)), "sessions": .array(Array(shown))]
        })
    }
}
