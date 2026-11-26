import CrateCore
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    @State private var detailSize = CGSize.zero
    @State private var decksHeight: CGFloat = 430
    @AppStorage("sampler.shown") private var showsSampler = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .alert("Crate", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(isPresented: Binding(get: { model.mixEditing != nil }, set: { if !$0 { model.mixEditing = nil } })) {
            if let crate = model.mixEditing {
                MixEditor(model: model, crateID: crate) { model.mixEditing = nil }
            }
        }
        .sheet(item: $model.cueEditing) { deck in
            CueEditor(deck: model.mixer.deck(deck), model: model) { model.cueEditing = nil }
        }
        .sheet(item: $model.gridEditing) { deck in
            GridEditor(deck: model.mixer.deck(deck)) { model.gridEditing = nil }
        }
        .sheet(item: $model.editing) { track in
            TrackEditor(model: model, track: track)
        }
        .sheet(isPresented: Binding(get: { model.grab.isShown }, set: { model.grab.isShown = $0 })) {
            GrabSheet(grab: model.grab, model: model)
        }
        .sheet(item: Binding(get: { model.agent.pendingCommand }, set: { _ in })) { request in
            CommandConfirmSheet(request: request) { approved in model.agent.resolveCommand(approved: approved) }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            // The decks redraw constantly while playing; in their own host that does not disturb the rest.
            IsolatedHost {
                DecksView(model: model, available: detailSize) { height in
                    if abs(height - decksHeight) > 0.5 { decksHeight = height }
                }
            }
            .frame(height: decksHeight)
            if showsSampler {
                SamplerStrip(model: model)
            }
            if model.stats.tracks == 0 {
                EmptyLibraryView(model: model)
            } else if model.sidebar == .history {
                HistoryView(model: model)
            } else {
                TrackTableView(model: model)
            }
            Divider()
            AgentPanel(model: model, room: detailSize.height - decksHeight - (showsSampler ? SamplerStrip.height : 0))
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { detailSize = $0 }
        // The split view asks this column how small, how big and how big ideally it could be
        // every time anything in it redraws. Answering here, with all three given, saves it
        // measuring the decks, the table and the agent bar sixty times a second while a deck plays.
        .frame(minWidth: 860, idealWidth: 1080, maxWidth: .infinity, minHeight: 640, idealHeight: 860, maxHeight: .infinity)
        .navigationTitle(model.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search title, artist, album")
        .toolbar {
            if let crate = model.currentCrate {
                ToolbarItem {
                    Button {
                        model.mixEditing = crate.id
                    } label: {
                        Label("Mix", systemImage: "arrow.triangle.merge")
                    }
                    .help("The mix editor: how each track of “\(crate.name)” goes into the next. Set it by hand, have it suggested, or ask the agent; then play the crate as a mix.")
                }
            }
            ToolbarItem {
                Button {
                    model.grab.open(crate: model.currentCrate)
                } label: {
                    Label("Grab from TIDAL", systemImage: "arrow.down.circle")
                }
                .help("Download tracks from TIDAL with tiddl and add them to the library")
            }
            ToolbarItem {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .help("Add a folder of music to the library")
            }
        }
    }

    private var subtitle: String {
        if let activity = model.activity { return activity }
        if model.sidebar == .history {
            let plays = model.history.playCount, sessions = model.history.sessions.count
            if plays == 0 { return "Nothing played yet" }
            return "\(plays == 1 ? "1 track" : "\(plays) tracks") played in \(sessions == 1 ? "1 session" : "\(sessions) sessions")"
        }
        let count = model.tracks.count
        let total = model.tracks.reduce(0) { $0 + $1.duration }
        let hours = Int(total) / 3600, minutes = Int(total) % 3600 / 60
        let length = hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
        let summary = count == 1 ? "1 track" : "\(count) tracks, \(length)"
        // With two columns in charge, say which: the header only marks the first.
        return TrackSorting.description(of: model.sortLevels).map { "\(summary) · sorted \($0)" } ?? summary
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var renaming: Crate?
    @State private var newName = ""

    var body: some View {
        // In every row `.tag` comes last: a `.badge` applied after the tag hides it,
        // and a row without a visible tag cannot be selected.
        List(selection: $model.sidebar) {
            Section("Library") {
                Label("All Tracks", systemImage: "music.note.list").badge(model.stats.tracks)
                    .tag(SidebarItem.all)
                Label("Recently Added", systemImage: "clock").tag(SidebarItem.recent)
                Label("To Tag", systemImage: "tag").badge(model.stats.needsTagging)
                    .tag(SidebarItem.needsTagging)
                Label("Mix History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            }
            Section("Crates") {
                ForEach(model.crates) { crate in
                    Label(crate.name, systemImage: "shippingbox")
                        .badge(crate.trackCount)
                        .tag(SidebarItem.crate(crate.id))
                        .dropDestination(for: String.self) { items, _ in
                            let ids = items.flatMap { $0.split(separator: ",") }.compactMap { Int64($0) }
                            model.add(ids, to: crate)
                            return !ids.isEmpty
                        }
                        .contextMenu {
                            Button("Play") { play(crate) }
                            Button("Play Mix") { Task { await model.director.playMix(crate) } }
                            Button("Edit Mix…") { model.mixEditing = crate.id }
                            Button("Ask the Agent About This Crate") {
                                model.sidebar = .crate(crate.id)
                                model.draft.focus()
                            }
                            Button("Rename…") {
                                newName = crate.name
                                renaming = crate
                            }
                            Button("Export for rekordbox…") { model.exportForRekordbox([crate]) }
                            if model.sharing.isOn {
                                Toggle("Keep on This Mac", isOn: Binding(get: { crate.keepHere }, set: { model.setKeepHere(crate, $0) }))
                            }
                            Divider()
                            Button("Delete Crate", role: .destructive) { model.delete(crate) }
                        }
                }
                Button {
                    model.newCrate()
                } label: {
                    Label("New Crate", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section("Sources") {
                Label("Local", systemImage: "internaldrive").badge(model.stats.local).tag(SidebarItem.source(.local))
                Label("Spotify", systemImage: "dot.radiowaves.left.and.right").badge(model.stats.spotify)
                    .tag(SidebarItem.source(.spotify))
                Label("TIDAL", systemImage: "waveform").badge(model.stats.tidal).tag(SidebarItem.source(.tidal))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if model.sharing.isOn { SharingStatus(sharing: model.sharing) }
        }
        .alert("Rename Crate", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { model.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func play(_ crate: Crate) {
        var query = TrackQuery()
        query.crateID = crate.id
        if let tracks = try? model.store.tracks(query) { model.player.play(tracks) }
    }
}

// MARK: - Empty state

struct EmptyLibraryView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.title2)
            Text("Add a folder of full-length tracks. Files under a minute are skipped as samples.")
                .foregroundStyle(.secondary)
            ForEach(model.suggestedFolders, id: \.self) { path in
                Button("Add \((path as NSString).abbreviatingWithTildeInPath)") { model.addFolder(path) }
            }
            Button("Choose Folder…") { model.chooseFolder() }
                .keyboardShortcut(.defaultAction)
            if let activity = model.activity {
                ProgressView(activity).controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Track table

struct TrackTableView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            table
                // The browse knob on a controller moves the selection; the list follows it.
                .onChange(of: model.browseMoves) {
                    if let id = model.selection.first { proxy.scrollTo(id) }
                }
        }
    }

    private var table: some View {
        Table(of: Track.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 6) {
                    // Which deck the track is on, lit while that deck plays.
                    ForEach(model.mixer.decks.filter { $0.track?.id == track.id }) { deck in
                        Text(deck.id.name)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(deck.isPlaying ? Color.black.opacity(0.85) : DeckStyle.color(deck.id.rawValue))
                            .frame(width: 17, height: 17)
                            .background(
                                DeckStyle.gradient(deck.id.rawValue).opacity(deck.isPlaying ? 1 : 0.22),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .shadow(color: DeckStyle.color(deck.id.rawValue).opacity(deck.isPlaying ? 0.8 : 0), radius: 5)
                    }
                    if model.player.streaming?.id == track.id {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).imageScale(.small)
                    }
                    Text(track.title)
                }
                .foregroundStyle(model.unavailable.contains(track.id) ? .tertiary : .primary)
                .help(model.unavailable.contains(track.id)
                    ? (model.away[track.id].map { "On \($0), which is not connected right now" } ?? "File not reachable: drive unplugged or file moved")
                    : track.title)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Artist", value: \.artist) { track in
                Text(track.artist.isEmpty ? "—" : track.artist)
                    .foregroundStyle(track.artist.isEmpty || model.unavailable.contains(track.id) ? .tertiary : .primary)
            }
            .width(min: 120, ideal: 200)

            TableColumn("BPM", value: \.sortBPM) { track in
                ValueCell(text: track.bpm.map { String(format: "%.1f", $0) }, source: track.bpmSource)
            }
            .width(64)

            TableColumn("Key", value: \.sortKey) { track in
                KeyCell(key: track.key, camelot: track.camelot, source: track.keySource)
                    .help(track.camelot?.musicalName ?? "")
            }
            .width(48)

            TableColumn("Time", value: \.duration) { track in
                Text(TrackFormat.duration(track.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(52)

            TableColumn("Added", value: \.addedAt) { track in
                Text(track.addedAt.formatted(.dateTime.day().month(.abbreviated).year()))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Added to the library \(track.addedAt.formatted(date: .complete, time: .shortened))")
            }
            .width(96)

            TableColumn("Source", value: \.format) { track in
                if let mac = model.away[track.id] {
                    // Its file is on another of your Macs; loading it copies it here.
                    Label(mac, systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(model.unavailable.contains(track.id) ? .tertiary : .secondary)
                        .lineLimit(1)
                        .help(model.unavailable.contains(track.id)
                            ? "On \(mac), which is not connected right now"
                            : "On \(mac). Loading or playing it copies it to this Mac.")
                } else {
                    Text(track.source == .local ? track.format.uppercased() : track.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 70, max: 140)
        } rows: {
            ForEach(model.tracks) { track in
                TableRow(track)
                    .draggable(dragPayload(for: track))
            }
        }
        .scrollContentBackground(.hidden)
        .background(DeckStyle.base)
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            menu(for: model.tracks.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let track = model.tracks.first(where: { ids.contains($0.id) }) { model.play(track) }
        }
        .overlay {
            if model.tracks.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "Nothing here yet" : "No matches",
                    systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(model.searchText.isEmpty ? emptyHint : "No tracks match “\(model.searchText)”."))
            }
        }
    }

    private var emptyHint: String {
        switch model.sidebar {
        case .crate: return "Drag tracks here, or ask the agent to fill this crate."
        case .needsTagging: return "Every track has an artist, BPM and key."
        case .source(.spotify), .source(.tidal): return "Tracks you add from a search appear here."
        default: return "No tracks."
        }
    }

    /// Dragging a selected row drags the whole selection.
    private func dragPayload(for track: Track) -> String {
        let ids = model.selection.contains(track.id) ? model.selectedTracks.map(\.id) : [track.id]
        return ids.map(String.init).joined(separator: ",")
    }

    @ViewBuilder
    private func menu(for tracks: [Track]) -> some View {
        if let first = tracks.first {
            Button("Play") { model.play(first) }
            if first.source == .local {
                Button("Load on Deck A") { model.load(first, on: .a) }
                Button("Load on Deck B") { model.load(first, on: .b) }
            }
            Button("Add to Queue") { model.player.enqueue(tracks) }
            if tracks.contains(where: { model.away[$0.id] != nil }) {
                Button("Copy to This Mac") { model.copyToThisMac(tracks) }
            }
            // A TIDAL track is a known track: it can be downloaded as it is. Anything else that has no
            // file here is looked for on TIDAL first.
            let streamed = tracks.filter { $0.source == .tidal }
            let fileless = tracks.filter { $0.source == .spotify || model.unavailable.contains($0.id) }
            if !streamed.isEmpty {
                Button(streamed.count == 1 ? "Grab from TIDAL" : "Grab \(streamed.count) from TIDAL") { model.grab.grab(streaming: streamed) }
            }
            if !fileless.isEmpty {
                Button("Find on TIDAL to Grab…") { model.grab.open(finding: fileless, crate: model.currentCrate) }
            }
            Divider()
            Menu("Ask the Agent") {
                // The same offers the agent bar makes for a selection. The tracks are selected first, since
                // "the selected track" is how the request names them.
                ForEach(model.suggestions(for: tracks)) { suggestion in
                    Button(suggestion.label) {
                        model.selection = Set(tracks.map(\.id))
                        model.use(suggestion)
                    }
                }
                Divider()
                Button("Something Else…") {
                    model.selection = Set(tracks.map(\.id))
                    model.draft.focus()
                }
            }
            if tracks.count == 1, first.source == .local {
                Menu("Send to Sampler") {
                    ForEach(DeckID.allCases) { deck in
                        Section("Deck \(deck.name): \(model.mixer.sampler.bank(on: deck)?.name ?? "")") {
                            ForEach(model.mixer.sampler.pads(of: deck)) { pad in
                                Button(pad.isLoaded ? "Pad \(pad.slot + 1) (replaces “\(pad.name)”)" : "Pad \(pad.slot + 1)") {
                                    model.sendToSampler(trackID: first.id, pad: pad.id)
                                }
                            }
                        }
                    }
                }
            }
            Menu("Add to Crate") {
                ForEach(model.crates) { crate in
                    Button(crate.name) { model.add(tracks.map(\.id), to: crate) }
                }
                if !model.crates.isEmpty { Divider() }
                Button("New Crate with Selection") { model.newCrate(containing: tracks) }
            }
            if case .crate = model.sidebar {
                Button("Remove from This Crate") { model.removeFromCurrentCrate(tracks) }
            }
            Divider()
            if tracks.count == 1 {
                Button("Edit Details…") { model.editing = first }
            }
            Menu("BPM") {
                Button("Halve") { model.scaleBPM(tracks, by: 0.5) }
                Button("Double") { model.scaleBPM(tracks, by: 2) }
            }
            .disabled(tracks.allSatisfy { $0.bpm == nil })
            if tracks.contains(where: { $0.source == .local }) {
                if tracks.count == 1 {
                    Button("Edit Cue Points…") { model.editCues(for: first) }
                    Button("Edit Beat Grid…") { model.editGrid(for: first) }
                }
                Button("Analyse BPM and Key Again") { model.reanalyze(tracks) }
                if tracks.count == 1 {
                    Button("Show in Finder") { model.revealInFinder(first) }
                }
            }
            Divider()
            Button("Remove from Library", role: .destructive) { model.removeFromLibrary(tracks) }
        }
    }
}

/// A key in its Camelot colour: keys that mix together have neighbouring colours.
/// An estimate is marked with "~" and dimmed.
struct KeyCell: View {
    let key: String?
    let camelot: CamelotKey?
    let source: ValueSource?

    var body: some View {
        if let key {
            Text((source == .estimated ? "~" : "") + key)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(DeckStyle.keyColor(camelot).opacity(source == .estimated ? 0.75 : 1))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// A BPM or key cell. Estimates are marked with "~" and dimmed, so they are
/// not mistaken for values from tags or ones typed by hand.
struct ValueCell: View {
    let text: String?
    let source: ValueSource?

    var body: some View {
        if let text {
            Text((source == .estimated ? "~" : "") + text)
                .monospacedDigit()
                .foregroundStyle(source == .estimated ? .secondary : .primary)
                .help(help)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private var help: String {
        switch source {
        case .estimated: return "Estimated by Crate. May be wrong."
        case .tag: return "From the file's tags"
        case .manual: return "Set by you"
        case .service: return "From the streaming service"
        case nil: return ""
        }
    }
}

// MARK: - Track editor

struct TrackEditor: View {
    let model: AppModel
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var bpm = ""
    @State private var key = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Details").font(.headline)
            Form {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
                TextField("BPM", text: $bpm)
                TextField("Key", text: $key, prompt: Text("8A or Am"))
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
            }
            Text("Changes are saved in Crate's library. The audio file is not modified.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            title = track.title
            artist = track.artist
            album = track.album
            bpm = track.bpm.map { String(format: "%g", ($0 * 100).rounded() / 100) } ?? ""
            key = track.key ?? ""
            notes = track.notes
        }
    }

    private var parsedBPM: Double? { Double(bpm.replacingOccurrences(of: ",", with: ".")) }

    private var isValid: Bool {
        let bpmOK = bpm.isEmpty || parsedBPM.map { (30...300).contains($0) } == true
        let keyOK = key.isEmpty || CamelotKey(parsing: key) != nil
        return bpmOK && keyOK && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        model.update(track) { patch in
            if title != track.title { patch.title = title }
            if artist != track.artist { patch.artist = artist }
            if album != track.album { patch.album = album }
            if notes != track.notes { patch.notes = notes }
            // Only touch BPM and key if they were edited, so an untouched estimate stays an estimate.
            if parsedBPM != track.bpm { patch.bpm = .some(parsedBPM) }
            let newKey = CamelotKey(parsing: key)?.description
            if newKey != track.key { patch.key = .some(newKey) }
        }
        dismiss()
    }
}

/// At the foot of the sidebar: which of your Macs are connected, and what is being copied.
private struct SharingStatus: View {
    let sharing: SharingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let problem = sharing.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(3)
            } else if sharing.code.isEmpty {
                Label("Sharing needs a code: Settings > Sharing", systemImage: "key").foregroundStyle(.secondary)
            } else if sharing.peers.isEmpty {
                Label("No other Mac connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
            } else {
                ForEach(sharing.peers, id: \.device.id) { peer in
                    Label(peer.device.name, systemImage: "circle.fill").foregroundStyle(.green)
                        .help("Connected at \(peer.host)")
                }
            }
            ForEach(sharing.fetching.keys.sorted(), id: \.self) { key in
                if let fetch = sharing.fetching[key] {
                    ProgressView(value: fetch.fraction) { Text("Copying from \(fetch.from)") }.controlSize(.small)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
