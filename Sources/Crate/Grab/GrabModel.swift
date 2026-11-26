import CrateCore
import Foundation
import Observation

/// Getting tracks from TIDAL with tiddl: what the "Grab from TIDAL" sheet shows, and the settings behind it.
///
/// It goes in two steps. First each line asked for is looked up, and the matches are shown with
/// TIDAL's best guess chosen, because the best guess is often the wrong version of the song.
/// Then the chosen tracks are downloaded and brought into the library.
@MainActor
@Observable
final class GrabModel {
    /// One thing asked for, and what is being done about it.
    struct Row: Identifiable {
        enum State: Equatable {
            case finding
            /// Matches are in; one may be chosen.
            case found
            case nothing(String)
            case waiting
            case downloading
            case done(Track, wasNew: Bool)
            case failed(String)
        }

        let id = UUID()
        /// What was typed, or the name of the library track being looked for.
        var asked: String
        /// A streaming track in the library that the download stands in for.
        var replacing: Track?
        var matches: [Tiddl.Hit] = []
        /// The id of the match to download. Nil leaves this row out.
        var choice: String?
        var state = State.finding
        /// Nothing TIDAL found looks like what was asked for, so nothing was chosen.
        var isDoubtful = false

        var chosen: Tiddl.Hit? { matches.first { $0.id == choice } }
    }

    enum Stage {
        case asking, choosing, grabbing, finished
    }

    /// Something asked for before it has been looked up.
    private struct Entry {
        var asked: String
        var reference: Tiddl.Reference
        var replacing: Track?
    }

    var isShown = false
    /// What is typed in the sheet: a track to a line.
    var text = ""
    /// The crate the tracks are added to, if any.
    var crateID: Int64?
    /// The name of a crate to make for them, when `makesCrate`.
    var newCrateName = ""
    var makesCrate = false
    private(set) var rows: [Row] = []
    private(set) var stage = Stage.asking
    /// Why nothing can be done: tiddl missing, or not signed in.
    private(set) var problem: String?
    private(set) var isBusy = false

