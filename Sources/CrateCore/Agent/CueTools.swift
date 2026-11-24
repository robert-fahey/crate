import Foundation

/// The agent's hold on cue points and saved loops.
public enum CueTools {
    static func bar(of seconds: Double, in grid: BeatGrid) -> Int {
        Int(((grid.beatPosition(at: seconds) - Double(grid.downbeat)) / Double(BeatGrid.beatsPerBar)).rounded(.down)) + 1
    }

    static func json(_ cue: CuePoint, grid: BeatGrid?) -> JSON {
        var object: [String: JSON] = [
            "pad": .number(Double(cue.slot)), "at": .string(TrackFormat.duration(cue.position)),
            "seconds": .number((cue.position * 100).rounded() / 100),
        ]
        if !cue.name.isEmpty { object["name"] = .string(cue.name) }
        if let grid {
            object["bar"] = .number(Double(bar(of: cue.position, in: grid)))
            if let end = cue.loopEnd {
                object["loop_beats"] = .number((grid.beatPosition(at: end) - grid.beatPosition(at: cue.position)).rounded())
            }
        } else if let end = cue.loopEnd {
            object["loop_seconds"] = .number(((end - cue.position) * 100).rounded() / 100)
        }
        return .object(object)
    }

    /// Crate's own idea of a track's cues, when the track has been analysed.
    public static func suggestions(for track: Track, store: LibraryStore) throws -> (cues: [CuePoint], grid: BeatGrid)? {
        guard let grid = try store.beatGrid(id: track.id), let detail = try store.waveDetail(id: track.id) else { return nil }
        let structure = TrackStructure.analyse(detail: detail, grid: grid, duration: track.duration)
        return (CueSuggester.suggest(structure: structure, grid: grid), grid)
    }

    public static func register(into registry: ToolRegistry, context: LibraryToolContext) {
        let store = context.store

        @Sendable func track(_ args: JSON) throws -> Track {
            guard let ref = args["track"] else { throw ToolError("Give the track.") }
            let id = try context.resolve(.array([ref]))[0]
            guard let track = try store.track(id: id) else { throw ToolError("There is no track with id \(id).") }
            return track
        }

        registry.register(AgentTool(
            name: "cue_points",
            description: """
                A track's hot cues and saved loops (eight pads), which pads are free, and the cues and loops Crate \
                would suggest from the track's shape. Use `track_structure` as well when you want to choose your own.
                """,
            properties: ["track": ["type": ["integer", "string"], "description": "A library track id."]],
            required: ["track"],
            readOnly: true
        ) { args in
            let track = try track(args)
            let cues = try store.cuePoints(id: track.id)
            let grid = try store.beatGrid(id: track.id)
            var result: [String: JSON] = [
                "track": TrackFormat.json(track),
                "cues": .array(cues.map { json($0, grid: grid) }),
                "free_pads": .array(CuePoint.slots.filter { slot in !cues.contains { $0.slot == slot } }.map { .number(Double($0)) }),
            ]
            if let suggested = try suggestions(for: track, store: store) {
                result["suggested"] = .array(suggested.cues.map { json($0, grid: suggested.grid) })
            } else {
                result["note"] = "This track has no beat grid yet, so Crate has nothing to suggest and cues will not snap to beats."
            }
            return .object(result)
        })

        registry.register(AgentTool(
            name: "cue_set",
            description: """
                Set hot cues and saved loops on a track. Each lands on the nearest beat. A cue with `loop_beats` is a \
                saved loop: its pad jumps there and loops that many beats. Give `pad` to choose the pad (1 to 8, \
                replacing what is on it), or leave it out to use the next free one. Names are a word or two: \
                "Drop", "Break", "Vocal in". With `replace_all` the track's other cues are removed first.
                """,
            properties: [
                "track": ["type": ["integer", "string"], "description": "A library track id."],
                "cues": [
                    "type": "array",
                    "description": "The cues to set.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "at": ["type": ["number", "string"], "description": "Where, as seconds or \"m:ss\"."],
                            "name": Schema.string("A word or two."),
                            "pad": Schema.integer("1 to 8. Left out: the next free pad."),
                            "loop_beats": Schema.number("For a saved loop: how many beats it goes round (4, 8, 16, 32)."),
                        ],
                        "required": ["at"],
                    ],
                ],
                "replace_all": Schema.boolean("Remove the track's other cues first. Default false."),
            ],
            required: ["track", "cues"]
        ) { args in
            let track = try track(args)
            guard let items = args["cues"]?.arrayValue, !items.isEmpty else { throw ToolError("Give at least one cue.") }
            let grid = try store.beatGrid(id: track.id)
            var cues = args["replace_all"]?.boolValue == true ? [] : try store.cuePoints(id: track.id)
            var written: [CuePoint] = []
            for item in items {
                guard var seconds = DeckTools.seconds(item["at"]), seconds >= 0, seconds < max(track.duration, 1) else {
                    throw ToolError("\"at\" must be a time inside the track (it is \(TrackFormat.duration(track.duration)) long), as seconds or \"m:ss\".")
                }
                if let grid { seconds = max(0, grid.nearestBeat(to: seconds)) }
                var end: Double?
                if let beats = item["loop_beats"]?.doubleValue {
                    guard beats > 0, beats <= 128 else { throw ToolError("\"loop_beats\" must be between a fraction of a beat and 128.") }
                    guard let grid else { throw ToolError("\"\(track.title)\" has no beat grid, so a loop cannot be measured in beats.") }
                    end = grid.time(atBeat: grid.beatPosition(at: seconds) + beats)
                }
                let slot: Int
                if let pad = item["pad"]?.intValue {
                    guard CuePoint.slots.contains(Int(pad)) else { throw ToolError("\"pad\" must be 1 to 8.") }
                    slot = Int(pad)
                } else if let free = CuePoint.slots.first(where: { slot in !cues.contains { $0.slot == slot } }) {
                    slot = free
                } else {
                    throw ToolError("All eight pads are in use. Give \"pad\" to replace one, or clear some with cue_clear.")
                }
                let cue = CuePoint(slot: slot, position: seconds, name: String((item["name"]?.stringValue ?? "").prefix(24)), loopEnd: end)
                cues.removeAll { $0.slot == slot }
                cues.append(cue)
                written.append(cue)
            }
            try store.setCuePoints(id: track.id, cues)
            return [
                "track": .string(track.title), "set": .array(written.map { json($0, grid: grid) }),
                "pads_in_use": .number(Double(cues.count)),
            ]
        })

        registry.register(AgentTool(
            name: "cue_clear",
            description: "Remove hot cues or saved loops from a track: the pads given, or all of them if none are given.",
            properties: [
                "track": ["type": ["integer", "string"], "description": "A library track id."],
                "pads": ["type": "array", "items": ["type": "integer"], "description": "Pads to clear, 1 to 8. Left out: all."],
            ],
            required: ["track"]
        ) { args in
            let track = try track(args)
            let before = try store.cuePoints(id: track.id)
            let pads = Set((args["pads"]?.arrayValue ?? []).compactMap { item -> Int? in item.intValue.map { Int($0) } })
            let after = pads.isEmpty ? [] : before.filter { !pads.contains($0.slot) }
            try store.setCuePoints(id: track.id, after)
            return ["track": .string(track.title), "removed": .number(Double(before.count - after.count))]
        })
    }
}
