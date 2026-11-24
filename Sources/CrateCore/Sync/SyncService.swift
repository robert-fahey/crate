import Foundation
import Network

/// Keeps this Mac's library in line with the user's other Macs: listens for them,
/// calls the ones it knows of, and fetches music files from them when asked.
public final class SyncService: @unchecked Sendable {
    public static let defaultPort = 47800

    public struct Peer: Equatable, Sendable {
        public var device: DeviceInfo
        public var host: String
        public var port: Int
    }

    private struct Line {
        let session: SyncSession
        let host: String
    }

    private let store: LibraryStore
    private let secret: String
    public let port: Int
    public let musicFolder: URL
    private let lock = NSLock()
    private var listener: NWListener?
    private var lines: [String: Line] = [:]
    /// Which Mac answered at each address tried, so an address is not called again while its Mac is connected.
    private var deviceAtAddress: [String: String] = [:]
    private var calling = Set<String>()
    private var fetches: [String: Task<String, Error>] = [:]
    private var failedFetches: [String: Double] = [:]
    private var manual: [String] = []
    private var tailscale = true
    private var loop: Task<Void, Never>?
    private var keeper: Task<Void, Never>?
    private var announcer: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var problemText: String?

    /// Called (on any thread) when the set of connected Macs, or the problem to show, changes.
    public var onChange: (@Sendable () -> Void)?
    /// Called as a file arrives: its track, the Mac it is coming from, and how far along it is (nil when done or failed).
    public var onFetchProgress: (@Sendable (_ contentID: String, _ from: String, _ fraction: Double?) -> Void)?

    public init(store: LibraryStore, secret: String, port: Int = SyncService.defaultPort, musicFolder: URL) {
        self.store = store
        self.secret = secret
        self.port = port
        self.musicFolder = musicFolder
    }

    deinit { stop() }

