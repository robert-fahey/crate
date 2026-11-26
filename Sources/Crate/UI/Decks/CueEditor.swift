import AppKit
import CrateCore
import SwiftUI

/// The cue editor: a track's eight pads laid out along its waveform.
///
/// Each pad holds a hot cue or a saved loop. Drag a flag to move it (it lands on the beat unless
/// Shift is held), drag a loop's far edge to change its length, double-click the wave to put a cue
/// there. The rows below name them. "Suggest" fills the empty pads from the track's shape, and the
/// agent can be asked to do the same with more thought.
struct CueEditor: View {
    @Bindable var deck: DeckModel
    let model: AppModel
    let close: () -> Void

    /// Points of width per second of the track.
    @State private var scale = 28.0
    /// The moment at the left edge of the view, in seconds.
    @State private var start = 0.0
    @State private var follow = true
    @State private var selected: Int?
    @State private var drag: Drag?
    @State private var width: CGFloat = 1000
    @State private var watcher = ScrollWatcher()
    /// Earlier states of the pads, for Undo, and those undone, for Redo.
    @State private var undone: [[CuePoint]] = []
    @State private var history: [[CuePoint]] = []
    @FocusState private var naming: Int?
    /// The pad whose name is being typed, so that the typing is one step to undo.
    @State private var renaming: Int?

    private enum Drag {
        /// A cue held by its flag, and how far along the flag from the cue's own line the pointer took hold.
        case cue(Int, grabbed: CGFloat)
        case loopEnd(Int)
        case pan(from: Double)
    }

    private static let ruler: CGFloat = 22
    /// Two rows of flags: a cue that starts where another does (a loop at the track's start, say) goes on the second.
    private static let flagRow: CGFloat = 18
    private static let flags: CGFloat = 38

