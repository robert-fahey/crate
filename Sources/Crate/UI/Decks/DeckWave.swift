import AppKit
import CrateCore
import SwiftUI

/// Per-deck motion state for a scrolling wave. Not observed: it is read and
/// advanced once per drawn frame.
@MainActor
final class WaveMotion {
    var isHovering = false
    var onScroll: ((NSEvent) -> Void)?
    private(set) var display = 0.0
    /// The loop the deck was going round when the wave was last drawn, and how many times it had been round.
    private(set) var loop: ClosedRange<Double>?
    private(set) var pass = 0

    private var lastDate: Date?
    private var born: Date?
    private var lastTarget = 0.0
    private var glide = 0.0
    private var level: CGFloat = 0
    private var monitor: Any?

    /// - Parameter state: where the deck is now and how fast it is moving, which tells ordinary
    ///   playback from a jump, and the loop it is going round.
    func advance(to date: Date, state: DeckState, level raw: CGFloat, reduceMotion: Bool) -> WaveFrame {
        let position = state.position, speed = state.speed
        let elapsed = lastDate.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        if born == nil {
            born = date
            lastTarget = position
        }
        lastDate = date

        // The deck moving at its own speed is followed exactly. A jump (a seek, a cue)
        // becomes a short glide, so the wave rushes to the new place instead of cutting.
        let expected = lastTarget + elapsed * speed
        var jump = position - expected
        let allowed = 0.2 + abs(speed) * 0.05
        // Going round a loop is not a jump: the wave is drawn unrolled and scrolls straight on.
        // The count of passes starts again with a new loop.
        let rounds = state.loopPass - (state.loop == loop ? pass : 0)
        if let length = state.loop.map({ $0.upperBound - $0.lowerBound }), rounds != 0, abs(jump + Double(rounds) * length) <= allowed {
            jump += Double(rounds) * length
        }
        loop = state.loop
        pass = state.loopPass
        if abs(jump) > allowed { glide -= jump }
        glide *= exp(-elapsed * 11)
        if abs(glide) < 0.004 || reduceMotion { glide = 0 }
        lastTarget = position
        display = position + glide

        let follow = raw > level ? 1 - exp(-elapsed * 45) : 1 - exp(-elapsed * 7)
        level += (raw - level) * CGFloat(follow)
        let age = reduceMotion ? 10 : date.timeIntervalSince(born ?? date)
        return WaveFrame(position: display, level: reduceMotion ? 0 : level, age: age, loop: loop, pass: pass)
    }

    func startWatchingScroll() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isHovering, let onScroll = self.onScroll else { return event }
            onScroll(event)
            return nil
        }
    }

    func stopWatchingScroll() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onScroll = nil
    }
}

/// The part of a deck's waveform that redraws every frame.
private struct MovingWave: View {
    let deck: Deck
    let motion: WaveMotion
    let detail: WaveDetail
    let marks: WaveMarks
    let pointsPerSecond: Double
    let duration: Double
    let level: CGFloat
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        // 60 frames a second is plenty, and the drawing itself happens off the main thread.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let state = deck.state()
            let frame = motion.advance(to: timeline.date, state: state, level: level, reduceMotion: reduceMotion)
            Canvas(rendersAsynchronously: true) { context, size in
                WaveRenderer.draw(
                    &context, size: size, detail: detail, frame: frame, pointsPerSecond: pointsPerSecond, duration: duration,
                    marks: marks)
            }
        }
    }
}

/// A deck's zoomed waveform, scrolling under a playhead fixed at the centre.
///
/// It is the record: drag it and the deck scratches, with sound, and spins back
/// up when you let go. Two-finger scroll nudges a playing deck ahead or back
/// (pitch bend) and scrubs a stopped one. Click a stopped deck to jump there.
/// Pinch or Command-scroll zooms both decks.
struct DeckWaveView: View {
    let deck: DeckModel
    @Binding var zoom: Double

    @State private var motion = WaveMotion()
    @State private var awake = true
    @State private var sleepTask: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    @State private var dragOrigin: Double?
    @State private var scrubbing = false
    @State private var pinchOrigin: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Points of width per second of the track. A faster deck is drawn more compressed,
    /// so two decks at the same tempo show the same spacing between beats.
    private var pointsPerSecond: Double { WaveZoom.clamp(zoom) / max(0.25, deck.tempo) }

