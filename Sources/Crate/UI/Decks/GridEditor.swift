import AppKit
import CrateCore
import SwiftUI

/// Watches scrolling and pinching over a view, which SwiftUI does not report on the Mac.
@MainActor
final class ScrollWatcher {
    var isHovering = false
    var onScroll: ((NSEvent) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.isHovering, let onScroll = self.onScroll else { return event }
            onScroll(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onScroll = nil
    }
}

/// The beat grid editor, in the manner of Ableton's warp markers.
///
/// Markers (yellow) pin a beat to a moment in the audio. Double-click a beat
/// line to pin it, drag a marker onto the drum hit it belongs to, double-click
/// a marker to remove it. The beats between markers spread out evenly. Unlike
/// Ableton nothing is stretched: the markers only record where the beats are.
struct GridEditor: View {
    @Bindable var deck: DeckModel
    let close: () -> Void

    /// Points of width per second of the track.
    @State private var scale = 150.0
    /// The moment at the left edge of the view, in seconds.
    @State private var start = 0.0
    @State private var follow = true
    @State private var selected: Int?
    @State private var drag: Drag?
    @State private var width: CGFloat = 1000
    @State private var tempoText = ""
    @State private var watcher = ScrollWatcher()
    @State private var pinchOrigin: Double?
    @FocusState private var tempoFocused: Bool

    private enum Drag {
        case marker(Int)
        case pan(from: Double)
    }