    private var cues: [CuePoint] { deck.cuePoints.values.sorted { $0.slot < $1.slot } }
    private var beat: Double { deck.grid.map { 60 / max(30, $0.bpm) } ?? 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            canvas
                .frame(minHeight: 190)
                .background(WavePalette.screenBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            WaveOverview(
                detail: deck.detail, peaks: deck.peaks, position: deck.position, duration: deck.duration,
                visibleSeconds: Double(width) / scale, isEnabled: deck.isLoaded,
                marks: WaveMarks(cues: deck.cues, loop: deck.loop)
            ) { seconds in
                deck.seek(to: seconds)
                start = clampStart(seconds - Double(width) * 0.3 / scale)
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            pads
            footer
        }
        .padding(16)
        .frame(minWidth: 1040, idealWidth: 1200, minHeight: 560, idealHeight: 600)
        .background(DeckStyle.panel)
        .environment(\.colorScheme, .dark)
        .onAppear {
            start = clampStart(deck.position - Double(width) * 0.2 / scale)
            watcher.onScroll = { event in scroll(event) }
            watcher.start()
            // A sheet puts the cursor in its first text field. Here that would send Space, which plays, into a name.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { naming = nil }
        }
        .onDisappear {
            watcher.stop()
            deck.endCueDrag()
        }
        .onChange(of: deck.position) { keepPlayheadInView() }
        .onChange(of: naming) { renaming = nil }
        .onDeleteCommand { if let selected, naming == nil { change { $0.removeAll { $0.slot == selected } } } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Cue Points").font(.title3.weight(.semibold))
            if let track = deck.track {
                Text(track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(cues.filter { !$0.isLoop }.count) cues").monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("\(cues.filter(\.isLoop).count) loops").monospacedDigit().foregroundStyle(WaveMarks.loopColor)
            if deck.grid == nil {
                Text("·").foregroundStyle(.secondary)
                Text("no beat grid yet, so nothing snaps").foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    // MARK: Canvas

    private func x(_ seconds: Double) -> CGFloat { CGFloat((seconds - start) * scale) }
    private func seconds(at x: CGFloat) -> Double { start + Double(x) / scale }

    private var canvas: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !deck.isPlaying)) { _ in
                let position = deck.deck.state().position
                Canvas { context, size in
                    draw(&context, size: size, position: position)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .gesture(
                SpatialTapGesture(count: 2).onEnded { tap in doubleClick(at: tap.location) }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { tap in click(at: tap.location) })
            )
            .onContinuousHover { phase in
                if case .active = phase { watcher.isHovering = true } else { watcher.isHovering = false }
            }
            .onAppear { width = geometry.size.width }
            .onChange(of: geometry.size.width) { width = geometry.size.width }
        }
        .help("Double-click the wave to put a cue there. Drag a flag to move it, or a loop's far edge to change its length (Shift: no snapping). Click a flag to select it, anywhere else to move the playhead. Drag the wave to scroll; pinch or ⌘-scroll to zoom.")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, position: Double) {
        let top = Self.ruler + Self.flags
        let waveHeight = size.height - top
        if let detail = deck.detail {
            var wave = context
            wave.translateBy(x: 0, y: top)
            wave.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: waveHeight)))
            WaveRenderer.draw(
                &wave, size: CGSize(width: size.width, height: waveHeight), detail: detail,
                frame: WaveFrame(position: start + Double(size.width) / 2 / scale), pointsPerSecond: scale,
                duration: deck.duration, waveOnly: true)
        }
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.ruler)), with: .color(.black.opacity(0.35)))

        // Bar lines, heavier every eight bars, where a phrase starts.
        if let grid = deck.grid, grid.count > 1 {
            let first = Int(grid.beatPosition(at: start).rounded(.down)), last = Int(grid.beatPosition(at: seconds(at: size.width)).rounded(.up))
            if last > first, last - first < 6000 {
                let spacing = size.width / CGFloat(last - first)
                for beat in first...last {
                    let inBar = grid.beatInBar(beat)
                    let bar = Int((Double(beat - grid.downbeat) / 4).rounded(.down)) + 1
                    let isPhrase = inBar == 1 && (beat - grid.phrase) % BeatGrid.beatsPerPhrase == 0
                    guard inBar == 1 || spacing >= 7 else { continue }
                    guard isPhrase || spacing * 4 >= 5 else { continue }
                    let at = x(grid.time(atBeat: Double(beat)))
                    let opacity = isPhrase ? 0.6 : (inBar == 1 ? 0.28 : 0.12)
                    context.fill(Path(CGRect(x: at - 0.5, y: Self.ruler, width: 1, height: size.height - Self.ruler)), with: .color(.white.opacity(opacity)))
                    if isPhrase || (inBar == 1 && spacing * 4 >= 34) {
                        context.draw(
                            Text("\(bar)").font(.system(size: 9, weight: isPhrase ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(.white.opacity(isPhrase ? 0.85 : 0.5)),
                            at: CGPoint(x: at + 3, y: Self.ruler - 8), anchor: .leading)
                    }
                }
            }
        }

        // Loops first, as shaded stretches, so the flags sit on top.
        for cue in cues {
            guard let end = cue.loopEnd else { continue }
            let left = x(cue.position), right = x(end)
            guard right > 0, left < size.width else { continue }
            let color = WaveMarks.color(forCue: cue.slot)
            let region = CGRect(x: left, y: Self.ruler, width: right - left, height: size.height - Self.ruler)
            context.fill(Path(region), with: .color(color.opacity(cue.slot == selected ? 0.26 : 0.15)))
            context.fill(Path(CGRect(x: right - 1, y: Self.ruler, width: 2, height: size.height - Self.ruler)), with: .color(color.opacity(0.9)))
            // The handle on the far edge.
            let handle = CGRect(x: right - 4, y: size.height - 26, width: 8, height: 20)
            context.fill(Path(roundedRect: handle, cornerRadius: 2.5), with: .color(color))
        }
        let flags = flagFrames
        for cue in cues {
            let at = x(cue.position)
            guard at > -160, at < size.width + 10 else { continue }
            let color = WaveMarks.color(forCue: cue.slot)
            let isSelected = cue.slot == selected
            context.fill(Path(CGRect(x: at - 0.75, y: Self.ruler, width: 1.5, height: size.height - Self.ruler)), with: .color(color))
            let label = Text(cue.name.isEmpty ? "\(cue.slot)" : "\(cue.slot)  \(cue.name)")
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.85))
            let resolved = context.resolve(label)
            let flag = flags[cue.slot] ?? CGRect(x: at, y: Self.ruler + 2, width: 18, height: Self.flagRow - 3)
            context.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(color))
            if isSelected {
                context.stroke(Path(roundedRect: flag.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4.5), with: .color(.white), lineWidth: 1.5)
            }
            context.draw(resolved, at: CGPoint(x: flag.minX + 5, y: flag.midY), anchor: .leading)
        }

        // The loop the deck is going round now, if any, as a line under the ruler.
        if let loop = deck.loop {
            let left = x(loop.lowerBound), right = x(loop.upperBound)
            context.fill(Path(CGRect(x: left, y: Self.ruler - 2, width: max(1, right - left), height: 2)), with: .color(WaveMarks.loopColor))
        }
        let playhead = x(position)
        if playhead >= 0, playhead <= size.width {
            context.fill(Path(CGRect(x: playhead - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
        }
    }

    // MARK: Pointer

    /// Where each cue's flag is drawn. A flag that would cover another goes on the second row.
    private var flagFrames: [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for cue in cues {
            // Near enough the width of the number and name in the flag's type.
            let width = CGFloat(cue.name.isEmpty ? 18 : 22 + cue.name.count * 6)
            var frame = CGRect(x: x(cue.position), y: Self.ruler + 2, width: width, height: Self.flagRow - 3)
            if frames.values.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(frame) }) { frame.origin.y += Self.flagRow }
            frames[cue.slot] = frame
        }
        return frames
    }

    /// The cue whose flag is under the pointer, or failing that whose line is.
    private func cue(at point: CGPoint) -> CuePoint? {
        let frames = flagFrames
        if let onFlag = cues.first(where: { frames[$0.slot]?.insetBy(dx: -3, dy: -3).contains(point) == true }) { return onFlag }
        guard point.y > Self.ruler + Self.flags else { return nil }
        return cues.filter { abs(x($0.position) - point.x) <= 5 }.min { abs(x($0.position) - point.x) < abs(x($1.position) - point.x) }
    }

    private func loopEnd(near x: CGFloat) -> CuePoint? {
        cues.first { cue in cue.loopEnd.map { abs(self.x($0) - x) <= 6 } == true }
    }

    /// Onto the nearest beat, unless Shift is held, Snap is off or there is no grid.
    private func snapped(_ seconds: Double) -> Double {
        guard !NSEvent.modifierFlags.contains(.shift), model.mixer.snap, let grid = deck.grid else { return max(0, seconds) }
        return max(0, grid.nearestBeat(to: seconds))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    if let cue = loopEnd(near: value.startLocation.x) {
                        remember()
                        drag = .loopEnd(cue.slot)
                        selected = cue.slot
                    } else if let cue = cue(at: value.startLocation) {
                        remember()
                        drag = .cue(cue.slot, grabbed: value.startLocation.x - x(cue.position))
                        selected = cue.slot
                    } else {
                        drag = .pan(from: start)
                        follow = false
                    }
                }
                switch drag {
                case .cue(let slot, let grabbed):
                    guard var cue = deck.cuePoints[slot] else { break }
                    let target = min(max(0, deck.duration - 0.05), snapped(seconds(at: value.location.x - grabbed)))
                    if let end = cue.loopEnd { cue.loopEnd = end + (target - cue.position) }
                    cue.position = target
                    deck.dragCuePoint(cue)
                case .loopEnd(let slot):
                    guard var cue = deck.cuePoints[slot] else { break }
                    let target = snapped(seconds(at: value.location.x))
                    cue.loopEnd = max(cue.position + beat / 4, min(deck.duration, target))
                    deck.dragCuePoint(cue)
                case .pan(let from):
                    start = clampStart(from - Double(value.translation.width) / scale)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                deck.endCueDrag()
                drag = nil
            }
    }

    private func click(at point: CGPoint) {
        naming = nil
        if let cue = cue(at: point) {
            selected = cue.slot
        } else {
            selected = nil
            deck.seek(to: max(0, seconds(at: point.x)))
        }
    }

    private func doubleClick(at point: CGPoint) {
        let x = point.x
        if let cue = cue(at: point) {
            // A flag double-clicked: play from there, as its pad would.
            selected = cue.slot
            deck.hotCue(cue.slot)
            return
        }
        guard let slot = CuePoint.slots.first(where: { deck.cuePoints[$0] == nil }) else {
            NSSound.beep()
            return
        }
        change { $0.append(CuePoint(slot: slot, position: snapped(seconds(at: x)))) }
        selected = slot
    }

    private func clampStart(_ value: Double) -> Double {
        max(-1, min(max(0, deck.duration - 1), value))
    }

    private func zoom(by factor: Double) {
        let middle = start + Double(width) / 2 / scale
        scale = max(3, min(600, scale * factor))
        start = clampStart(middle - Double(width) / 2 / scale)
    }

    private func scroll(_ event: NSEvent) {
        if event.type == .magnify {
            zoom(by: 1 + Double(event.magnification))
        } else if event.modifierFlags.contains(.command) {
            zoom(by: exp(Double(event.scrollingDeltaY) * 0.01))
        } else {
            var delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { delta *= 12 }
            guard delta != 0 else { return }
            follow = false
            start = clampStart(start - Double(delta) / scale)
        }
    }

    private func keepPlayheadInView() {
        guard follow, drag == nil else { return }
        let playhead = x(deck.position)
        if playhead < 0 || playhead > width * 0.9 { start = clampStart(deck.position - Double(width) * 0.12 / scale) }
    }

    private func show(_ seconds: Double) {
        let at = x(seconds)
        if at < 40 || at > width - 120 { start = clampStart(seconds - Double(width) * 0.25 / scale) }
    }

    // MARK: Changes

    /// Keeps the pads as they are now, so the change about to be made can be undone.
    private func remember() {
        history.append(cues)
        if history.count > 100 { history.removeFirst() }
        undone = []
    }

    private func change(_ edit: (inout [CuePoint]) -> Void) {
        var next = cues
        edit(&next)
        guard next != cues else { return }
        remember()
        deck.setCuePoints(next)
    }

    private func undo() {
        guard let before = history.popLast() else { return }
        undone.append(cues)
        deck.setCuePoints(before)
    }

    private func redo() {
        guard let after = undone.popLast() else { return }
        history.append(cues)
        deck.setCuePoints(after)
    }

    private func suggest(replacing: Bool) {
        let suggested = deck.suggestedCues()
        guard !suggested.isEmpty else { return }
        change { $0 = replacing ? suggested : CueSuggester.filling($0, with: suggested, beat: beat) }
    }

    /// How many beats a loop goes round, to the nearest quarter.
    private func loopBeats(_ cue: CuePoint) -> Double? {
        guard let end = cue.loopEnd, let grid = deck.grid else { return nil }
        return ((grid.beatPosition(at: end) - grid.beatPosition(at: cue.position)) * 4).rounded() / 4
    }

    private func setLoop(_ slot: Int, beats: Double?) {
        change { cues in
            guard let index = cues.firstIndex(where: { $0.slot == slot }) else { return }
            if let beats {
                let position = cues[index].position
                cues[index].loopEnd = deck.grid.map { $0.time(atBeat: $0.beatPosition(at: position) + beats) } ?? position + beats * beat
            } else {
                cues[index].loopEnd = nil
            }
        }
    }

    // MARK: Pads

    private var pads: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 5) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    padRow(row + 1)
                    padRow(row + 5)
                }
            }
        }
    }

    private func padRow(_ slot: Int) -> some View {
        let cue = deck.cuePoints[slot]
        let color = WaveMarks.color(forCue: slot)
        return HStack(spacing: 7) {
            Button("\(slot)") {
                selected = slot
                if cue == nil {
                    change { $0.append(CuePoint(slot: slot, position: snapped(deck.deck.state().position))) }
                } else {
                    deck.hotCue(slot)
                    if let cue { show(cue.position) }
                }
            }
            .buttonStyle(PadButtonStyle(isOn: cue != nil, color: color, minWidth: 28, height: 24))
            .help(cue == nil ? "Set pad \(slot) at the playhead" : "Play from pad \(slot), as hitting it on the deck does")
            if let cue {
                TextField("Name", text: Binding(
                    get: { deck.cuePoints[slot]?.name ?? "" },
                    set: { name in
                        guard var edited = deck.cuePoints[slot], edited.name != name else { return }
                        // Typing a name is one change to undo, not one a letter.
                        if renaming != slot {
                            remember()
                            renaming = slot
                        }
                        edited.name = String(name.prefix(24))
                        deck.setCuePoint(edited)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .focused($naming, equals: slot)
                    .frame(minWidth: 110)
                Text(clock(cue.position)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                Text(bar(of: cue.position)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                Menu {
                    Button("Not a Loop") { setLoop(slot, beats: nil) }
                    Divider()
                    ForEach([1.0, 2, 4, 8, 16, 32], id: \.self) { beats in
                        Button(beats == 1 ? "1 beat" : "\(Int(beats)) beats") { setLoop(slot, beats: beats) }
                    }
                } label: {
                    Label(loopBeats(cue).map { Self.beats($0) } ?? (cue.isLoop ? "Loop" : "Cue"), systemImage: cue.isLoop ? "repeat" : "flag.fill")
                        .foregroundStyle(cue.isLoop ? WaveMarks.loopColor : .secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(width: 96, alignment: .leading)
                .help("A plain cue, or a saved loop that goes round this many beats when its pad is hit")
                Button {
                    change { cues in
                        guard let index = cues.firstIndex(where: { $0.slot == slot }) else { return }
                        let target = snapped(deck.deck.state().position)
                        if let end = cues[index].loopEnd { cues[index].loopEnd = end + (target - cues[index].position) }
                        cues[index].position = target
                    }
                } label: { Image(systemName: "arrow.down.to.line") }
                    .buttonStyle(.borderless)
                    .help("Move this pad to the playhead")
                Button {
                    change { $0.removeAll { $0.slot == slot } }
                    if selected == slot { selected = nil }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Clear pad \(slot)")
            } else {
                Text("Empty").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(selected == slot ? color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = slot
            if let cue { show(cue.position) }
        }
    }

    private static func beats(_ beats: Double) -> String {
        beats == beats.rounded() ? "\(Int(beats)) beat\(beats == 1 ? "" : "s")" : String(format: "%.2g beats", beats)
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds - Double(Int(seconds) / 60 * 60))
    }

    private func bar(of seconds: Double) -> String {
        guard let grid = deck.grid else { return "" }
        let position = grid.beatPosition(at: seconds)
        let bar = Int(((position - Double(grid.downbeat)) / 4).rounded(.down)) + 1
        return "bar \(bar)"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .buttonStyle(PadButtonStyle(isOn: deck.isPlaying, color: DeckStyle.color(deck.id.rawValue), minWidth: 44))
            .keyboardShortcut(.space, modifiers: [])
            .help("Play or pause deck \(deck.id.name) (Space)")
            Button("FOLLOW") {
                follow.toggle()
                keepPlayheadInView()
            }
            .buttonStyle(PadButtonStyle(isOn: follow, color: .white, minWidth: 64))
            .help("Keep the playhead in view")
            Button("SNAP") { model.mixer.snap.toggle() }
                .buttonStyle(PadButtonStyle(isOn: model.mixer.snap, color: .white, minWidth: 48))
                .help("Cues and loop ends land on beats. Hold Shift while dragging to place one freely.")
            Button { zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(PadButtonStyle(minWidth: 30))
            Button { zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(PadButtonStyle(minWidth: 30))
            Button("Undo") { undo() }.buttonStyle(PadButtonStyle(minWidth: 46)).disabled(history.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { redo() }.buttonStyle(PadButtonStyle(minWidth: 46)).disabled(undone.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            if let activity = model.agent.activity {
                ProgressView().controlSize(.small)
                Text("Agent: \(activity)…").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu("Suggest") {
                Button("Fill the Empty Pads") { suggest(replacing: false) }
                Button("Replace Every Pad") { suggest(replacing: true) }
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(deck.grid == nil || deck.detail == nil)
            .help("Cues where the track changes (start, bass in, breakdowns and drops, outro) and four-bar loops at each end, worked out from the track's shape. Instant, and only as right as the beat grid.")
            Button("Ask the Agent") { askAgent() }
                .disabled(model.agent.phase != .ready)
                .help("Has the agent look at the track's structure and set cues and loops on the empty pads. Billed to your Cursor plan like any request.")
            Button("Clear All", role: .destructive) { change { $0 = [] } }.disabled(cues.isEmpty)
            Button("Done") { close() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func askAgent() {
        guard let track = deck.track else { return }
        model.ask("""
            Work out good hot cues and saved loops for the track with id \(track.id) (“\(track.title)”), which is on deck \(deck.id.name). \
            Keep the cues it already has, put the new ones on the free pads, and tell me in a line or two what you set.
            """)
    }
}
