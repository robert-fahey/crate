import CrateCore
import Foundation
import Observation

/// Sharing the library with the user's other Macs, for the window: the settings,
/// which Macs are connected, and what is being fetched.
@MainActor
@Observable
final class SharingModel {
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private var service: SyncService?
    @ObservationIgnored private var notes: [String: @MainActor (String) -> Void] = [:]
    /// Test runs (two copies of Crate on one Mac) set these in the environment instead of in Settings.
    @ObservationIgnored private let environment = ProcessInfo.processInfo.environment

    private(set) var peers: [SyncService.Peer] = []
    private(set) var problem: String?
    /// Files on their way here: who from and how far along, by track identity.
    private(set) var fetching: [String: (from: String, fraction: Double)] = [:]
    /// The Macs that hold each track, by name; and the tracks a connected Mac can hand over now.
    private(set) var elsewhere: [String: [String]] = [:]
    private(set) var reachable = Set<String>()
    /// Called when what can be fetched changes, so the track list can redraw its marks.
    @ObservationIgnored var onChange: (() -> Void)?

    var isOn: Bool { didSet { if isOn != oldValue { save("sync.enabled", isOn ? "1" : nil); restart() } } }
    var usesTailscale: Bool { didSet { if usesTailscale != oldValue { save("sync.tailscale", usesTailscale ? nil : "0"); restart() } } }
    /// Other Macs' addresses typed in by hand, one per line.
    var addresses: String { didSet { if addresses != oldValue { save("sync.addresses", addresses.isEmpty ? nil : addresses); restart() } } }
    var musicFolder: String { didSet { if musicFolder != oldValue { save("sync.folder", musicFolder); restart() } } }
    private(set) var code: String

    init(store: LibraryStore, secrets: SecretStore) {
        self.store = store
        self.secrets = secrets
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["CRATE_SYNC_NAME"] { store.deviceName = name }
        code = environment["CRATE_SYNC_SECRET"] ?? secrets.secret("sync.secret") ?? ""
        isOn = environment["CRATE_SYNC_SECRET"] != nil || store.setting("sync.enabled") == "1"
        usesTailscale = environment["CRATE_SYNC_SECRET"] == nil && store.setting("sync.tailscale") != "0"
        addresses = environment["CRATE_SYNC_PEERS"] ?? store.setting("sync.addresses") ?? ""
        musicFolder = environment["CRATE_SYNC_FOLDER"] ?? store.setting("sync.folder") ?? (NSHomeDirectory() + "/Music/Crate")
        restart()
    }

    var deviceName: String {
        get { store.deviceName }
        set {
            store.deviceName = newValue
            restart()
        }
    }

    var port: Int { environment["CRATE_SYNC_PORT"].flatMap(Int.init) ?? SyncService.defaultPort }

    private func save(_ key: String, _ value: String?) { store.setSetting(key, value) }

    /// A fresh code, for the first Mac. Twelve letters and digits that are hard to confuse when typed across.
    func makeCode() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let letters = (0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        setCode(stride(from: 0, to: 12, by: 4).map { String(letters[$0..<$0 + 4]) }.joined(separator: "-"))
    }

    func setCode(_ value: String) {
        code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        secrets.setSecret("sync.secret", code.isEmpty ? nil : code)
        restart()
    }

    // MARK: The service

    private func restart() {
        service?.stop()
        service = nil
        peers = []
        problem = nil
        guard isOn, !code.isEmpty else { return refresh() }
        let service = SyncService(store: store, secret: code, port: port, musicFolder: URL(fileURLWithPath: (musicFolder as NSString).expandingTildeInPath))
        service.findsMacsWithTailscale = usesTailscale
        service.addresses = addresses.split(whereSeparator: \.isNewline).map(String.init)
        service.onChange = { [weak self, weak service] in
            Task { @MainActor in
                guard let self, let service, self.service === service else { return }
                self.peers = service.connected
                self.problem = service.problem
                self.refresh()
            }
        }
        service.onFetchProgress = { [weak self] key, from, fraction in
            Task { @MainActor in
                guard let self else { return }
                if let fraction {
                    self.fetching[key] = (from, fraction)
                    self.notes[key]?("Fetching from \(from)… \(Int(fraction * 100))%")
                } else {
                    self.fetching[key] = nil
                }
            }
        }
        self.service = service
        service.start()
        refresh()
    }

    /// Reads again which Macs hold what. Called when the library or the connections change.
    func refresh() {
        let connected = Set(peers.map(\.device.id))
        let held = (try? store.heldElsewhere()) ?? [:]
        var reachable = Set<String>()
        if !connected.isEmpty {
            for key in held.keys where ((try? store.holders(of: key)) ?? []).contains(where: connected.contains) { reachable.insert(key) }
        }
        let changed = held != elsewhere || reachable != self.reachable
        elsewhere = held
        self.reachable = reachable
        if changed { onChange?() }
    }

    /// The Mac to name for a track whose file is not on this one.
    func holder(of track: Track) -> String? {
        guard !track.isOnThisMac, let key = track.contentID else { return nil }
        return elsewhere[key]?.first
    }

    func canFetch(_ track: Track) -> Bool {
        guard let key = track.contentID else { return false }
        return reachable.contains(key)
    }

    struct SharingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Copies a track's file to this Mac and returns the track as it now is, with its file.
    /// - Parameter note: told how the copy is going, for showing where the track is headed.
    func fetch(_ track: Track, note: (@MainActor (String) -> Void)? = nil) async throws -> Track {
        guard let key = track.contentID else { throw SharingError(message: "\"\(track.title)\" has no file on this Mac.") }
        guard let service, canFetch(track) else {
            let name = holder(of: track)
            throw SharingError(message: name.map { "\"\(track.title)\" is on \($0), which is not connected right now." }
                ?? "The file for \"\(track.title)\" is not on this Mac, and no connected Mac has it.")
        }
        notes[key] = note
        defer { notes[key] = nil }
        note?("Fetching from \(holder(of: track) ?? "another Mac")…")
        _ = try await service.fetch(contentID: key)
        return try store.track(id: track.id) ?? track
    }
}
