import Foundation

/// What the agent needs from the player. The app implements this; tests use a stub.
public protocol PlayerControl: Sendable {
    /// Replaces the queue with these tracks and starts the first. Returns the player status.
    func play(trackIDs: [Int64]) async throws -> JSON
    /// Appends to the queue without interrupting what is playing.
    func enqueue(trackIDs: [Int64]) async throws -> JSON
    func pause() async throws -> JSON
    func resume() async throws -> JSON
    func next() async throws -> JSON
    func seek(toSeconds seconds: Double) async throws -> JSON
    func status() async -> JSON
}

public enum PlayerTools {
    public static func register(into registry: ToolRegistry, context: LibraryToolContext, player: PlayerControl) {
        registry.register(AgentTool(
            name: "player_play",
            description: """
                Play tracks now, replacing the current queue. The first track starts immediately and the rest \
                follow in order. Local files play in Crate; Spotify and TIDAL tracks play in their own apps.
                """,
            properties: ["tracks": Schema.trackRefs("Tracks to play, in order.")],
            required: ["tracks"]
        ) { args in
            try await player.play(trackIDs: try context.resolve(args["tracks"]))
        })

        registry.register(AgentTool(
            name: "player_queue_add",
            description: "Add tracks to the end of the play queue without interrupting the current track.",
            properties: ["tracks": Schema.trackRefs("Tracks to queue, in order.")],
            required: ["tracks"]
        ) { args in
            try await player.enqueue(trackIDs: try context.resolve(args["tracks"]))
        })

        registry.register(AgentTool(name: "player_pause", description: "Pause playback.") { _ in
            try await player.pause()
        })

        registry.register(AgentTool(name: "player_resume", description: "Resume the paused track.") { _ in
            try await player.resume()
        })

        registry.register(AgentTool(name: "player_next", description: "Skip to the next track in the queue.") { _ in
            try await player.next()
        })

        registry.register(AgentTool(
            name: "player_seek",
            description: "Jump to a position in the current track. Not available for TIDAL tracks.",
            properties: ["seconds": Schema.number("Position from the start of the track, in seconds.")],
            required: ["seconds"]
        ) { args in
            guard let seconds = try args.optionalDouble("seconds"), seconds >= 0 else {
                throw ToolError("\"seconds\" must be zero or more.")
            }
            return try await player.seek(toSeconds: seconds)
        })

        registry.register(AgentTool(
            name: "player_status",
            description: "What is playing now, the position in it, and what is queued next.",
            readOnly: true
        ) { _ in
            await player.status()
        })
    }
}
