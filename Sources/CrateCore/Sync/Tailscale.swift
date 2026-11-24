import Foundation

/// Finds the user's other Macs through Tailscale, which they already run to join
/// their machines into one private network.
public enum Tailscale {
    static let commandPaths = [
        "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Addresses of the Macs on the tailnet that are online now. Empty when Tailscale is absent or stopped.
    public static func onlineMacs() -> [String] {
        guard let command = commandPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // The command answers at once; if it ever hangs, it is stopped rather than waited on.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return macs(inStatus: data)
    }

    /// Picks the online Macs out of `tailscale status --json`: each one's first IPv4 address.
    static func macs(inStatus data: Data) -> [String] {
        guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = status["Peer"] as? [String: Any]
        else { return [] }
        return peers.values.compactMap { value -> String? in
            guard let peer = value as? [String: Any], peer["OS"] as? String == "macOS", peer["Online"] as? Bool == true,
                  let addresses = peer["TailscaleIPs"] as? [String]
            else { return nil }
            return addresses.first { !$0.contains(":") } ?? addresses.first
        }.sorted()
    }
}
