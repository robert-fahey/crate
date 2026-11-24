import AppKit
import CrateCore
import Foundation
import Observation

enum SidebarItem: Hashable {
    case all
    case recent
    case needsTagging
    case source(TrackSource)
    case crate(Int64)
}

/// Everything the main window shows, and the actions behind its controls.
@MainActor
@Observable
final class AppModel {
    let store: LibraryStore
    let mixer: DJMixer
    let player: PlayerController
    let director: MixDirector
    let agent: AgentSession
    let spotify: SpotifyAPI
    let tidal: TidalAPI
    let sharing: SharingModel
    @ObservationIgnored private(set) var controller: ControllerModel!
    /// Counts moves of the selection made from a controller, so the list can keep the selected row in view.
    private(set) var browseMoves = 0

    var sidebar: SidebarItem = .all { didSet { reload() } }
    var searchText = "" { didSet { reload() } }
    /// What the table's headers show: the column clicked last comes first.
    var sortOrder: [KeyPathComparator<Track>] = [KeyPathComparator(\Track.artist)] {
        didSet {
            if let clicked = sortOrder.first { sortLevels = TrackSorting.levels(clicking: clicked, after: sortLevels) }
            tracks.sort(using: TrackSorting.comparators(for: sortLevels))
        }
    }
    /// The column the list is sorted by and the one that orders its ties: the last two headers clicked.
    private(set) var sortLevels: [KeyPathComparator<Track>] = [KeyPathComparator(\Track.artist)]
    var selection = Set<Track.ID>()

    private(set) var tracks: [Track] = []
    private(set) var crates: [Crate] = []
    private(set) var folders: [LibraryFolder] = []
    private(set) var stats = LibraryStats()
    /// Local tracks whose files cannot be reached right now.
    private(set) var unavailable = Set<Track.ID>()
    /// Tracks whose files are on another of the user's Macs, with that Mac's name.
    private(set) var away: [Track.ID: String] = [:]
    /// Progress of scanning or analysis, shown in the status line.
    private(set) var activity: String?
    var alert: String?
    var editing: Track?
    /// The deck whose beat grid is open in the grid editor.
    var gridEditing: DeckID?

    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private let registry = ToolRegistry()
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var fingerprintTask: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
        scanner = LibraryScanner(store: store)
        mixer = DJMixer(store: store)
        player = PlayerController(store: store, mixer: mixer)
        director = MixDirector(mixer: mixer, player: player, store: store)
        agent = AgentSession(store: store, registry: registry)

        let context = LibraryToolContext(store: store, scanner: scanner, catalog: StreamingCatalog())
        LibraryTools.register(into: registry, context: context)
        PlayerTools.register(into: registry, context: context, player: player)
        DeckTools.register(into: registry, context: context, mix: director)
        director.agent = agent
        // CRATE_DB marks a test run: keep it away from the real keychain.
        let secrets: SecretStore = ProcessInfo.processInfo.environment["CRATE_DB"] == nil ? KeychainStore() : MemorySecretStore()
        spotify = SpotifyAPI(secrets: secrets)
        tidal = TidalAPI(secrets: secrets)
        sharing = SharingModel(store: store, secrets: secrets)
        let sharing = self.sharing
        mixer.fetchFile = { track, note in try await sharing.fetch(track, note: note) }
        sharing.onChange = { [weak self] in self?.refreshAvailability() }
        ServiceTools.register(into: registry, context: context, spotify: spotify, tidal: tidal)
        let agent = self.agent
        CommandTool.register(into: registry) { request in await agent.requestApproval(request) }

