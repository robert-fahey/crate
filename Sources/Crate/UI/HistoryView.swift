import CrateCore
import SwiftUI

/// The mix history: every session at the decks, latest first, with its tracks in the order played.
struct HistoryView: View {
    let model: AppModel
    @State private var selection = Set<Play.ID>()
    @State private var deleting: MixSession?

    private var history: HistoryModel { model.history }

    /// The sessions, narrowed to what is typed in the search field.
    private var sessions: [MixSession] {
        let wanted = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return history.sessions }
        return history.sessions.compactMap { session in
            var kept = session
            kept.plays = session.plays.filter { play in
                guard let track = history.tracks[play.trackID] else { return false }
                return track.title.localizedCaseInsensitiveContains(wanted) || track.artist.localizedCaseInsensitiveContains(wanted)
                    || track.album.localizedCaseInsensitiveContains(wanted)
            }
            return kept.plays.isEmpty ? nil : kept
        }
    }

    var body: some View {
        let sessions = sessions
        List(selection: $selection) {
            ForEach(sessions) { session in
                Section {
                    ForEach(session.plays) { play in
                        HistoryRow(play: play, track: history.tracks[play.trackID], from: play.fromTrackID.flatMap { history.tracks[$0] })
                            .tag(play.id)
                            .draggable(String(play.trackID))
                    }
                } header: {
                    header(session)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DeckStyle.base)
        .contextMenu(forSelectionType: Play.ID.self) { ids in
            menu(for: plays(ids, in: sessions))
        } primaryAction: { ids in
            // As a double-click in the library does not: it goes on a free deck, ready, without cutting off what is playing.
            if let track = plays(ids, in: sessions).first.flatMap({ history.tracks[$0.trackID] }) { model.load(track, on: model.mixer.freeDeck) }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "Nothing played yet" : "No matches",
                    systemImage: model.searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    description: Text(model.searchText.isEmpty
                        ? "A track is added here once it has been playing in the mix for half a minute."
                        : "Nothing in the history matches “\(model.searchText)”."))
            }
        }
        .confirmationDialog(
            "Delete this session from the history?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { session in
            Button("Delete \(session.plays.count == 1 ? "1 Track" : "\(session.plays.count) Tracks") from the History", role: .destructive) {
                history.delete(session)
            }
        } message: { _ in
            Text("The tracks stay in the library. Only the record of having played them goes.")
        }
    }

    private func plays(_ ids: Set<Play.ID>, in sessions: [MixSession]) -> [Play] {
        sessions.flatMap(\.plays).filter { ids.contains($0.id) }
    }

    private func header(_ session: MixSession) -> some View {
        HStack(spacing: 8) {
            Text(Self.day(session.startedAt)).font(.headline).foregroundStyle(.primary)
            Text(Self.span(session)).foregroundStyle(.secondary)
            Spacer()
            Button("Save as Crate") {
                if let crate = history.saveAsCrate(session) {
                    model.reload()
                    model.sidebar = .crate(crate.id)
                }
            }
            .buttonStyle(.borderless)
            .help("Make a crate of this session's tracks, in the order they were played")
            Menu {
                Button("Delete Session…", role: .destructive) { deleting = session }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func menu(for plays: [Play]) -> some View {
        let tracks = plays.compactMap { history.tracks[$0.trackID] }
        if let track = tracks.first, plays.count == 1 {
            Button("Load on Deck A") { model.load(track, on: .a) }
            Button("Load on Deck B") { model.load(track, on: .b) }
            Divider()
        }
        if !tracks.isEmpty {
            Button("Show in Library") { model.show(tracks) }
            Menu("Add to Crate") {
                ForEach(model.crates) { crate in
                    Button(crate.name) { model.add(tracks.map(\.id), to: crate) }
                }
                if !model.crates.isEmpty { Divider() }
                Button("New Crate") { model.newCrate(containing: tracks) }
            }
            Divider()
        }
        if !plays.isEmpty {
            Button(plays.count == 1 ? "Remove from History" : "Remove \(plays.count) from History", role: .destructive) {
                for play in plays { history.delete(play) }
            }
        }
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return date.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func span(_ session: MixSession) -> String {
        let from = session.startedAt.formatted(date: .omitted, time: .shortened)
        let to = session.lastPlayedAt.formatted(date: .omitted, time: .shortened)
        let count = session.plays.count == 1 ? "1 track" : "\(session.plays.count) tracks"
        return (from == to ? from : "\(from) – \(to)") + " · " + count
    }
}

private struct HistoryRow: View {
    let play: Play
    let track: Track?
    let from: Track?

    var body: some View {
        HStack(spacing: 10) {
            Text(play.playedAt.formatted(date: .omitted, time: .shortened))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            // How it came in: mixed out of the track before, or started cold.
            Image(systemName: "arrow.triangle.merge")
                .font(.caption)
                .foregroundStyle(from == nil ? Color.clear : Color.secondary)
                .frame(width: 16)
                .help(from.map { "Mixed in from “\($0.title)”" } ?? "Started with nothing else playing")
            deck.frame(width: 22)
            Text(track?.title ?? "A track no longer in the library").lineLimit(1)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text(track.map { $0.artist.isEmpty ? "—" : $0.artist } ?? "").lineLimit(1).foregroundStyle(.secondary)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            ValueCell(text: track?.bpm.map { String(format: "%.1f", $0) }, source: track?.bpmSource)
                .frame(width: 58, alignment: .leading)
            KeyCell(key: track?.key, camelot: track?.camelot, source: track?.keySource)
                .frame(width: 44, alignment: .leading)
            Text(track.map { TrackFormat.duration($0.duration) } ?? "").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var deck: some View {
        if let index = ["A", "B"].firstIndex(of: play.deck) {
            Text(play.deck)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 16, height: 16)
                .background(DeckStyle.gradient(index), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help("Played on deck \(play.deck)")
        } else {
            Image(systemName: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
                .help(play.deck.isEmpty ? "Played from a streaming service" : "Played through \(play.deck)")
        }
    }
}