    /// Where downloads go.
    var folder: String {
        didSet { UserDefaults.standard.set(folder, forKey: "tiddl.folder") }
    }
    var quality: Tiddl.Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "tiddl.quality") }
    }
    /// What Settings shows about tiddl itself.
    private(set) var status = "Looking for tiddl…"

    /// Says what is going on, for the window's status line. Nil when nothing is.
    @ObservationIgnored var report: ((String?) -> Void)?
    /// Called when tracks have arrived, so that they can be analysed.
    @ObservationIgnored var imported: (() -> Void)?
    /// Something to tell the user when the sheet is not there to show it.
    @ObservationIgnored var announce: ((String) -> Void)?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored let grabber: TrackGrabber
    @ObservationIgnored private var tiddl: Tiddl?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(store: LibraryStore, grabber: TrackGrabber) {
        self.store = store
        self.grabber = grabber
        folder = UserDefaults.standard.string(forKey: "tiddl.folder") ?? TrackGrabber.defaultFolder
        quality = UserDefaults.standard.string(forKey: "tiddl.quality").flatMap(Tiddl.Quality.init) ?? .high
    }

    // MARK: tiddl

    /// The installed tiddl. Looked for again each time it was not found, in case it has been installed since.
    func installed() async -> Tiddl? {
        if let tiddl { return tiddl }
        tiddl = await Tiddl.find()
        refreshStatus()
        return tiddl
    }

    func options() -> TrackGrabber.Options { TrackGrabber.Options(folder: folder, quality: quality) }

    static let howToInstall = "tiddl is not installed. In Terminal: “uv tool install tiddl” (or “pipx install tiddl”), then “tiddl auth login” to sign in to TIDAL."

    private func refreshStatus() {
        guard let tiddl else {
            status = "Not installed"
            return
        }
        let place = (tiddl.executable as NSString).abbreviatingWithTildeInPath
        status = tiddl.isSignedIn ? "Found at \(place), signed in to TIDAL" : "Found at \(place). Not signed in: run “tiddl auth login” in Terminal"
    }

    /// Looks for tiddl and says what was found, for Settings.
    func check() {
        Task {
            tiddl = nil
            _ = await installed()
        }
    }

    // MARK: The sheet

    /// Opens the sheet to type into.
    func open(crate: Crate? = nil) {
        if stage == .finished { reset() }
        if stage == .asking { crateID = crate?.id }
        isShown = true
    }

    /// Opens the sheet looking for library tracks on TIDAL: streaming tracks, or tracks whose files are gone.
    func open(finding tracks: [Track], crate: Crate? = nil) {
        guard !isBusy else {
            isShown = true
            return
        }
        reset()
        // Crate membership is kept by the file taking the track's place, so the crate is not asked for.
        crateID = tracks.contains { $0.source == .local } ? crate?.id : nil
        text = tracks.map { [$0.artist, $0.title].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "\n")
        isShown = true
        find(tracks.map { track in
            let asked = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " – ")
            if track.source == .tidal, let reference = Tiddl.reference(track.uri), case .track = reference {
                return Entry(asked: asked, reference: reference, replacing: track)
            }
            return Entry(
                asked: asked, reference: .search(Tiddl.query(from: "\(track.artist) \(track.title)")),
                replacing: track.source == .local ? nil : track)
        })
    }

    func reset() {
        guard !isBusy else { return }
        rows = []
        stage = .asking
        problem = nil
        text = ""
        makesCrate = false
        newCrateName = ""
    }

    /// Back to what was typed, to change it.
    func back() {
        guard !isBusy else { return }
        rows = []
        stage = .asking
        problem = nil
    }

    /// The lines typed, each as something to look up.
    var canFind: Bool { text.split(whereSeparator: \.isNewline).contains { Tiddl.reference(String($0)) != nil } }

    func find() {
        let entries = text.split(whereSeparator: \.isNewline).compactMap { line -> Entry? in
            let asked = line.trimmingCharacters(in: .whitespaces)
            return Tiddl.reference(asked).map { Entry(asked: asked, reference: $0, replacing: nil) }
        }
        find(entries)
    }

    private func find(_ entries: [Entry]) {
        guard !entries.isEmpty, !isBusy else { return }
        rows = entries.map { Row(asked: $0.asked, replacing: $0.replacing) }
        stage = .choosing
        problem = nil
        isBusy = true
        let ids = rows.map(\.id)
        work = Task {
            defer { isBusy = false }
            guard let tiddl = await installed() else {
                problem = Self.howToInstall
                stage = .asking
                return
            }
            // A few at a time: each is a short conversation with TIDAL.
            for start in stride(from: 0, to: entries.count, by: 4) {
                let batch = Array(start..<min(start + 4, entries.count))
                let found = await withTaskGroup(of: (Int, Result<[Tiddl.Hit], Error>).self) { group in
                    for index in batch {
                        let reference = entries[index].reference
                        group.addTask {
                            do {
                                return (index, .success(try await tiddl.tracks(of: reference)))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }
                    var results: [Int: Result<[Tiddl.Hit], Error>] = [:]
                    for await (index, result) in group { results[index] = result }
                    return results
                }
                if Task.isCancelled { return }
                for index in batch {
                    guard let result = found[index] else { continue }
                    place(result, for: entries[index], at: ids[index])
                }
            }
        }
    }

    /// Puts what was found for one line into its row. An album or a playlist becomes a row for each of its tracks.
    private func place(_ result: Result<[Tiddl.Hit], Error>, for entry: Entry, at id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .failure(let error):
            // tiddl missing its sign-in is the same for every line: say it once.
            if error.localizedDescription.contains("tiddl auth login") { problem = error.localizedDescription }
            rows[index].state = .nothing(error.localizedDescription)
        case .success(let hits):
            let usable = hits.filter { $0.problem == nil }
            switch entry.reference {
            case .album, .playlist:
                guard !usable.isEmpty else {
                    rows[index].state = .nothing("TIDAL shows no tracks there.")
                    return
                }
                rows.replaceSubrange(index...index, with: usable.map { hit in
                    var row = Row(asked: hit.name, matches: [hit], choice: hit.isAvailable ? hit.id : nil, state: .found)
                    if !hit.isAvailable { row.state = .nothing("TIDAL does not let this track be downloaded.") }
                    return row
                })
            default:
                guard !usable.isEmpty else {
                    rows[index].state = .nothing(hits.first?.problem ?? "TIDAL has nothing matching this.")
                    return
                }
                rows[index].matches = usable
                rows[index].state = .found
                if case .search(let query) = entry.reference {
                    // TIDAL answers with something for any words. A match with little of what was
                    // asked for in its name is shown, and left for the user to choose or not.
                    rows[index].choice = Tiddl.best(of: usable, for: query)?.id
                    rows[index].isDoubtful = rows[index].choice == nil
                } else {
                    rows[index].choice = usable.first(where: \.isAvailable)?.id
                }
            }
        }
    }

    func choose(_ hit: String?, for row: Row.ID) {
        guard stage == .choosing, let index = rows.firstIndex(where: { $0.id == row }) else { return }
        rows[index].choice = hit
    }

    /// How many tracks would be downloaded.
    var chosenCount: Int { rows.filter { $0.chosen != nil }.count }

    /// Downloads what is chosen.
    func grab() {
        guard stage == .choosing, !isBusy, chosenCount > 0 else { return }
        var crate = crateID
        if makesCrate {
            let name = newCrateName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                problem = "Give the new crate a name."
                return
            }
            do {
                crate = try (store.crate(named: name) ?? store.createCrate(name: name)).id
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        problem = nil
        let chosen = rows.compactMap { row in row.chosen.map { (row.id, TrackGrabber.Request($0, replacing: row.replacing?.id)) } }
        for index in rows.indices { rows[index].state = rows[index].chosen == nil ? rows[index].state : .waiting }
        run(chosen, crate: crate)
    }

    /// Downloads streaming tracks that are already in the library, without the sheet: each is a
    /// known TIDAL track, so there is nothing to choose.
    func grab(streaming tracks: [Track]) {
        let known = tracks.filter { $0.source == .tidal }
        guard !known.isEmpty else { return }
        guard !isBusy else {
            announce?("A grab is already under way. Try again when it has finished.")
            return
        }
        rows = known.compactMap { track in
            guard case .track(let id)? = Tiddl.reference(track.uri) else { return nil }
            let hit = Tiddl.Hit(id: id, title: track.title, artist: track.artist, album: track.album, duration: track.duration)
            return Row(asked: hit.name, replacing: track, matches: [hit], choice: id, state: .waiting)
        }
        stage = .choosing
        run(rows.compactMap { row in row.chosen.map { (row.id, TrackGrabber.Request($0, replacing: row.replacing?.id)) } }, crate: nil)
    }

    private func run(_ chosen: [(Row.ID, TrackGrabber.Request)], crate: Int64?) {
        guard !chosen.isEmpty else { return }
        stage = .grabbing
        isBusy = true
        var options = options()
        options.crateID = crate
        work = Task {
            guard let tiddl = await installed() else {
                problem = Self.howToInstall
                fail(chosen.map(\.0), Self.howToInstall)
                finish()
                return
            }
            let total = chosen.count
            _ = await grabber.grab(chosen.map(\.1), with: tiddl, options: options) { [weak self] index, outcome in
                await self?.note(index, outcome, row: chosen[index].0, of: total)
            }
            finish()
        }
    }

    private func fail(_ ids: [Row.ID], _ message: String) {
        for index in rows.indices where ids.contains(rows[index].id) { rows[index].state = .failed(message) }
    }

    private func note(_ index: Int, _ outcome: TrackGrabber.Outcome?, row id: Row.ID, of total: Int) {
        guard let at = rows.firstIndex(where: { $0.id == id }) else { return }
        guard let outcome else {
            rows[at].state = .downloading
            report?("Grabbing \(index + 1) of \(total) from TIDAL: \(rows[at].chosen?.name ?? rows[at].asked)")
            return
        }
        // Looked up by id, the track now has its full name.
        if rows[at].matches.count == 1 { rows[at].matches = [outcome.hit] }
        switch outcome.result {
        case .downloaded(let track): rows[at].state = .done(track, wasNew: true)
        case .alreadyHad(let track): rows[at].state = .done(track, wasNew: false)
        case .failed(let message): rows[at].state = .failed(message)
        }
    }

    private func finish() {
        isBusy = false
        stage = .finished
        var new = 0, had = 0, failed: [String] = []
        for row in rows {
            switch row.state {
            case .done(_, let wasNew): if wasNew { new += 1 } else { had += 1 }
            case .failed(let message): failed.append("\(row.chosen?.name ?? row.asked): \(message)")
            default: break
            }
        }
        var parts: [String] = []
        if new > 0 { parts.append("\(new) downloaded") }
        if had > 0 { parts.append("\(had) already downloaded") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        summary = parts.isEmpty ? nil : "From TIDAL: " + parts.joined(separator: ", ")
        report?(summary)
        // After the summary, so that "Analysing…" is what shows while the new tracks are worked on.
        if new + had > 0 { imported?() }
        // With the sheet closed there is nowhere else to say that something went wrong.
        if !isShown, !failed.isEmpty {
            announce?("Not everything could be grabbed from TIDAL.\n\n" + failed.prefix(8).joined(separator: "\n"))
        }
        if !isShown { reset() }
    }

    /// What the last grab came to.
    private(set) var summary: String?

    /// The tracks that arrived, for showing in the list.
    var arrived: [Track] {
        rows.compactMap { row in
            if case .done(let track, _) = row.state { return track }
            return nil
        }
    }
}
