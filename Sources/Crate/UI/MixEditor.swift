import AppKit
import CrateCore
import SwiftUI

/// The mix editor: a crate as a mix, one transition at a time.
///
/// Down the left are the crate's tracks in order, with how each goes into the next. The transition
/// picked is laid out on the right as two waveforms in step: the track being left above, the track
/// coming in below, and the stretch where both play shaded. Drag either waveform to move where that
/// track is left or joined; they move a bar at a time. Whatever is changed here is saved with the
/// crate, and "Play Mix" plays the crate that way.
struct MixEditor: View {
    let model: AppModel
    let crateID: Int64
    let close: () -> Void

    @State private var tracks: [Track] = []
    @State private var saved: [MixStep] = []
    /// Grids and shapes of the tracks, read once each.
    @State private var sides: [Int64: MixSide] = [:]
    @State private var details: [Int64: WaveDetail] = [:]
    /// The outgoing track of the transition on show, by its place in the crate.
    @State private var selected = 0
    @State private var pointsPerBeat = 7.0
    @State private var drag: Drag?
    @State private var problem: String?
    @State private var history: [[MixStep]] = []

    private struct Drag {
        var lane: Int
        var startedAt: Double
    }

    private var store: LibraryStore { model.store }
    private var director: MixDirector { model.director }
    private var crate: Crate? { model.crates.first { $0.id == crateID } }

    private var pair: (from: Track, to: Track)? {
        tracks.indices.contains(selected) && tracks.indices.contains(selected + 1) ? (tracks[selected], tracks[selected + 1]) : nil
    }

    private func side(_ track: Track) -> MixSide { sides[track.id] ?? MixSide(track: track) }

    private func savedStep(_ index: Int) -> MixStep? {
        guard tracks.indices.contains(index + 1) else { return nil }
        return saved.first { $0.from == tracks[index].id && $0.to == tracks[index + 1].id }
    }