    var body: some View {
        Group {
            if let detail = deck.detail, deck.isLoaded {
                wave(detail).id(deck.track?.id)
            } else {
                placeholder
            }
        }
        .background(WavePalette.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            if let arriving = deck.arriving {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text(deck.arrivingNote.map { "\(arriving.title): \($0)" } ?? "Loading \(arriving.title)…").lineLimit(1)
            } else if deck.isLoaded {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text("Drawing the waveform…")
            } else {
                Image(systemName: "waveform")
                Text("Deck \(deck.id.name) is empty. Drag a track here, or double-click one.")
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wave(_ detail: WaveDetail) -> some View {
        let marks = WaveMarks(grid: deck.grid, cues: deck.cues, cuePoint: deck.cuePoint, loop: deck.loop)
        let scale = pointsPerSecond
        let duration = deck.duration
        let level = CGFloat(deck.isPlaying ? deck.level : 0)
        let isActive = deck.isPlaying || awake
        return GeometryReader { geometry in
            // The moving picture lives in a host of its own: each frame it draws would
            // otherwise make SwiftUI lay the whole deck area out again.
            IsolatedHost {
                MovingWave(
                    deck: deck.deck, motion: motion, detail: detail, marks: marks, pointsPerSecond: scale, duration: duration,
                    level: level, isActive: isActive, reduceMotion: reduceMotion)
            }
            // Gestures go on a clear layer above the host, which is an AppKit view and would swallow them.
            .overlay(Color.clear
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(pinch)
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    // Only a stopped deck jumps on a click: a stray click must not move a deck that is playing out.
                    guard !deck.isPlaying else { return }
                    // Round a loop the wave shows its passes one after another: the click is on the track under it.
                    let place = motion.display + (tap.location.x - geometry.size.width / 2) / pointsPerSecond
                    deck.jump(
                        to: WaveUnroll.time(
                            at: place, reach: WaveRenderer.reach(width: geometry.size.width, pointsPerSecond: pointsPerSecond),
                            loop: motion.loop, pass: motion.pass))
                    stayAwake()
                }
            )
            .onContinuousHover { phase in
                if case .active = phase { motion.isHovering = true } else { motion.isHovering = false }
            }
            )
        }
        .onAppear {
            motion.onScroll = { event in scroll(event) }
            motion.startWatchingScroll()
            stayAwake(for: 1.2)
        }
        .onDisappear {
            motion.stopWatchingScroll()
            sleepTask?.cancel()
            settleTask?.cancel()
        }
        // While stopped nothing redraws, so wake up for anything that moves or marks the wave.
        .onChange(of: deck.position) { if !deck.isPlaying { stayAwake() } }
        .onChange(of: deck.isPlaying) { stayAwake() }
        .onChange(of: zoom) { stayAwake(for: 0.3) }
        .onChange(of: marks) { stayAwake(for: 0.3) }
        .help("Drag to scratch. Scroll to nudge a playing deck or scrub a stopped one. Pinch to zoom.")
        .accessibilityHidden(true)
    }

    private func stayAwake(for seconds: Double = 1.0) {
        awake = true
        sleepTask?.cancel()
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { awake = false }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragOrigin == nil {
                    settleTask?.cancel()
                    if !scrubbing { deck.beginScratch() }
                    scrubbing = false
                    dragOrigin = deck.deck.state().position
                }
                // The record moves with the pointer: pull left and the music runs forward.
                deck.scratch(to: (dragOrigin ?? 0) - value.translation.width / pointsPerSecond)
                stayAwake()
            }
            .onEnded { _ in
                dragOrigin = nil
                deck.endScratch()
                stayAwake(for: 1.4)
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let origin = pinchOrigin ?? WaveZoom.clamp(zoom)
                pinchOrigin = origin
                zoom = WaveZoom.clamp(origin * value.magnification)
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    private func scroll(_ event: NSEvent) {
        guard dragOrigin == nil else { return }
        if event.modifierFlags.contains(.command) {
            zoom = WaveZoom.clamp(WaveZoom.clamp(zoom) * exp(Double(event.scrollingDeltaY) * 0.01))
            return
        }
        var delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 12 }  // a notched mouse wheel reports lines, not points
        guard delta != 0 else { return }
        stayAwake()
        settleTask?.cancel()
        if deck.isPlaying, !scrubbing {
            // Nudge: speed the deck up or hold it back while the fingers move, like a hand on the platter.
            deck.bend(max(-0.2, min(0.2, -Double(delta) * 0.006)))
            settleTask = Task {
                try? await Task.sleep(for: .milliseconds(90))
                if !Task.isCancelled { deck.bend(0) }
            }
        } else {
            if !scrubbing {
                scrubbing = true
                deck.beginScratch()
            }
            deck.scratch(to: deck.deck.state().position - Double(delta) * 2.5 / pointsPerSecond)
            settleTask = Task {
                try? await Task.sleep(for: .milliseconds(160))
                if !Task.isCancelled {
                    scrubbing = false
                    deck.endScratch()
                }
            }
        }
    }
}