        NotificationCenter.default.addObserver(
            forName: .libraryDidChange, object: store, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.agent.quit() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.volumesChanged() }
            }
        }
        reload()
        _ = FakeController.shared  // exists only in test runs, and must be there before the controller is looked for
        controller = ControllerModel(app: self)
    }

    /// Moves the selection up or down the track list, as a controller's browse knob does.
    func moveSelection(by rows: Int) {
        guard !tracks.isEmpty, rows != 0 else { return }
        let current = tracks.firstIndex { selection.contains($0.id) }
        let next = max(0, min(tracks.count - 1, (current ?? (rows > 0 ? -1 : tracks.count)) + rows))
        selection = [tracks[next].id]
        browseMoves += 1
    }

    // MARK: Loading

    /// Many changes arrive in bursts (a scan, an agent editing tracks); reload once for each burst.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.reloadScheduled = false
            self.sharing.refresh()
            self.reload()
        }
    }

    /// Gives every local file its fingerprint, which is what makes it the same track on the other Macs.
    /// Quick (two megabytes read per file), and needed once per file.
    func fingerprintPending() {
        guard fingerprintTask == nil else { return }
        let store = self.store
        fingerprintTask = Task {
            await Task.detached(priority: .utility) {
                for track in (try? store.tracksNeedingContentID()) ?? [] {
                    guard let path = Volumes.resolvedPath(for: track), let print = Fingerprint.of(path: path) else { continue }
                    try? store.setContentID(id: track.id, print)
                }
            }.value
            self.fingerprintTask = nil
            self.store.setSetting("sync.fingerprinted", "1")
            NotificationCenter.default.post(name: .libraryDidChange, object: self.store)
        }
    }

    /// Copies tracks that are on another Mac to this one.
    func copyToThisMac(_ tracks: [Track]) {
        Task {
            for track in tracks where !track.isOnThisMac {
                do {
                    _ = try await sharing.fetch(track)
                } catch {
                    alert = error.localizedDescription
                    return
                }
            }
        }
    }

    func setKeepHere(_ crate: Crate, _ keep: Bool) {
        do {
            try store.setKeepHere(crateID: crate.id, keep)
        } catch {
            alert = error.localizedDescription
        }
    }

    func reload() {
        var query = TrackQuery()
        query.text = searchText
        switch sidebar {
        case .all: break
        case .recent:
            query.sort = .added
            query.ascending = false
            query.limit = 100
        case .needsTagging: query.needsTagging = true
        case .source(let source): query.source = source
        case .crate(let id): query.crateID = id
        }
        do {
            var loaded = try store.tracks(query)
            // A crate keeps its own order and "recent" its date order until a column header is clicked.
            let keepsStoreOrder: Bool
            switch sidebar {
            case .crate, .recent: keepsStoreOrder = sortOrder == [KeyPathComparator(\Track.artist)]
            default: keepsStoreOrder = false
            }
            if !keepsStoreOrder { loaded.sort(using: TrackSorting.comparators(for: sortLevels)) }
            tracks = loaded
            crates = try store.crates()
            folders = try store.folders()
            stats = try store.stats()
        } catch {
            alert = error.localizedDescription
        }
        if case .crate(let id) = sidebar, !crates.contains(where: { $0.id == id }) { sidebar = .all }
        selection.formIntersection(Set(tracks.map(\.id)))
        refreshAvailability()
        player.refreshWaveform()
    }

    private func refreshAvailability() {
        let local = tracks.filter { $0.source == .local }
        Task.detached(priority: .utility) {
            var mounts: [String: String?] = [:]
            var missing = Set<Track.ID>()
            for track in local {
                var path = track.path
                if let uuid = track.volumeUUID, let relative = track.relativePath {
                    if mounts[uuid] == nil { mounts[uuid] = Volumes.mountPoint(uuid: uuid) }
                    path = (mounts[uuid] ?? nil).map { ($0 as NSString).appendingPathComponent(relative) }
                }
                if path.map(FileManager.default.fileExists(atPath:)) != true { missing.insert(track.id) }
            }
            let result = missing
            await MainActor.run {
                // A file on another Mac that is connected is a click away, not missing.
                var away: [Track.ID: String] = [:]
                var unreachable = result
                for track in local where result.contains(track.id) {
                    if let name = self.sharing.holder(of: track) { away[track.id] = name }
                    if self.sharing.canFetch(track) { unreachable.remove(track.id) }
                }
                self.unavailable = unreachable
                self.away = away
            }
        }
    }

    private func volumesChanged() {
        refreshAvailability()
        // A drive that has just been plugged in may hold new files and tracks still to analyse.
        rescan()
    }

    var title: String {
        switch sidebar {
        case .all: return "All Tracks"
        case .recent: return "Recently Added"
        case .needsTagging: return "To Tag"
        case .source(let source): return source.displayName
        case .crate(let id): return crates.first { $0.id == id }?.name ?? "Crate"
        }
    }

    var selectedTracks: [Track] { tracks.filter { selection.contains($0.id) } }

    // MARK: Library

    /// Folders worth offering on first run: ones that exist and are not yet in the library.
    var suggestedFolders: [String] {
        let home = NSHomeDirectory()
        var candidates = ["\(home)/Music/tiddl"]
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        candidates += volumes.map { "/Volumes/\($0)/Music" }
        let known = Set(folders.map(\.path))
        return candidates.filter { path in
            var isDirectory: ObjCBool = false
            return !known.contains(path) && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose folders of full-length tracks. Files under a minute are skipped as samples."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFolder(url.path) }
    }

    func addFolder(_ path: String) {
        let scanner = self.scanner
        let name = (path as NSString).lastPathComponent
        activity = "Scanning \(name)…"
        Task {
            do {
                let summary = try await Task.detached { try await scanner.scan(folder: path) }.value
                self.activity = "\(name): \(summary.description)"
                self.agent.reloadSession()
                self.analyzePending()
            } catch {
                self.activity = nil
                self.alert = error.localizedDescription
            }
        }
    }

    func removeFolder(_ folder: LibraryFolder) {
        do {
            try store.removeFolder(id: folder.id)
            agent.reloadSession()
        } catch {
            alert = error.localizedDescription
        }
    }

    func rescan() {
        guard !folders.isEmpty else { return }
        let scanner = self.scanner
        activity = "Checking library folders…"
        Task {
            let summary = await Task.detached { await scanner.scanAll() }.value
            self.activity = summary.added + summary.updated > 0 ? "Library updated: \(summary.description)" : nil
            self.fingerprintPending()
            self.analyzePending()
        }
    }

    /// Works through tracks that have no BPM, key or waveform yet, one at a time, in the background.
    func analyzePending() {
        guard analysisTask == nil else { return }
        let store = self.store
        analysisTask = Task {
            let pending = ((try? store.unanalyzedLocalTracks()) ?? [])
            var done = 0
            for track in pending {
                if Task.isCancelled { break }
                self.activity = "Analysing \(done + 1) of \(pending.count): \(track.title)"
                _ = await Task.detached(priority: .utility) { try? AudioAnalyzer.analyze(track: track, store: store) }.value
                done += 1
            }
            if !pending.isEmpty { self.activity = nil }
            self.analysisTask = nil
        }
    }

    func reanalyze(_ tracks: [Track]) {
        let store = self.store
        Task {
            for (index, track) in tracks.enumerated() where track.source == .local {
                self.activity = "Analysing \(index + 1) of \(tracks.count): \(track.title)"
                _ = await Task.detached(priority: .utility) { try? AudioAnalyzer.analyze(track: track, store: store) }.value
            }
            self.activity = nil
        }
    }

    // MARK: Tracks

    func play(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        player.open(tracks, startingAt: index)
    }

    /// Puts a track on a deck without starting it. Returns at once; the track arrives when its file has been read.
    func load(_ track: Track, on deck: DeckID) {
        Task { await loadAndWait(track, on: deck) }
    }

    /// The same, returning whether the track is now on the deck.
    @discardableResult
    func loadAndWait(_ track: Track, on deck: DeckID) async -> Bool {
        do {
            try await mixer.load(track, on: deck)
            player.problem = nil
            return true
        } catch is CancellationError {
            return false  // another track was put on that deck before this one arrived
        } catch {
            player.problem = error.localizedDescription
            return false
        }
    }

    /// Opens the beat grid editor for a track, putting it on a deck first if it is not on one.
    func editGrid(for track: Track) {
        if let deck = mixer.decks.first(where: { $0.track?.id == track.id }) {
            gridEditing = deck.id
            return
        }
        let target = mixer.freeDeck
        guard !mixer.deck(target).isPlaying else {
            alert = "Both decks are playing. The grid editor needs a deck to play the track on: stop one first."
            return
        }
        Task {
            if await loadAndWait(track, on: target), mixer.deck(target).track?.id == track.id { gridEditing = target }
        }
    }

    func loadSelection(on deck: DeckID) {
        if let track = selectedTracks.first(where: { $0.source == .local }) { load(track, on: deck) }
    }

    func load(trackID: Int64, on deck: DeckID) {
        if let track = try? store.track(id: trackID) { load(track, on: deck) }
    }

    func update(_ track: Track, _ change: (inout TrackPatch) -> Void) {
        var patch = TrackPatch()
        change(&patch)
        do {
            try store.update(id: track.id, patch)
        } catch {
            alert = error.localizedDescription
        }
    }

    func scaleBPM(_ tracks: [Track], by factor: Double) {
        for track in tracks {
            guard let bpm = track.bpm else { continue }
            update(track) { $0.bpm = .some(bpm * factor) }
        }
    }

    func removeFromLibrary(_ tracks: [Track]) {
        do {
            try store.deleteTracks(ids: tracks.map(\.id))
        } catch {
            alert = error.localizedDescription
        }
    }

    func revealInFinder(_ track: Track) {
        guard let path = Volumes.resolvedPath(for: track) else {
            alert = "That file is not reachable right now."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Services

    private(set) var spotifyStatus: String?
    private(set) var tidalStatus: String?
    private(set) var isConnectingSpotify = false
    @ObservationIgnored private var spotifyCallback: LoopbackCallback?

    /// Opens Spotify's sign-in page in the browser and waits for it to come back.
    func connectSpotify(clientID: String) {
        spotify.clientID = clientID
        do {
            let signIn = try spotify.beginSignIn()
            let callback = try LoopbackCallback(port: SpotifyAPI.redirectPort)
            spotifyCallback = callback
            isConnectingSpotify = true
            spotifyStatus = "Waiting for you to approve in the browser…"
            NSWorkspace.shared.open(signIn.url)
            let spotify = self.spotify
            Task {
                do {
                    try await spotify.finishSignIn(signIn, callback: try await callback.wait())
                    self.spotifyStatus = "Connected."
                } catch {
                    self.spotifyStatus = error.localizedDescription
                }
                self.isConnectingSpotify = false
                self.spotifyCallback = nil
            }
        } catch {
            spotifyStatus = error.localizedDescription
        }
    }

    func cancelSpotifyConnect() { spotifyCallback?.cancel() }

    func disconnectSpotify() {
        spotify.disconnect()
        spotifyStatus = "Disconnected."
    }

    /// Saves the TIDAL credentials and checks them by requesting a token.
    func saveTidal(clientID: String, clientSecret: String) {
        tidal.configure(clientID: clientID, clientSecret: clientSecret)
        guard tidal.isConfigured else {
            tidalStatus = clientID.isEmpty && clientSecret.isEmpty ? "Removed." : "Both the client ID and the secret are needed."
            return
        }
        tidalStatus = "Checking…"
        let tidal = self.tidal
        Task {
            do {
                try await tidal.validToken()
                self.tidalStatus = "Connected."
            } catch {
                self.tidalStatus = error.localizedDescription
            }
        }
    }

    // MARK: Crates

    func newCrate(containing tracks: [Track] = []) {
        var name = "New Crate"
        var number = 2
        while crates.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "New Crate \(number)"
            number += 1
        }
        do {
            let crate = try store.createCrate(name: name)
            try store.addToCrate(id: crate.id, trackIDs: tracks.map(\.id))
            reload()
            sidebar = .crate(crate.id)
        } catch {
            alert = error.localizedDescription
        }
    }

    func rename(_ crate: Crate, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name != crate.name else { return }
        do {
            try store.renameCrate(id: crate.id, to: name)
        } catch {
            alert = error.localizedDescription
        }
    }

    func delete(_ crate: Crate) {
        do {
            try store.deleteCrate(id: crate.id)
        } catch {
            alert = error.localizedDescription
        }
    }

    func add(_ trackIDs: [Int64], to crate: Crate) {
        do {
            try store.addToCrate(id: crate.id, trackIDs: trackIDs)
        } catch {
            alert = error.localizedDescription
        }
    }

    func removeFromCurrentCrate(_ tracks: [Track]) {
        guard case .crate(let id) = sidebar else { return }
        do {
            try store.removeFromCrate(id: id, trackIDs: tracks.map(\.id))
        } catch {
            alert = error.localizedDescription
        }
    }
}