    /// The transition in force between a track and the next: the saved one, or what Crate would do.
    private func step(_ index: Int) -> MixStep? {
        guard tracks.indices.contains(index + 1) else { return nil }
        return savedStep(index) ?? MixPlanner.suggest(from: side(tracks[index]), to: side(tracks[index + 1]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 14) {
                trackList.frame(width: 330)
                Group {
                    if let pair, let step = step(selected) {
                        transition(step, from: pair.from, to: pair.to)
                    } else {
                        ContentUnavailableView(
                            "No transition to edit", systemImage: "arrow.triangle.merge",
                            description: Text(tracks.count < 2 ? "A mix needs at least two tracks in the crate." : "Pick a transition on the left."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 1180, idealWidth: 1280, minHeight: 640, idealHeight: 700)
        .background(DeckStyle.panel)
        .environment(\.colorScheme, .dark)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in reload() }
        .onDisappear { director.stopPreview() }
    }

    // MARK: Loading and saving

    private func reload() {
        tracks = ((try? store.tracks(inCrate: crateID)) ?? []).filter { $0.source == .local }
        saved = (try? store.mixSteps(crate: crateID)) ?? []
        for track in tracks where sides[track.id]?.grid == nil {
            let detail = try? store.waveDetail(id: track.id)
            details[track.id] = detail
            sides[track.id] = MixSide(track: track, grid: try? store.beatGrid(id: track.id), detail: detail)
        }
        selected = min(selected, max(0, tracks.count - 2))
    }

    /// Saves a transition: as the DJ's own, unless it is Crate's suggestion being put back.
    private func save(_ step: MixStep, from: Track, to: Track, by author: MixStep.Author = .you) {
        var step = MixPlanner.tidied(step, from: side(from), to: side(to))
        step.author = author
        guard savedStep(selected) != step else { return }
        history.append(saved)
        try? store.setMixSteps(crate: crateID, [step])
        saved = (try? store.mixSteps(crate: crateID)) ?? saved
    }

    private func undo() {
        guard let before = history.popLast() else { return }
        try? store.removeMixSteps(crate: crateID)
        try? store.setMixSteps(crate: crateID, before)
        saved = before
    }

    /// Saves Crate's own suggestion for every pair that has nothing saved.
    private func suggestAll() {
        var added: [MixStep] = []
        for index in tracks.indices.dropLast() where savedStep(index) == nil {
            added.append(MixPlanner.suggest(from: side(tracks[index]), to: side(tracks[index + 1])))
        }
        guard !added.isEmpty else { return }
        history.append(saved)
        try? store.setMixSteps(crate: crateID, added)
        saved = (try? store.mixSteps(crate: crateID)) ?? saved
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Mix").font(.title3.weight(.semibold))
            Text(crate?.name ?? "").foregroundStyle(.secondary)
            Spacer()
            let set = tracks.indices.dropLast().filter { savedStep($0) != nil }.count
            Text("\(tracks.count) tracks").monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("\(TrackFormat.duration(MixPlanner.length(of: tracks, steps: tracks.indices.dropLast().compactMap { step($0) }))) as a mix").monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("\(set) of \(max(0, tracks.count - 1)) transitions saved").monospacedDigit()
                .foregroundStyle(set == max(0, tracks.count - 1) ? Color(red: 0.4, green: 1.0, blue: 0.85) : .secondary)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                guard let crate else { return }
                close()
                Task { await director.playMix(crate) }
            } label: { Label("Play Mix", systemImage: "play.fill") }
                .disabled(tracks.count < 2)
                .help("Plays the crate from the top, each track going into the next as shown here. Where nothing is saved, Crate mixes its own way.")
            Button("Suggest the Rest") { suggestAll() }
                .disabled(tracks.indices.dropLast().allSatisfy { savedStep($0) != nil })
                .help("Saves Crate's own transition for every pair that has none: out where the first track thins, in at the next one's start. Instant, and only as right as the beat grids.")
            Button("Ask the Agent to Plan It") { askAgent() }
                .disabled(model.agent.phase != .ready || tracks.count < 2)
                .help("Has the agent look at the tracks' structure and save a transition for each pair, keeping the ones you set. Billed to your Cursor plan like any request.")
            Button("Undo") { undo() }.disabled(history.isEmpty).keyboardShortcut("z", modifiers: .command)
            if let activity = model.agent.activity {
                ProgressView().controlSize(.small)
                Text("Agent: \(activity)…").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else if let problem {
                Text(problem).font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Done") { close() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func askAgent() {
        guard let crate else { return }
        model.ask("""
            Plan the mix for the crate “\(crate.name)”: look at each track's structure and save a transition for every pair of \
            neighbouring tracks, keeping the ones I set myself and the order as it is. Tell me in a few lines what you chose.
            """)
    }

    // MARK: The crate, top to bottom

    private var trackList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).fontWeight(.semibold).lineLimit(1)
                            Text(track.artist.isEmpty ? "—" : track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(track.bpm.map { String(format: "%.1f", $0) } ?? "–").font(.callout.monospacedDigit())
                            Text(track.key ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    if index + 1 < tracks.count, let step = step(index) {
                        transitionRow(step, index: index, isSaved: savedStep(index) != nil)
                    }
                }
            }
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func transitionRow(_ step: MixStep, index: Int, isSaved: Bool) -> some View {
        let isSelected = index == selected
        return Button {
            selected = index
            problem = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                Text(Self.name(step.style) + (step.style.overlaps ? " · \(Int(step.beats)) beats" : ""))
                    .font(.callout.weight(isSaved ? .semibold : .regular))
                    .foregroundStyle(isSaved ? Color.white.opacity(0.92) : Color.white.opacity(0.5))
                Spacer(minLength: 4)
                Text(isSaved ? Self.by(step.author) : "auto")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .foregroundStyle(isSaved ? Color.black.opacity(0.8) : Color.white.opacity(0.5))
                    .background(isSaved ? Self.color(step.author) : Color.white.opacity(0.08), in: Capsule())
            }
            .padding(.leading, 30).padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.white.opacity(0.13) : Color.white.opacity(0.03))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSaved ? (step.note.isEmpty ? "Saved by \(Self.by(step.author).lowercased())" : step.note) : "Nothing saved: this is what Crate would do. Change anything and it is saved.")
    }

    static func name(_ style: CrateCore.Transition.Style) -> String {
        switch style {
        case .bassSwap: return "Bass swap"
        case .blend: return "Blend"
        case .filter: return "Filter"
        case .echoOut: return "Echo out"
        case .cut: return "Cut"
        case .tapeStop: return "Tape stop"
        }
    }

    private static func by(_ author: MixStep.Author) -> String {
        switch author {
        case .crate: return "Crate"
        case .agent: return "Agent"
        case .you: return "You"
        }
    }

    private static func color(_ author: MixStep.Author) -> Color {
        switch author {
        case .crate: return Color.white.opacity(0.75)
        case .agent: return Color(red: 0.72, green: 0.6, blue: 1.0)
        case .you: return Color(red: 0.4, green: 1.0, blue: 0.85)
        }
    }

    // MARK: One transition

    private func transition(_ step: MixStep, from: Track, to: Track) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(from.title)  →  \(to.title)").font(.headline).lineLimit(1)
                Spacer()
                Text(tempos(from, to)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            canvas(step, from: from, to: to)
                .frame(minHeight: 250)
                .background(WavePalette.screenBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                ForEach(CrateCore.Transition.Style.allCases, id: \.self) { style in
                    Button(Self.name(style)) {
                        var changed = step
                        changed.style = style
                        // The note said why the old style was chosen.
                        if style != step.style { changed.note = "" }
                        save(changed, from: from, to: to)
                    }
                    .buttonStyle(PadButtonStyle(isOn: step.style == style, color: .white, minWidth: 74))
                    .help(Self.explain(style))
                }
                Spacer(minLength: 12)
                Text("LENGTH").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(.secondary)
                ForEach(MixPlanner.lengths, id: \.self) { beats in
                    Button("\(Int(beats))") {
                        var changed = step
                        changed.beats = beats
                        save(changed, from: from, to: to)
                    }
                    .buttonStyle(PadButtonStyle(isOn: step.style.overlaps && step.beats == beats, color: WaveMarks.loopColor, minWidth: 34))
                    .disabled(!step.style.overlaps)
                    .help("The two tracks overlap for \(Int(beats)) beats")
                }
            }
            place("Leave", track: from, at: step.outAt, color: DeckStyle.color(0)) { bars in
                var changed = step
                changed.outAt = moved(step.outAt, bars: bars, in: from)
                save(changed, from: from, to: to)
            }
            place("Come in on", track: to, at: step.inAt, color: DeckStyle.color(1)) { bars in
                var changed = step
                changed.inAt = moved(step.inAt, bars: bars, in: to)
                save(changed, from: from, to: to)
            }
            if !step.note.isEmpty {
                Label(step.note, systemImage: step.author == .agent ? "sparkles" : "text.quote").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if director.isPreviewing {
                    Button { director.stopPreview() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { preview(step) } label: { Label("Preview", systemImage: "play.fill") }
                        .help("Plays the first track from two bars before the mix, then the mix itself, on the two decks")
                }
                Button { pointsPerBeat = max(2.5, pointsPerBeat / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { pointsPerBeat = min(24, pointsPerBeat * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                Spacer()
                Button("Crate's Suggestion") { save(MixPlanner.suggest(from: side(from), to: side(to)), from: from, to: to, by: .crate) }
                    .help("Puts this transition back to what Crate would do")
                Button("Clear", role: .destructive) {
                    history.append(saved)
                    try? store.removeMixSteps(crate: crateID, pairs: [(from: from.id, to: to.id)])
                    saved = (try? store.mixSteps(crate: crateID)) ?? saved
                }
                .disabled(savedStep(selected) == nil)
                .help("Forgets what is saved for this pair; Crate decides when the mix is played")
            }
        }
    }

    private func preview(_ step: MixStep) {
        problem = nil
        Task {
            do {
                try await director.preview(step)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private static func explain(_ style: CrateCore.Transition.Style) -> String {
        switch style {
        case .bassSwap: return "The new track comes in without its bass; halfway through, the bass changes hands"
        case .blend: return "A plain crossfade"
        case .filter: return "As a bass swap, with the old track filtered away"
        case .echoOut: return "The old track echoes out on one beat and the new one starts"
        case .cut: return "A hard switch on the beat"
        case .tapeStop: return "The old track slows to a stop; the new one starts a bar later"
        }
    }

    private func tempos(_ from: Track, _ to: Track) -> String {
        guard let a = side(from).grid?.bpm ?? from.bpm, let b = side(to).grid?.bpm ?? to.bpm else { return "" }
        let keys = [from.key, to.key].compactMap { $0 }.joined(separator: " → ")
        return String(format: "%.1f → %.1f BPM (%+.1f%%)", a, b, (b / a - 1) * 100) + (keys.isEmpty ? "" : "   \(keys)")
    }

    /// A time moved by so many bars along a track's grid.
    private func moved(_ seconds: Double, bars: Int, in track: Track) -> Double {
        guard let grid = side(track).grid else { return max(0, seconds + Double(bars) * 2) }
        return max(0, min(track.duration - 1, grid.time(atBeat: grid.beatPosition(at: seconds) + Double(bars * BeatGrid.beatsPerBar))))
    }

    /// A line saying where a track is left or joined, with buttons to move the place by a bar or a phrase.
    private func place(_ verb: String, track: Track, at seconds: Double, color: Color, move: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(verb) \(track.title) at").lineLimit(1)
            Text(TrackFormat.duration(seconds)).monospacedDigit().fontWeight(.semibold)
            Text(whereabouts(seconds, in: track)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            ForEach([(-8, "backward.end.fill", "Eight bars earlier"), (-1, "chevron.left", "A bar earlier"), (1, "chevron.right", "A bar later"), (8, "forward.end.fill", "Eight bars later")], id: \.0) { bars, icon, help in
                Button { move(bars) } label: { Image(systemName: icon).frame(width: 16) }
                    .buttonStyle(PadButtonStyle(minWidth: 28, height: 22))
                    .help(help)
            }
        }
        .font(.callout)
    }

    private func whereabouts(_ seconds: Double, in track: Track) -> String {
        let side = side(track)
        guard let grid = side.grid else { return "" }
        let bar = Int(((grid.beatPosition(at: seconds) - Double(grid.downbeat)) / 4).rounded(.down)) + 1
        let part = side.structure?.phrases.last { $0.time <= seconds + 0.05 }?.label
        return "bar \(bar)" + (part.map { " · \($0)" } ?? "")
    }

    // MARK: The two waveforms

    /// Where the mix starts, across the view.
    private static let origin = 0.3

    private func canvas(_ step: MixStep, from: Track, to: Track) -> some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !director.isPreviewing)) { _ in
                Canvas { context, size in
                    draw(&context, size: size, step: step, from: from, to: to)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if drag == nil {
                            let lane = value.startLocation.y < geometry.size.height / 2 ? 0 : 1
                            drag = Drag(lane: lane, startedAt: lane == 0 ? step.outAt : step.inAt)
                        }
                        guard let drag else { return }
                        // Dragging the wave to the right brings an earlier part of it to the line: a bar at a time.
                        let bars = Int((-Double(value.translation.width) / pointsPerBeat / 4).rounded())
                        var changed = step
                        if drag.lane == 0 {
                            changed.outAt = moved(drag.startedAt, bars: bars, in: from)
                        } else {
                            changed.inAt = moved(drag.startedAt, bars: bars, in: to)
                        }
                        if changed != step { save(changed, from: from, to: to) }
                    }
                    .onEnded { _ in drag = nil }
            )
        }
        .help("Drag the upper waveform to move where the first track is left, the lower to move where the next comes in. They move a bar at a time. The shaded stretch is where both play.")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, step: MixStep, from: Track, to: Track) {
        let origin = size.width * Self.origin
        let gap: CGFloat = 6, label: CGFloat = 18
        let laneHeight = (size.height - gap) / 2
        let length = step.style.overlaps ? step.beats : 0
        let end = origin + CGFloat(length * pointsPerBeat)

        // The stretch where both tracks play.
        if length > 0 {
            context.fill(Path(CGRect(x: origin, y: 0, width: end - origin, height: size.height)), with: .color(WaveMarks.loopColor.opacity(0.10)))
        }

        for lane in 0..<2 {
            let track = lane == 0 ? from : to
            let anchor = lane == 0 ? step.outAt : step.inAt
            let top = CGFloat(lane) * (laneHeight + gap)
            let color = DeckStyle.color(lane)
            let side = side(track)
            let bpm = side.grid.map { $0.bpm(at: anchor) } ?? track.bpm ?? 120
            let pointsPerSecond = pointsPerBeat * bpm / 60

            if let detail = details[track.id] {
                var wave = context
                wave.translateBy(x: 0, y: top + label)
                wave.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: laneHeight - label)))
                WaveRenderer.draw(
                    &wave, size: CGSize(width: size.width, height: laneHeight - label), detail: detail,
                    frame: WaveFrame(position: anchor + Double(size.width / 2 - origin) / pointsPerSecond), pointsPerSecond: pointsPerSecond,
                    duration: track.duration, waveOnly: true)
            } else {
                context.draw(
                    Text("Not analysed yet").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: top + laneHeight / 2))
            }

            // Bar lines of this track's own grid, heavier where a phrase starts.
            if let grid = side.grid {
                let anchorBeat = grid.beatPosition(at: anchor)
                let first = Int((anchorBeat - Double(origin) / pointsPerBeat).rounded(.down)), last = Int((anchorBeat + Double(size.width - origin) / pointsPerBeat).rounded(.up))
                if last > first, last - first < 3000 {
                    for beat in first...last where grid.beatInBar(beat) == 1 {
                        let at = origin + CGFloat((Double(beat) - anchorBeat) * pointsPerBeat)
                        let isPhrase = (beat - grid.phrase) % BeatGrid.beatsPerPhrase == 0
                        guard isPhrase || pointsPerBeat * 4 >= 9 else { continue }
                        context.fill(Path(CGRect(x: at - 0.5, y: top + label, width: 1, height: laneHeight - label)), with: .color(.white.opacity(isPhrase ? 0.5 : 0.14)))
                    }
                }
            }

            // What is not heard: the incoming track before it comes in, the outgoing one once it has gone.
            let silent = lane == 0
                ? CGRect(x: end, y: top + label, width: max(0, size.width - end), height: laneHeight - label)
                : CGRect(x: 0, y: top + label, width: origin, height: laneHeight - label)
            context.fill(Path(silent), with: .color(.black.opacity(0.62)))

            // How the fader (solid) and the bass (dashed) of this track move through the mix.
            if length > 0 {
                let transition = CrateCore.Transition(style: step.style, beats: step.beats, startBeat: 0, incomingBeat: 0)
                var fader = Path(), bass = Path()
                for index in 0...60 {
                    let progress = Double(index) / 60
                    let levels = transition.levels(at: progress)
                    let x = origin + CGFloat(progress) * (end - origin)
                    let reach = laneHeight - label - 8
                    let faderY = top + label + 4 + reach * CGFloat(1 - (lane == 0 ? levels.outgoingFader : levels.incomingFader))
                    let bassY = top + label + 4 + reach * CGFloat(1 - (lane == 0 ? levels.outgoingLow : levels.incomingLow))
                    if index == 0 {
                        fader.move(to: CGPoint(x: x, y: faderY))
                        bass.move(to: CGPoint(x: x, y: bassY))
                    } else {
                        fader.addLine(to: CGPoint(x: x, y: faderY))
                        bass.addLine(to: CGPoint(x: x, y: bassY))
                    }
                }
                context.stroke(bass, with: .color(Color(red: 0.45, green: 0.6, blue: 1).opacity(0.95)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.stroke(fader, with: .color(.white.opacity(0.95)), lineWidth: 1.75)
            }

            // The lane's name, and where it is at the line.
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: label)), with: .color(.black.opacity(0.4)))
            context.draw(
                Text("\(lane == 0 ? "OUT" : "IN")  \(track.title)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(color),
                at: CGPoint(x: 8, y: top + label / 2), anchor: .leading)
            context.draw(
                Text(TrackFormat.duration(anchor)).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85)),
                at: CGPoint(x: origin + 5, y: top + label / 2), anchor: .leading)

            // Where a deck that is playing this track has got to.
            if let deck = model.mixer.decks.first(where: { $0.track?.id == track.id && $0.isPlaying }) {
                let position = deck.deck.state().position
                let x = origin + CGFloat((position - anchor) * pointsPerSecond)
                if x >= 0, x <= size.width {
                    context.fill(Path(CGRect(x: x - 0.75, y: top, width: 1.5, height: laneHeight)), with: .color(.white))
                }
            }
        }

        // The line the mix starts on, and the one it ends on.
        context.fill(Path(CGRect(x: origin - 1, y: 0, width: 2, height: size.height)), with: .color(WaveMarks.loopColor))
        if length > 0 {
            context.fill(Path(CGRect(x: end - 0.5, y: 0, width: 1, height: size.height)), with: .color(WaveMarks.loopColor.opacity(0.7)))
            context.draw(
                Text("\(Self.name(step.style).uppercased())  ·  \(Int(step.beats)) BEATS").font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(WaveMarks.loopColor),
                at: CGPoint(x: (origin + end) / 2, y: size.height / 2), anchor: .center)
        } else {
            context.draw(
                Text(Self.name(step.style).uppercased()).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(WaveMarks.loopColor),
                at: CGPoint(x: origin + 6, y: size.height / 2), anchor: .leading)
        }
    }
}
