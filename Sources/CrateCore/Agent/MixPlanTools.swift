import Foundation

/// The agent's hold on a crate's mix: the transition kept for each pair of neighbouring tracks.
public enum MixPlanTools {
    static func json(_ step: MixStep, titles: [Int64: String]) -> JSON {
        var object: [String: JSON] = [
            "from": .number(Double(step.from)), "to": .number(Double(step.to)),
            "style": .string(step.style.rawValue),
            "out_at": .string(TrackFormat.duration(step.outAt)), "out_seconds": .number((step.outAt * 10).rounded() / 10),
            "in_at": .string(TrackFormat.duration(step.inAt)), "in_seconds": .number((step.inAt * 10).rounded() / 10),
        ]
        if let from = titles[step.from], let to = titles[step.to] { object["tracks"] = .string("\(from) → \(to)") }
        if step.style.overlaps { object["beats"] = .number(step.beats) }
        if !step.note.isEmpty { object["note"] = .string(step.note) }
        return .object(object)
    }

    public static func register(into registry: ToolRegistry, context: LibraryToolContext) {
        let store = context.store

        registry.register(AgentTool(
            name: "mix_plan",
            description: """
                A crate as a mix: its tracks in order and, for each track going into the next, the transition that \
                is saved for it (who set it, style, where the first track is left and where the next comes in) or, \
                where none is saved, the one Crate would use. The DJ sees and edits the same thing in the mix editor.
                """,
            properties: ["crate": Schema.string("Crate name.")],
            required: ["crate"],
            readOnly: true
        ) { args in
            let crate = try context.crate(args)
            let tracks = try store.tracks(inCrate: crate.id)
            let saved = try store.mixSteps(crate: crate.id)
            let titles = Dictionary(tracks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            let sides = tracks.map { MixSide(track: $0, store: store) }
            var transitions: [JSON] = []
            for (from, to) in zip(sides, sides.dropFirst()) {
                if let step = saved.first(where: { $0.from == from.track.id && $0.to == to.track.id }) {
                    guard case .object(var object) = json(step, titles: titles) else { continue }
                    object["saved"] = true
                    object["set_by"] = .string(step.author == .you ? "the DJ" : step.author.rawValue)
                    transitions.append(.object(object))
                } else {
                    guard case .object(var object) = json(MixPlanner.suggest(from: from, to: to), titles: titles) else { continue }
                    object["saved"] = false
                    transitions.append(.object(object))
                }
            }
            return [
                "crate": .string(crate.name),
                "tracks": .array(tracks.map(TrackFormat.json)),
                "transitions": .array(transitions),
                "length_as_a_mix": .string(TrackFormat.duration(MixPlanner.length(of: tracks, steps: saved))),
            ]
        })

        registry.register(AgentTool(
            name: "mix_plan_set",
            description: """
                Save transitions for a crate's mix. Each says how one track goes into another: the style, how many \
                beats the two overlap, where the first track is left (`out_at`) and where the second comes in from \
                (`in_at`). Anything left out keeps what is saved, or takes Crate's suggestion. Times land on the \
                nearest bar line. Styles: bass_swap, blend, filter, echo_out, cut, tape_stop. The DJ can change any \
                of it in the mix editor, and "Play Mix" plays the crate this way.
                """,
            properties: [
                "crate": Schema.string("Crate name."),
                "transitions": [
                    "type": "array",
                    "description": "One for each pair of neighbouring tracks being set.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "from": ["type": ["integer", "string"], "description": "The outgoing track's id."],
                            "to": ["type": ["integer", "string"], "description": "The incoming track's id."],
                            "style": Schema.choice("How to mix.", Transition.Style.allCases.map(\.rawValue)),
                            "beats": Schema.number("How long the two overlap: 8, 16, 32 or 64. Ignored for echo_out, cut and tape_stop."),
                            "out_at": ["type": ["number", "string"], "description": "Where in the outgoing track the mix starts, as seconds or \"m:ss\"."],
                            "in_at": ["type": ["number", "string"], "description": "Where in the incoming track it comes in from, as seconds or \"m:ss\"."],
                            "note": Schema.string("Why, in a few words, for the DJ to read."),
                        ],
                        "required": ["from", "to"],
                    ],
                ],
            ],
            required: ["crate", "transitions"]
        ) { args in
            let crate = try context.crate(args)
            guard let items = args["transitions"]?.arrayValue, !items.isEmpty else { throw ToolError("Give at least one transition.") }
            let tracks = try store.tracks(inCrate: crate.id)
            let titles = Dictionary(tracks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            let saved = try store.mixSteps(crate: crate.id)
            var steps: [MixStep] = [], notes: [String] = []
            for item in items {
                let ids = try context.resolve(.array([item["from"] ?? .null, item["to"] ?? .null]))
                guard ids.count == 2, let fromIndex = tracks.firstIndex(where: { $0.id == ids[0] }), let toIndex = tracks.firstIndex(where: { $0.id == ids[1] }) else {
                    throw ToolError("Both tracks of a transition must be in \"\(crate.name)\". Look at mix_plan for its tracks.")
                }
                let from = MixSide(track: tracks[fromIndex], store: store), to = MixSide(track: tracks[toIndex], store: store)
                if toIndex != fromIndex + 1 {
                    notes.append("\(from.track.title) is not followed by \(to.track.title) in the crate as it is ordered now, so that transition will not be used until it is.")
                }
                var step = saved.first { $0.from == ids[0] && $0.to == ids[1] } ?? MixPlanner.suggest(from: from, to: to)
                if let text = item["style"]?.stringValue {
                    guard let style = Transition.Style(rawValue: text) else {
                        throw ToolError("\"\(text)\" is not a style. Use one of: \(Transition.Style.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    step.style = style
                }
                if let beats = item["beats"]?.doubleValue {
                    guard beats >= 4, beats <= 128 else { throw ToolError("\"beats\" must be between 4 and 128.") }
                    step.beats = beats
                }
                if let value = item["out_at"] {
                    guard let seconds = DeckTools.seconds(value), seconds >= 0, seconds < from.track.duration else {
                        throw ToolError("\"out_at\" must be a time inside \(from.track.title) (\(TrackFormat.duration(from.track.duration)) long).")
                    }
                    step.outAt = seconds
                }
                if let value = item["in_at"] {
                    guard let seconds = DeckTools.seconds(value), seconds >= 0, seconds < to.track.duration else {
                        throw ToolError("\"in_at\" must be a time inside \(to.track.title) (\(TrackFormat.duration(to.track.duration)) long).")
                    }
                    step.inAt = seconds
                }
                step.note = String((item["note"]?.stringValue ?? "").prefix(80))
                step.author = .agent
                let tidy = MixPlanner.tidied(step, from: from, to: to)
                if tidy.beats != step.beats, step.style.overlaps {
                    notes.append("\(from.track.title) → \(to.track.title): shortened to \(Int(tidy.beats)) beats to fit before the first track ends.")
                }
                steps.append(tidy)
            }
            try store.setMixSteps(crate: crate.id, steps)
            var result: [String: JSON] = ["crate": .string(crate.name), "saved": .array(steps.map { json($0, titles: titles) })]
            if !notes.isEmpty { result["notes"] = .array(notes.map(JSON.string)) }
            return .object(result)
        })

        registry.register(AgentTool(
            name: "mix_plan_clear",
            description: "Forget saved transitions of a crate's mix: every one, or those for the pairs given. Crate then decides those itself.",
            properties: [
                "crate": Schema.string("Crate name."),
                "pairs": [
                    "type": "array",
                    "description": "Left out: all of them.",
                    "items": ["type": "object", "properties": ["from": Schema.integer("Outgoing track id."), "to": Schema.integer("Incoming track id.")], "required": ["from", "to"]],
                ],
            ],
            required: ["crate"]
        ) { args in
            let crate = try context.crate(args)
            let before = try store.mixSteps(crate: crate.id).count
            if let pairs = args["pairs"]?.arrayValue, !pairs.isEmpty {
                var named: [(from: Int64, to: Int64)] = []
                for pair in pairs {
                    if let from = pair["from"]?.intValue, let to = pair["to"]?.intValue { named.append((from: Int64(from), to: Int64(to))) }
                }
                try store.removeMixSteps(crate: crate.id, pairs: named)
            } else {
                try store.removeMixSteps(crate: crate.id)
            }
            return ["crate": .string(crate.name), "removed": .number(Double(before - (try store.mixSteps(crate: crate.id).count)))]
        })
    }
}