    /// Addresses typed in by hand ("macbook" or "100.64.0.2:47800"), tried as well as any Tailscale finds.
    public var addresses: [String] {
        get { lock.withLock { manual } }
        set { lock.withLock { manual = newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
    }

    public var findsMacsWithTailscale: Bool {
        get { lock.withLock { tailscale } }
        set { lock.withLock { tailscale = newValue } }
    }

    public var connected: [Peer] {
        lock.withLock {
            lines.compactMap { _, line in
                line.session.peer.map { Peer(device: $0, host: line.host, port: line.session.peerPort ?? Self.defaultPort) }
            }.sorted { $0.device.name < $1.device.name }
        }
    }

    /// Why sharing is not working, in words for the user; nil when all is well.
    public var problem: String? { lock.withLock { problemText } }

    private func setProblem(_ text: String?) {
        let isNews = lock.withLock { () -> Bool in
            defer { problemText = text }
            return problemText != text
        }
        if isNews { onChange?() }
    }

    // MARK: Starting and stopping

    public func start() {
        guard lock.withLock({ self.loop == nil }) else { return }
        do {
            let listener = try NWListener(using: NetworkChannel.parameters(secret: secret), on: NWEndpoint.Port(rawValue: UInt16(port))!)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.setProblem("Other Macs cannot reach this one: port \(self?.port ?? 0) could not be opened (\(error.localizedDescription)).")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                let channel = NetworkChannel(connection: connection)
                Task {
                    guard (try? await channel.open()) != nil else { return }
                    await self.talk(over: channel, host: channel.remoteHost ?? "", calledByUs: false, address: nil)
                }
            }
            listener.start(queue: DispatchQueue(label: "crate.sync.listener"))
            lock.withLock { self.listener = listener }
        } catch {
            setProblem("Other Macs cannot reach this one: \(error.localizedDescription)")
        }
        observer = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: store, queue: nil) { [weak self] _ in
            self?.announceSoon()
        }
        let rounds = Task { [weak self] in
            while !Task.isCancelled {
                await self?.callEveryone()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        lock.withLock { self.loop = rounds }
    }

    public func stop() {
        let (lines, listener, tasks) = lock.withLock { () -> ([Line], NWListener?, [Task<Void, Never>?]) in
            defer {
                self.lines = [:]
                self.listener = nil
                loop = nil
                keeper = nil
                announcer = nil
            }
            return (Array(self.lines.values), self.listener, [loop, keeper, announcer])
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        tasks.forEach { $0?.cancel() }
        listener?.cancel()
        lines.forEach { $0.session.close() }
    }

    // MARK: Connections

    /// Tries every address not already answered by a connected Mac, tells the connected ones
    /// of anything new (a drive plugged in changes what this Mac can hand over), and fetches
    /// what crates marked "keep on this Mac" still lack.
    private func callEveryone() async {
        var targets = addresses
        if findsMacsWithTailscale { targets += Tailscale.onlineMacs() }
        for address in Set(targets) {
            let skip = lock.withLock { () -> Bool in
                if let device = deviceAtAddress[address], lines[device] != nil { return true }
                return !calling.insert(address).inserted
            }
            if skip { continue }
            Task { [weak self] in
                await self?.call(address)
                self?.lock.withLock { _ = self?.calling.remove(address) }
            }
        }
        await announce()
        keepUp()
    }

    private func call(_ address: String) async {
        let parts = address.split(separator: ":")
        // "host", "host:port", or a bare IPv6 address (several colons, no port).
        let hasPort = parts.count == 2 && Int(parts[1]) != nil
        let host = hasPort ? String(parts[0]) : address
        let port = hasPort ? Int(parts[1]) ?? Self.defaultPort : Self.defaultPort
        guard let channel = try? await open(host: host, port: port) else { return }
        await talk(over: channel, host: host, calledByUs: true, address: address)
    }

    private func open(host: String, port: Int) async throws -> NetworkChannel {
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: NetworkChannel.parameters(secret: secret))
        let channel = NetworkChannel(connection: connection)
        try await channel.open()
        return channel
    }

    private func talk(over channel: NetworkChannel, host: String, calledByUs: Bool, address: String?) async {
        let session = SyncSession(store: store, channel: channel, purpose: "sync", port: port)
        var device: DeviceInfo?
        session.onHello = { [weak self] info, purpose in
            guard let self else { return false }
            device = info
            // A line that only fetches a file is served and forgotten.
            guard purpose == "sync" else { return true }
            return self.lock.withLock {
                if let address { self.deviceAtAddress[address] = info.id }
                if let existing = self.lines[info.id] {
                    // Two Macs that call each other at once keep one line: the one the Mac with the smaller id opened.
                    guard calledByUs == (self.store.deviceID < info.id) else { return false }
                    existing.session.close()
                }
                self.lines[info.id] = Line(session: session, host: host)
                return true
            }
        }
        do {
            try await session.greet()
            setProblem(nil)
            onChange?()
            try await session.run()
        } catch ChannelError.refused(let reason) where !reason.hasPrefix("Already connected") && !reason.hasPrefix("That address is this Mac") {
            setProblem(reason)
        } catch {}
        session.close()
        let wasListed = lock.withLock { () -> Bool in
            guard let device, lines[device.id]?.session === session else { return false }
            lines[device.id] = nil
            return true
        }
        if wasListed { onChange?() }
    }

    /// Sends this Mac's manifest to every connected Mac that has not had it.
    public func announce() async {
        for line in lock.withLock({ Array(lines.values) }) { try? await line.session.announce() }
    }

    /// Several changes in a burst (an edit, an analysis finishing) are announced once.
    private func announceSoon() {
        lock.withLock {
            guard announcer == nil else { return }
            announcer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.lock.withLock { self?.announcer = nil }
                await self?.announce()
            }
        }
    }

    // MARK: Files

    public enum FetchError: Error, LocalizedError {
        case nobodyHasIt(String)

        public var errorDescription: String? {
            switch self {
            case .nobodyHasIt(let title): return "\"\(title)\" is on another Mac that is not connected right now."
            }
        }
    }

    /// True if a connected Mac can hand this track's file over now.
    public func canFetch(contentID: String) -> Bool {
        guard let holders = try? store.holders(of: contentID) else { return false }
        return lock.withLock { holders.contains { lines[$0] != nil } }
    }

    /// Copies a track's file from a connected Mac that has it, files it, and records where it is.
    /// Asking twice for the same track while it is on its way waits for the one copy.
    /// - Returns: the path of the file on this Mac.
    public func fetch(contentID: String) async throws -> String {
        let task = lock.withLock { () -> Task<String, Error> in
            if let running = fetches[contentID] { return running }
            let task = Task { [weak self] () throws -> String in
                guard let self else { throw ChannelError.closed }
                defer { self.lock.withLock { self.fetches[contentID] = nil } }
                return try await self.copy(contentID: contentID)
            }
            fetches[contentID] = task
            return task
        }
        return try await task.value
    }

    private func copy(contentID: String) async throws -> String {
        let track = try store.track(contentID: contentID)
        // Another Mac may have been asked first: the file may be here by now.
        if let track, let path = Volumes.resolvedPath(for: track) { return path }
        let holders = try store.holders(of: contentID)
        guard let peer = connected.first(where: { holders.contains($0.device.id) }) else {
            throw FetchError.nobodyHasIt(track?.title ?? "That track")
        }
        let name = peer.device.name
        onFetchProgress?(contentID, name, 0)
        defer { onFetchProgress?(contentID, name, nil) }
        let channel = try await open(host: peer.host, port: peer.port)
        defer { channel.close() }
        try await SyncSession(store: store, channel: channel, purpose: "file", port: port).greet()
        let report = onFetchProgress
        let file = try await FileTransfer.fetch(key: contentID, artist: track?.artist ?? "", over: channel, into: musicFolder) { fraction in
            report?(contentID, name, fraction)
        }
        // The folder fetched music goes to is part of the library, so later scans know these files.
        let location = Volumes.location(forPath: musicFolder.path)
        try store.addFolder(path: musicFolder.path, volumeUUID: location?.uuid, relativePath: location?.relativePath)
        try store.attachFile(contentID: contentID, path: file.path)
        // Its waveforms can be copied too, now that there is a file here to go with them.
        if let line = lock.withLock({ lines[peer.device.id] }) { try? await line.session.reconsider() }
        return file.path
    }

    /// Fetches, one at a time, the files that crates marked "keep on this Mac" still lack.
    private func keepUp() {
        lock.withLock {
            guard keeper == nil else { return }
            keeper = Task { [weak self] in
                defer { self?.lock.withLock { self?.keeper = nil } }
                guard let self, let wanted = try? self.store.tracksToKeepHere() else { return }
                for track in wanted {
                    guard !Task.isCancelled, let key = track.contentID, self.canFetch(contentID: key) else { continue }
                    // One that failed is left for a few minutes rather than tried every few seconds.
                    if let failed = self.lock.withLock({ self.failedFetches[key] }), Date().timeIntervalSince1970 - failed < 300 { continue }
                    do {
                        _ = try await self.fetch(contentID: key)
                    } catch {
                        self.lock.withLock { self.failedFetches[key] = Date().timeIntervalSince1970 }
                    }
                }
            }
        }
    }
}
