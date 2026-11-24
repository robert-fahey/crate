import Foundation

/// One Mac's end of a standing connection to another: says hello, sends its manifest,
/// asks for what the other has newer, answers what it is asked, and serves files.
public final class SyncSession: @unchecked Sendable {
    public static let protocolVersion = 1

    private let store: LibraryStore
    private let channel: PeerChannel
    private let purpose: String
    private let port: Int
    private let lock = NSLock()
    private var lastManifest: SyncManifest?
    private var theirManifest: SyncManifest?
    private var theirs: (device: DeviceInfo, port: Int, purpose: String)?
    private var handled = 0

    /// How many messages from the other Mac have been dealt with; when it stops rising, the two have settled.
    public var messagesHandled: Int { lock.withLock { handled } }

    /// The Mac at the other end, once it has said hello.
    public var peer: DeviceInfo? { lock.withLock { theirs?.device } }
    /// Where the other Mac listens, for calling it back to fetch a file.
    public var peerPort: Int? { lock.withLock { theirs?.port } }
    /// Called when the other Mac has said who it is. Returning false ends the connection (it is a second line to a Mac already connected).
    /// The second argument is what the other Mac wants the connection for: "sync" or "file".
    public var onHello: ((DeviceInfo, String) -> Bool)?

    /// - Parameter purpose: "sync" to keep the libraries in line, "file" for a connection that only fetches a file.
    public init(store: LibraryStore, channel: PeerChannel, purpose: String = "sync", port: Int = 0) {
        self.store = store
        self.channel = channel
        self.purpose = purpose
        self.port = port
    }

    /// Exchanges hellos. Throws if the other end is not a Crate this one can talk to.
    @discardableResult
    public func greet() async throws -> DeviceInfo {
        try await channel.send(.hello(store.device, version: Self.protocolVersion, purpose: purpose, port: port))
        guard case .hello(let device, let version, let theirPurpose, let theirPort) = try await channel.receive() else { throw ChannelError.malformed }
        guard version == Self.protocolVersion else {
            throw ChannelError.refused("\(device.name) runs a different version of Crate. Update both Macs to the same one.")
        }
        guard device.id != store.deviceID else { throw ChannelError.refused("That address is this Mac.") }
        lock.withLock { theirs = (device, theirPort, theirPurpose) }
        if onHello?(device, theirPurpose) == false { throw ChannelError.refused("Already connected to \(device.name).") }
        return device
    }

    /// Runs until the connection closes: greets, then answers and asks in turn.
    public func run() async throws {
        defer { channel.close() }
        if peer == nil { try await greet() }
        let wantsSync = purpose == "sync" && lock.withLock { theirs?.purpose } == "sync"
        if wantsSync { try await announce() }
        while true {
            let message = try await channel.receive()
            defer { lock.withLock { handled += 1 } }
            switch message {
            case .manifest(let manifest):
                lock.withLock { theirManifest = manifest }
                let wants = try store.absorb(manifest)
                if !wants.isEmpty { try await channel.send(.wants(wants)) }
            case .wants(let wants):
                try await answer(wants)
            case .records(let tracks, let crates, let analysis):
                try store.apply(tracks: tracks)
                try store.apply(analysis: analysis)
                if let peer { try store.apply(crates: crates, from: peer.id) }
                // What was just taken in is news to the other Mac too: it now knows the two agree.
                if wantsSync, !crates.isEmpty || !tracks.isEmpty { try await announce() }
            case .fileRequest(let key, let offset):
                try await FileTransfer.serve(key: key, offset: offset, store: store, channel: channel)
            case .failure(let reason):
                throw ChannelError.refused(reason)
            case .hello, .fileStart, .fileData, .fileEnd:
                throw ChannelError.malformed
            }
        }
    }

    /// Sends this Mac's manifest, unless it is what the other Mac was last sent.
    public func announce() async throws {
        let manifest = try store.syncManifest()
        let isNews = lock.withLock { () -> Bool in
            guard manifest != lastManifest else { return false }
            lastManifest = manifest
            return true
        }
        if isNews { try await channel.send(.manifest(manifest)) }
    }

    /// Looks again at what the other Mac last said it has, after something here changed what
    /// is worth asking for (a file arriving makes its waveforms worth having).
    public func reconsider() async throws {
        guard let manifest = lock.withLock({ theirManifest }) else { return }
        let wants = try store.absorb(manifest)
        if !wants.isEmpty { try await channel.send(.wants(wants)) }
    }

    /// Tracks go first, so that by the time a crate arrives the tracks it lists are known.
    private func answer(_ wants: SyncWants) async throws {
        for chunk in wants.tracks.chunked(50) {
            try await channel.send(.records(tracks: try store.trackRecords(keys: chunk), crates: [], analysis: []))
        }
        for chunk in wants.analysis.chunked(8) {
            try await channel.send(.records(tracks: [], crates: [], analysis: try store.analysisRecords(keys: chunk)))
        }
        for chunk in wants.crates.chunked(20) {
            try await channel.send(.records(tracks: [], crates: try store.crateRecords(uids: chunk), analysis: []))
        }
    }

    public func close() { channel.close() }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min(count, $0 + size)]) }
    }
}
