import AppKit
import AVFoundation
import CrateCore

/// One way of playing a track. Local files play in-process; streaming tracks
/// are played by remote-controlling the service's own app.
@MainActor
protocol PlaybackBackend: AnyObject {
    var canSeek: Bool { get }
    var canPause: Bool { get }
    func start(_ track: Track) throws
    func pause() throws
    func resume() throws
    func seek(to seconds: Double) throws
    func stop()
    /// Seconds into the track.
    var position: Double { get }
    /// True once the track has played to its end.
    var isFinished: Bool { get }
}

struct PlaybackError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Spotify (remote control of Spotify.app)

@MainActor
enum AppleScriptRunner {
    /// Runs a script and returns its result as text. The first use against an
    /// app makes macOS ask the user to allow Crate to control it.
    static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw PlaybackError("Could not build the script.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 {
                throw PlaybackError(
                    "macOS is blocking Crate from controlling that app. Allow it in System Settings > Privacy & Security > Automation.")
            }
            throw PlaybackError(error[NSAppleScript.errorMessage] as? String ?? "The app did not respond.")
        }
        return result.stringValue ?? ""
    }
}

@MainActor
final class SpotifyBackend: PlaybackBackend {
    private var uri = ""
    private var startedAt = Date()
    private var lastPolled = Date.distantPast
    private var polledPosition = 0.0
    private var polledAt = Date()
    private var playing = false
    private var finished = false
    private var duration = 0.0

    let canSeek = true
    let canPause = true

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    func start(_ track: Track) throws {
        guard Self.isInstalled else { throw PlaybackError("The Spotify app is not installed.") }
        _ = try AppleScriptRunner.run("tell application \"Spotify\" to play track \"\(track.uri)\"")
        uri = track.uri
        duration = track.duration
        startedAt = Date()
        polledPosition = 0
        polledAt = Date()
        playing = true
        finished = false
    }

    func pause() throws {
        _ = try AppleScriptRunner.run("tell application \"Spotify\" to pause")
        poll(force: true)
        playing = false
    }

    func resume() throws {
        _ = try AppleScriptRunner.run("tell application \"Spotify\" to play")
        playing = true
        polledAt = Date()
    }

    func seek(to seconds: Double) throws {
        _ = try AppleScriptRunner.run("tell application \"Spotify\" to set player position to \(seconds)")
        polledPosition = seconds
        polledAt = Date()
    }

    func stop() {
        guard playing else { return }
        _ = try? AppleScriptRunner.run("tell application \"Spotify\" to pause")
        playing = false
    }

    /// Asking Spotify costs a round trip, so ask once a second and interpolate between.
    private func poll(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPolled) >= 1 else { return }
        lastPolled = Date()
        let script = """
            tell application "Spotify"
                if it is running then
                    return (id of current track) & "|" & (player position as string) & "|" & (player state as string)
                end if
                return "||stopped"
            end tell
            """
        guard let reply = try? AppleScriptRunner.run(script) else { return }
        let parts = reply.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        let settled = Date().timeIntervalSince(startedAt) > 3
        if parts[0] != uri {
            // Spotify has moved on to something else: our track ended (or the user changed it there).
            if settled { finished = true }
            return
        }
        polledPosition = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? polledPosition
        polledAt = Date()
        if playing, settled, parts[2] != "playing", duration > 0, polledPosition < 1 || polledPosition >= duration - 2 {
            finished = true
        }
    }

    var position: Double {
        poll()
        return playing ? polledPosition + Date().timeIntervalSince(polledAt) : polledPosition
    }

    var isFinished: Bool {
        poll()
        return finished
    }
}

// MARK: - TIDAL (hands the track to TIDAL.app)

/// TIDAL's app has no scripting interface. Crate can ask it to play a track,
/// but cannot pause it, seek, or read its position; progress is timed locally.
@MainActor
final class TidalBackend: PlaybackBackend {
    private var startedAt: Date?
    private var duration = 0.0

    let canSeek = false
    let canPause = false

    func start(_ track: Track) throws {
        guard let id = track.uri.split(separator: ":").last, let url = URL(string: "tidal://track/\(id)") else {
            throw PlaybackError("That is not a TIDAL track.")
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw PlaybackError("The TIDAL app is not installed.")
        }
        guard NSWorkspace.shared.open(url) else { throw PlaybackError("Could not hand the track to the TIDAL app.") }
        startedAt = Date()
        duration = track.duration
    }

    func pause() throws { throw PlaybackError("Crate cannot pause TIDAL. Pause it in the TIDAL app.") }
    func resume() throws { throw PlaybackError("Crate cannot resume TIDAL. Press play in the TIDAL app.") }
    func seek(to seconds: Double) throws { throw PlaybackError("Crate cannot seek in TIDAL tracks.") }
    func stop() { startedAt = nil }

    var position: Double { startedAt.map { min(duration, Date().timeIntervalSince($0)) } ?? 0 }
    var isFinished: Bool {
        guard let startedAt, duration > 0 else { return false }
        return Date().timeIntervalSince(startedAt) >= duration
    }
}