    private static let ruler: CGFloat = 26
    private static let ticks: CGFloat = 12
    private static let markerColor = Color(red: 1.0, green: 0.82, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            canvas
                .frame(minHeight: 240)
                .background(WavePalette.screenBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            transport
            markerPanel
        }
        .padding(16)
        .frame(minWidth: 1000, idealWidth: 1180, minHeight: 440, idealHeight: 470)
        .background(DeckStyle.panel)
        .environment(\.colorScheme, .dark)
        .task { await deck.loadTransients() }
        .onAppear {
            start = max(0, deck.position - Double(width) * 0.2 / scale)
            watcher.onScroll = { event in scroll(event) }
            watcher.start()
        }
        .onDisappear {
            watcher.stop()
            if deck.metronome { deck.metronome = false }
        }
        .onChange(of: deck.position) { keepPlayheadInView() }
        .onChange(of: selected) { syncTempoText() }
        .onChange(of: deck.grid) { syncTempoText() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Beat Grid").font(.title3.weight(.semibold))
            if let track = deck.track {
                Text("\(track.title) — \(track.artist)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let grid = deck.grid {
                Text(String(format: "%.2f BPM overall", grid.bpm)).monospacedDigit()
                Text("·").foregroundStyle(.secondary)
                Text(grid.isSteady ? "steady tempo" : "tempo drifts").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text("\(grid.markers.count) markers").monospacedDigit().foregroundStyle(Self.markerColor)
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
                SpatialTapGesture(count: 2).onEnded { tap in doubleClick(at: tap.location.x) }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { tap in click(at: tap.location.x) })
            )
            .onContinuousHover { phase in
                if case .active = phase { watcher.isHovering = true } else { watcher.isHovering = false }
            }
            .onAppear { width = geometry.size.width }
            .onChange(of: geometry.size.width) { width = geometry.size.width }
        }
        .help("Double-click a beat line to add a marker. Drag a marker onto its drum hit (Shift: no snapping). Double-click a marker to remove it. Drag elsewhere to scroll; pinch to zoom.")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, position: Double) {
        let waveHeight = size.height - Self.ruler - Self.ticks
        if let detail = deck.detail {
            var wave = context
            wave.translateBy(x: 0, y: Self.ruler)
            wave.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: waveHeight)))
            WaveRenderer.draw(
                &wave, size: CGSize(width: size.width, height: waveHeight), detail: detail,
                frame: WaveFrame(position: start + Double(size.width) / 2 / scale), pointsPerSecond: scale,
                duration: deck.duration, waveOnly: true)
        }
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.ruler)), with: .color(.black.opacity(0.35)))

        // Drum attacks, along the bottom.
        for time in deck.transients where time >= start {
            let position = x(time)
            if position > size.width { break }
            context.fill(
                Path(CGRect(x: position - 0.5, y: size.height - Self.ticks + 2, width: 1, height: Self.ticks - 3)),
                with: .color(.white.opacity(0.45)))
        }

        guard let grid = deck.grid, grid.count > 1 else { return }
        let first = Int(grid.beatPosition(at: start).rounded(.down)), last = Int(grid.beatPosition(at: seconds(at: size.width)).rounded(.up))
        guard last > first, last - first < 4000 else { return }
        let spacing = size.width / CGFloat(last - first)
        // Label every beat when there is room, otherwise bars, otherwise every fourth bar.
        let labelEvery = spacing >= 30 ? 1 : (spacing >= 8 ? 4 : 16)
        for beat in first...last {
            let position = x(grid.time(atBeat: Double(beat)))
            let inBar = grid.beatInBar(beat)
            let bar = Int((Double(beat - grid.downbeat) / 4).rounded(.down)) + 1
            if inBar == 1 {
                context.fill(Path(CGRect(x: position - 0.5, y: Self.ruler, width: 1, height: size.height - Self.ruler - Self.ticks)), with: .color(.white.opacity(0.55)))
            } else if spacing >= 6 {
                context.fill(Path(CGRect(x: position - 0.5, y: Self.ruler, width: 1, height: size.height - Self.ruler - Self.ticks)), with: .color(.white.opacity(0.2)))
            }
            let isLabelled = labelEvery == 1 || (inBar == 1 && (labelEvery == 4 || (bar - 1) % 4 == 0))
            if isLabelled {
                context.draw(
                    Text(labelEvery == 1 ? "\(bar).\(inBar)" : "\(bar)")
                        .font(.system(size: 9, weight: inBar == 1 ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(inBar == 1 ? 0.85 : 0.5)),
                    at: CGPoint(x: position + 3, y: Self.ruler - 7), anchor: .leading)
            }
        }

        // Markers, and the tempo of each stretch between them.
        let visible = grid.markers.filter { $0 >= first - 1 && $0 <= last + 1 }
        for marker in visible {
            let position = x(grid.beats[marker])
            let isSelected = marker == selected
            context.fill(
                Path(CGRect(x: position - 0.75, y: 0, width: 1.5, height: size.height - Self.ticks)),
                with: .color(Self.markerColor.opacity(isSelected ? 1 : 0.8)))
            let handle = CGRect(x: position - 5, y: 1, width: 10, height: 13)
            context.fill(Path(roundedRect: handle, cornerRadius: 2.5), with: .color(Self.markerColor))
            if isSelected {
                context.stroke(Path(roundedRect: handle.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.white), lineWidth: 1.5)
            }
        }
        for (from, to) in zip(grid.markers, grid.markers.dropFirst()) where to >= first && from <= last {
            let left = x(grid.beats[from]), right = x(grid.beats[to])
            guard right - left > 64 else { continue }
            context.draw(
                Text(String(format: "%.2f", grid.segmentBPM(after: from)))
                    .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(Self.markerColor.opacity(0.85)),
                at: CGPoint(x: max(left, 0) + 9, y: Self.ruler + 9), anchor: .leading)
        }

        // Playhead.
        let playhead = x(position)
        if playhead >= 0, playhead <= size.width {
            context.fill(Path(CGRect(x: playhead - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
        }
    }

    // MARK: Pointer

    private func marker(near x: CGFloat) -> Int? {
        guard let grid = deck.grid else { return nil }
        return grid.markers.min { abs(self.x(grid.beats[$0]) - x) < abs(self.x(grid.beats[$1]) - x) }
            .flatMap { abs(self.x(grid.beats[$0]) - x) <= 7 ? $0 : nil }
    }

    /// The moment to put a dragged marker: on the nearest drum attack if one is close, unless Shift is held.
    private func snapped(_ seconds: Double) -> Double {
        guard !NSEvent.modifierFlags.contains(.shift), !deck.transients.isEmpty else { return seconds }
        let transients = deck.transients
        var low = 0, high = transients.count
        while low < high {
            let middle = (low + high) / 2
            if transients[middle] < seconds { low = middle + 1 } else { high = middle }
        }
        let nearest = [low - 1, low].filter { transients.indices.contains($0) }
            .min { abs(transients[$0] - seconds) < abs(transients[$1] - seconds) }
        guard let nearest, abs(transients[nearest] - seconds) * scale <= 9 else { return seconds }
        return transients[nearest]
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    if let beat = marker(near: value.startLocation.x) {
                        drag = .marker(beat)
                        selected = beat
                        deck.beginGridDrag()
                    } else {
                        drag = .pan(from: start)
                        follow = false
                    }
                }
                switch drag {
                case .marker(let beat):
                    let target = snapped(seconds(at: value.location.x))
                    deck.dragGrid { $0.movingMarker(atBeat: beat, to: target) }
                case .pan(let from):
                    start = clampStart(from - Double(value.translation.width) / scale)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .marker = drag { deck.endGridDrag() }
                drag = nil
            }
    }

    private func click(at x: CGFloat) {
        if let beat = marker(near: x) {
            selected = beat
        } else {
            deck.seek(to: max(0, seconds(at: x)))
        }
    }

    private func doubleClick(at x: CGFloat) {
        guard let grid = deck.grid else { return }
        if let beat = marker(near: x) {
            deck.editGrid { $0.removingMarker(atBeat: beat) }
            if selected == beat { selected = nil }
        } else {
            let beat = max(0, min(grid.count - 1, Int(grid.beatPosition(at: seconds(at: x)).rounded())))
            deck.editGrid { $0.addingMarker(atBeat: beat) }
            selected = beat
        }
    }

    private func clampStart(_ value: Double) -> Double {
        max(-1, min(max(0, deck.duration - 1), value))
    }

    private func zoom(by factor: Double) {
        // Keep the middle of the view where it is.
        let middle = start + Double(width) / 2 / scale
        scale = max(12, min(2400, scale * factor))
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

    /// While following, the view pages along so the playhead stays in sight.
    private func keepPlayheadInView() {
        guard follow, drag == nil else { return }
        let playhead = x(deck.position)
        if playhead < 0 || playhead > width * 0.9 { start = clampStart(deck.position - Double(width) * 0.12 / scale) }
    }

    // MARK: Controls

    private var transport: some View {
        HStack(spacing: 8) {
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .buttonStyle(PadButtonStyle(isOn: deck.isPlaying, color: DeckStyle.color(deck.id.rawValue), minWidth: 44))
            .keyboardShortcut(.space, modifiers: [])
            .help("Play or pause deck \(deck.id.name) (Space)")
            Button("METRONOME") { deck.metronome.toggle() }
                .buttonStyle(PadButtonStyle(isOn: deck.metronome, color: Self.markerColor, minWidth: 92))
                .help("A click on every beat of the grid, higher on the first beat of each bar")
            Button("FOLLOW") {
                follow.toggle()
                keepPlayheadInView()
            }
            .buttonStyle(PadButtonStyle(isOn: follow, color: .white, minWidth: 64))
            .help("Keep the playhead in view")
            if let bpm = deck.grid?.bpm(at: deck.position) {
                Text(String(format: "%.2f BPM at the playhead", bpm)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if deck.transients.isEmpty, deck.duration > TransientDetector.longestTrack {
                Text("Too long to show drum hits").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("−") { zoom(by: 1 / 1.5) }.buttonStyle(PadButtonStyle()).help("Zoom out")
            Button("+") { zoom(by: 1.5) }.buttonStyle(PadButtonStyle()).help("Zoom in")
            Button("Undo") { deck.undoGrid() }
                .buttonStyle(PadButtonStyle(minWidth: 48))
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!deck.canUndoGrid)
            Button("Redo") { deck.redoGrid() }
                .buttonStyle(PadButtonStyle(minWidth: 48))
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!deck.canRedoGrid)
        }
    }

    private var markerPanel: some View {
        HStack(spacing: 8) {
            if let selected, let grid = deck.grid, grid.isMarker(selected) {
                let bar = Int((Double(selected - grid.downbeat) / 4).rounded(.down)) + 1
                Text("Marker \(bar).\(grid.beatInBar(selected))  ·  \(clock(grid.beats[selected]))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Self.markerColor)
                Text("Seg. BPM").font(.callout).foregroundStyle(.secondary)
                TextField("", text: $tempoText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 74)
                    .focused($tempoFocused)
                    .onSubmit { applyTempo() }
                    .help("Tempo from this marker to the next. Press Return to apply.")
                Button("Set 1.1.1 Here") {
                    deck.editGrid { $0.settingDownbeat(at: $0.beats[selected]) }
                }
                .buttonStyle(PadButtonStyle(minWidth: 96))
                .help("Make this beat the first beat of a bar, and the start of a phrase")
                Button("Warp From Here (Straight)") { deck.editGrid { $0.straightened(from: selected) } }
                    .buttonStyle(PadButtonStyle(minWidth: 160))
                    .help("One fixed tempo from this marker to the end. Later markers are removed.")
                Button("Delete Marker") {
                    deck.editGrid { $0.removingMarker(atBeat: selected) }
                    self.selected = nil
                }
                .buttonStyle(PadButtonStyle(minWidth: 96))
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(grid.markers.count < 2)
            } else {
                Text("Double-click a beat line to pin it, then drag the marker onto its drum hit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(":2") { deck.scaleGrid(by: 0.5); selected = nil }.buttonStyle(PadButtonStyle()).help("Half tempo")
            Button("×2") { deck.scaleGrid(by: 2); selected = nil }.buttonStyle(PadButtonStyle()).help("Double tempo")
            Button(deck.isAnalysingGrid ? "Analysing…" : "Revert to Analysed") {
                selected = nil
                Task { await deck.revertGridToAnalysed() }
            }
            .buttonStyle(PadButtonStyle(minWidth: 124))
            .disabled(deck.isAnalysingGrid)
            .help("Throw away the edits and find the beats again. Can be undone.")
            Button("Done") { close() }
                .buttonStyle(PadButtonStyle(isOn: true, color: .white, minWidth: 60))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%06.3f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func syncTempoText() {
        guard !tempoFocused, let selected, let grid = deck.grid, grid.isMarker(selected) else { return }
        tempoText = String(format: "%.2f", grid.segmentBPM(after: selected))
    }

    private func applyTempo() {
        guard let selected, let bpm = Double(tempoText.replacingOccurrences(of: ",", with: ".")), bpm >= 30, bpm <= 300 else {
            tempoFocused = false
            return syncTempoText()
        }
        deck.editGrid { $0.settingSegmentTempo(after: selected, bpm: bpm) }
        tempoFocused = false
    }
}
