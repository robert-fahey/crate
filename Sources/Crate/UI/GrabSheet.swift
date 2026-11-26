import CrateCore
import SwiftUI

/// "Grab from TIDAL": type or paste what is wanted, check what TIDAL found, and download it with tiddl.
struct GrabSheet: View {
    @Bindable var grab: GrabModel
    let model: AppModel
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Grab from TIDAL", systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Text("\(grab.quality.displayName), into \((grab.folder as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("Change these in Settings > Services")
            }
            if let problem = grab.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    .textSelection(.enabled)
            }
            if grab.stage == .asking {
                asking
            } else {
                found
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
    }

    // MARK: Asking

    private var asking: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $grab.text)
                .font(.body)
                .focused($typing)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if grab.text.isEmpty {
                        Text("Larry Levan Stand On The Word\nhttps://tidal.com/track/16330447\nhttps://tidal.com/album/…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
            Text("One to a line: an artist and title, or a TIDAL link to a track, an album or a playlist. A pasted tracklist works: numbers and times at the start of a line are ignored.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            cratePicker
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { grab.isShown = false }.keyboardShortcut(.cancelAction)
                Button("Find on TIDAL") { grab.find() }.keyboardShortcut(.defaultAction).disabled(!grab.canFind)
            }
        }
        .onAppear { typing = true }
    }

    private var cratePicker: some View {
        HStack {
            Picker("Add to", selection: Binding(
                get: { grab.makesCrate ? -1 : (grab.crateID ?? 0) },
                set: { value in
                    grab.makesCrate = value == -1
                    grab.crateID = value > 0 ? value : nil
                })
            ) {
                Text("The library only").tag(Int64(0))
                Divider()
                ForEach(model.crates) { crate in Text(crate.name).tag(crate.id) }
                Divider()
                Text("A new crate…").tag(Int64(-1))
            }
            .frame(maxWidth: 320)
            if grab.makesCrate {
                TextField("Crate name", text: $grab.newCrateName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            Spacer()
        }
    }

    // MARK: What was found

    private var found: some View {
        VStack(alignment: .leading, spacing: 12) {
            if grab.stage == .choosing {
                Text("TIDAL's best match is chosen for each. Check the version and the length: the best match is often a radio edit, a remaster or a live recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            List(grab.rows) { row in
                GrabRow(row: row, canChoose: grab.stage == .choosing && !grab.isBusy) { grab.choose($0, for: row.id) }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if grab.stage == .choosing { cratePicker }
            HStack {
                if grab.stage == .finished, let summary = grab.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                } else if grab.isBusy {
                    ProgressView().controlSize(.small)
                    Text(grab.stage == .grabbing ? "Downloading…" : "Asking TIDAL…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                switch grab.stage {
                case .choosing:
                    Button("Back") { grab.back() }.disabled(grab.isBusy)
                    Button("Cancel", role: .cancel) { grab.isShown = false }.keyboardShortcut(.cancelAction)
                    Button(grab.chosenCount == 1 ? "Grab 1 Track" : "Grab \(grab.chosenCount) Tracks") { grab.grab() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(grab.isBusy || grab.chosenCount == 0)
                case .grabbing:
                    Button("Hide") { grab.isShown = false }
                        .keyboardShortcut(.cancelAction)
                        .help("The downloads carry on. Progress shows under the window's title.")
                default:
                    Button("Grab More") { grab.reset() }
                    if !grab.arrived.isEmpty {
                        Button("Show in Library") {
                            model.show(grab.arrived)
                            grab.isShown = false
                            grab.reset()
                        }
                    }
                    Button("Done") {
                        grab.isShown = false
                        grab.reset()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct GrabRow: View {
    let row: GrabModel.Row
    let canChoose: Bool
    let choose: (String?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark.frame(width: 18, height: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if row.matches.count > 1, canChoose {
                    Picker("", selection: Binding(get: { row.choice ?? "" }, set: { choose($0.isEmpty ? nil : $0) })) {
                        ForEach(row.matches) { hit in
                            Text(GrabRowText.line(hit)).tag(hit.id)
                        }
                        Divider()
                        Text(row.isDoubtful ? "None of these" : "Leave this one out").tag("")
                    }
                    .labelsHidden()
                } else {
                    Text(row.chosen?.name ?? row.matches.first?.name ?? row.asked)
                        .lineLimit(1)
                        .foregroundStyle(row.chosen == nil && !row.matches.isEmpty ? .secondary : .primary)
                }
                Text(detail).font(.caption).foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if row.matches.count == 1, canChoose, row.matches[0].isAvailable {
                Toggle("", isOn: Binding(get: { row.choice != nil }, set: { choose($0 ? row.matches[0].id : nil) }))
                    .labelsHidden().help("Grab this track")
            }
        }
        .padding(.vertical, 3)
    }

    private var isProblem: Bool {
        switch row.state {
        case .nothing, .failed: return true
        default: return false
        }
    }

    private var detail: String {
        switch row.state {
        case .finding: return "Looking for “\(row.asked)”…"
        case .nothing(let why): return why
        case .failed(let why): return why
        case .done(let track, let wasNew):
            let file = track.path.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
            return (wasNew ? "Downloaded" : "Already downloaded") + file
        case .found, .waiting, .downloading:
            guard let hit = row.chosen else {
                return row.isDoubtful
                    ? "Nothing on TIDAL looks like “\(row.asked)”. Choose one of its nearest matches if one is right."
                    : "Left out · asked for “\(row.asked)”"
            }
            var parts: [String] = []
            if !hit.album.isEmpty { parts.append(hit.album) }
            if hit.duration > 0 { parts.append(TrackFormat.duration(hit.duration)) }
            if let bpm = hit.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
            if !hit.isLossless, !hit.quality.isEmpty { parts.append("lossy only") }
            if row.replacing != nil { parts.append("takes the streaming track's place") }
            else if row.matches.count > 1 { parts.append("asked for “\(row.asked)”") }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch row.state {
        case .finding, .downloading: ProgressView().controlSize(.small)
        case .found:
            if row.chosen == nil, row.isDoubtful {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: row.chosen == nil ? "minus.circle" : "music.note").foregroundStyle(.secondary)
            }
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .nothing, .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .done(_, let wasNew): Image(systemName: wasNew ? "checkmark.circle.fill" : "checkmark.circle").foregroundStyle(.green)
        }
    }
}

enum GrabRowText {
    /// A match as one line of the menu: enough to tell the versions of a song apart.
    static func line(_ hit: Tiddl.Hit) -> String {
        var parts = [hit.name]
        if !hit.album.isEmpty { parts.append(hit.album) }
        parts.append(TrackFormat.duration(hit.duration))
        if !hit.isLossless { parts.append("lossy only") }
        if !hit.isAvailable { parts.append("not available") }
        return parts.joined(separator: " · ")
    }
}
