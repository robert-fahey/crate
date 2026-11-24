import CrateCore
import SwiftUI

/// The decks: two stacked waveforms, each deck's controls, and the mixer between them.
struct DecksView: View {
    let model: AppModel
    /// The space the decks and the track list share, so large mode can size itself to fit.
    var available: CGSize = .zero
    /// Reports how tall the decks are, as they are hosted apart from the window's layout.
    var onHeight: (CGFloat) -> Void = { _ in }
    @AppStorage("wave.pointsPerSecond") private var zoom = WaveZoom.standard
    /// Large mode: taller waveforms and everything on the decks half as big again.
    @AppStorage("decks.large") private var isLarge = false

    private var mixer: DJMixer { model.mixer }
    /// Large mode is half as big again where there is room, and as big as fits where there is not:
    /// the decks must not run off the side of the window or squeeze the track list out.
    private var scale: CGFloat {
        guard isLarge else { return 1 }
        guard available.width > 0, available.height > 0 else { return 1.5 }
        let widest = available.width / 850      // the narrowest the compact decks can be
        let tallest = available.height * 0.72 / 540  // the compact decks' height, leaving room for the list
        return max(1, min(1.5, widest, tallest))
    }

    var body: some View {
        VStack(spacing: 8 * scale) {
            if let streaming = model.player.streaming {
                StreamingStrip(player: model.player, track: streaming)
            }
            ForEach(mixer.decks) { deck in
                HStack(spacing: 10) {
                    DeckHeader(deck: deck)
                    DeckWaveView(deck: deck, zoom: $zoom)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DeckStyle.color(deck.id.rawValue).opacity(deck.isPlaying ? 0.55 : 0.18), lineWidth: 1)
                        )
                }
                .frame(height: 70 + 180 * (scale - 1))
                .dropDestination(for: String.self) { items, _ in
                    let ids = items.flatMap { $0.split(separator: ",") }.compactMap { Int64($0) }
                    guard let id = ids.first else { return false }
                    model.load(trackID: id, on: deck.id)
                    return true
                }
            }
            HStack(alignment: .top, spacing: 10) {
                DeckControls(deck: mixer.deck(.a), zoom: zoom, editGrid: { model.gridEditing = .a }, editCues: { model.cueEditing = .a })
                MixerCenter(mixer: mixer, player: model.player, director: model.director, isLarge: $isLarge)
                DeckControls(deck: mixer.deck(.b), zoom: zoom, editGrid: { model.gridEditing = .b }, editCues: { model.cueEditing = .b })
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DeckStyle.backdrop)
        .environment(\.colorScheme, .dark)
        .environment(\.deckScale, scale)
    }
}

/// A Spotify or TIDAL track cannot go on a deck; it plays in its own app and is shown here.
private struct StreamingStrip: View {
    let player: PlayerController
    let track: Track

    var body: some View {
        HStack(spacing: 10) {
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.streamingIsPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PadButtonStyle(isOn: player.streamingIsPlaying, color: .green))
            .disabled(player.streamingIsPlaying && !player.canPause)
            Text(track.title).fontWeight(.semibold).lineLimit(1)
            Text("\(track.artist)  ·  playing in the \(track.source.displayName) app")
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(TrackFormat.duration(player.streamingPosition)) / \(TrackFormat.duration(track.duration))")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("Stop") { player.stop() }.buttonStyle(PadButtonStyle())
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DeckStyle.hairline))
    }
}

/// What is on a deck: a turning record, the title, a large tempo readout, key, time left and the beat of the bar.
private struct DeckHeader: View {
    let deck: DeckModel
    @Environment(\.deckScale) private var scale

    var body: some View {
        let colors = DeckStyle.colors(deck.id.rawValue)
        HStack(spacing: 10 * scale) {
            Platter(deck: deck).frame(width: 58 * scale, height: 58 * scale)
            if let track = deck.track {
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(track.title).font(.system(size: 13 * scale, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(deck.arrivingNote ?? deck.arriving.map { "Loading \($0.title)…" } ?? (track.artist.isEmpty ? " " : track.artist))
                        .font(.system(size: 11 * scale, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 7 * scale) {
                        if let key = track.key {
                            Text(key)
                                .font(.system(size: 10 * scale, weight: .heavy, design: .rounded))
                                .foregroundStyle(.black.opacity(0.8))
                                .padding(.horizontal, 5 * scale).padding(.vertical, 1.5 * scale)
                                .background(DeckStyle.keyColor(track.camelot), in: Capsule())
                                .fixedSize()
                        }
                        Text("-" + TrackFormat.duration(max(0, deck.duration - deck.position)))
                            .font(.system(size: 11 * scale, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize()
                        BeatDots(beat: deck.isPlaying ? deck.beatInBar : nil, colors: colors)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: -2) {
                    Text(deck.bpm.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 23 * scale, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .shadow(color: colors[0].opacity(deck.isPlaying ? 0.7 : 0), radius: 8)
                        .fixedSize()
                    Text("BPM").font(.system(size: 8.5 * scale, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(.white.opacity(0.45))
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deck \(deck.id.name)").font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                    Text(deck.arrivingNote ?? deck.arriving.map { "Loading \($0.title)…" } ?? "Empty")
                        .font(.system(size: 11 * scale, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 300 * scale, alignment: .leading)
        .help(deck.problem ?? deck.track.map { "\($0.title) — \($0.artist)" } ?? "Deck \(deck.id.name)")
    }
}

/// Four lights counting the beats of the bar; the first is the downbeat.
private struct BeatDots: View {
    let beat: Int?
    let colors: [Color]
    @Environment(\.deckScale) private var scale

    var body: some View {
        HStack(spacing: 3.5 * scale) {
            ForEach(1...4, id: \.self) { index in
                let lit = index == beat
                Circle()
                    .fill(lit ? (index == 1 ? Color.white : colors[0]) : Color.white.opacity(0.14))
                    .frame(width: 7 * scale, height: 7 * scale)
                    .shadow(color: lit ? (index == 1 ? Color.white : colors[0]).opacity(0.9) : .clear, radius: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A tiny heading over a group of controls.
private struct GroupLabel: View {
    let text: String
    @Environment(\.deckScale) private var scale
    var body: some View {
        Text(text).font(.system(size: 8.5 * scale, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(.white.opacity(0.4))
    }
}

// MARK: - One deck's controls

private struct DeckControls: View {
    @Bindable var deck: DeckModel
    let zoom: Double
    let editGrid: () -> Void
    var editCues: () -> Void = {}
    @Environment(\.deckScale) private var scale
    /// The width inside the card, which decides whether each row fits on one line.
    @State private var width: CGFloat = 600

    private var index: Int { deck.id.rawValue }
    private var color: Color { DeckStyle.color(index) }
    private var colors: [Color] { DeckStyle.colors(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            GeometryReader { geometry in
                WaveOverview(
                    detail: deck.detail, peaks: deck.peaks, position: deck.position, duration: deck.duration,
                    visibleSeconds: deck.detail == nil ? 0 : Double(geometry.size.width) * 2.2 / WaveZoom.clamp(zoom) * deck.tempo,
                    isEnabled: deck.isLoaded,
                    marks: WaveMarks(cues: deck.cues, loop: deck.loop)
                ) { seconds in
                    deck.jump(to: seconds)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(DeckStyle.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DeckStyle.hairline))
            }
            .frame(height: 28 * scale)
            // Each row is one line when there is room and two when the window is narrow. The choice is
            // made from the card's width; letting SwiftUI try both arrangements (ViewThatFits) cost a
            // full measurement of every control each time anything on the decks changed.
            if width >= 492 * scale {
                HStack(spacing: 7 * scale) {
                    transportButtons
                    Spacer(minLength: 4)
                    tempo
                }
            } else {
                transportButtons
                tempo
            }
            if width >= 424 * scale {
                HStack(alignment: .top, spacing: 12 * scale) {
                    tone
                    Spacer(minLength: 0)
                    loops
                }
            } else {
                tone
                loops
            }
            if width >= 536 * scale {
                HStack(alignment: .bottom, spacing: 6 * scale) {
                    cues
                    Spacer(minLength: 6)
                    effects
                }
            } else {
                cues
                effects
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .deckCard(tint: [color.opacity(0.55), color.opacity(0.04)])
        .disabled(!deck.isLoaded)
        .opacity(deck.isLoaded ? 1 : 0.55)
    }

    private var transportButtons: some View {
        HStack(spacing: 7 * scale) {
            // Acts on the way down and again on the way up, so the click itself does nothing.
            Button("CUE") {}
                .buttonStyle(TransportButtonStyle(isOn: deck.isCueing, colors: colors, size: 38) { down in
                    if down { deck.cueDown() } else { deck.cueUp() }
                })
                .help("Hold to play from the cue point; let go to return to it. While playing: back to the cue point and stop. Stopped somewhere else: sets the cue point there.")
            Button { deck.togglePlay() } label: {
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15 * scale, weight: .black))
            }
            .buttonStyle(TransportButtonStyle(isOn: deck.isPlaying, colors: colors, size: 38))
            .help(deck.isPlaying ? "Pause" : "Play")
            Button("SYNC") { deck.isSynced.toggle() }
                .buttonStyle(PadButtonStyle(isOn: deck.isSynced, color: Color(red: 0.35, green: 0.95, blue: 0.55), minWidth: 46))
                .help("Follow the other deck's tempo and stay on its beat")
            Button("MASTER") { deck.toggleMaster() }
                .buttonStyle(PadButtonStyle(isOn: deck.isMaster, color: Color(red: 1.0, green: 0.84, blue: 0.25), minWidth: 58))
                .help("The deck the other one follows. Crate picks the playing deck unless you choose.")
            Button("KEY") { deck.keyLock.toggle() }
                .buttonStyle(PadButtonStyle(isOn: deck.keyLock, color: Color(red: 0.35, green: 0.90, blue: 1.0), minWidth: 36))
                .help("Key lock: change tempo without changing pitch. Off is varispeed, like a turntable, and sounds cleaner.")
        }
    }

    private var tempo: some View {
        HStack(spacing: 6 * scale) {
            HoldButton(label: "−", color: color, minWidth: 24) { deck.bend($0 ? -0.04 : 0) }
                .help("Hold to pull this deck back a little")
            HoldButton(label: "+", color: color, minWidth: 24) { deck.bend($0 ? 0.04 : 0) }
                .help("Hold to push this deck ahead a little")
            HorizontalFader(
                value: Binding(get: { deck.tempoOffset }, set: { deck.setTempoOffset($0) }),
                range: -deck.tempoRange...deck.tempoRange, resting: 0, colors: colors, label: "Deck \(deck.id.name) tempo"
            )
            .frame(minWidth: 64 * scale, idealWidth: 110 * scale, maxWidth: 220 * scale)
            .help("Tempo. Double-click to reset.")
            Text(String(format: "%+.1f%%", deck.tempoOffset * 100))
                .font(.system(size: 11 * scale, weight: .bold, design: .rounded).monospacedDigit())
                .frame(width: 48 * scale, height: 22 * scale)
                .background(DeckStyle.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DeckStyle.hairline))
                .onTapGesture(count: 2) { deck.setTempoOffset(0) }
            Button(deck.tempoRange > 0.1 ? "±16" : "±8") { deck.tempoRange = deck.tempoRange > 0.1 ? 0.08 : 0.16 }
                .buttonStyle(PadButtonStyle(minWidth: 34))
                .help("Reach of the tempo fader")
        }
    }

    private var tone: some View {
        HStack(alignment: .top, spacing: 9 * scale) {
            Knob(value: $deck.trim, range: -12...12, resting: 0, label: "TRIM", color: .white)
            ForEach([2, 1, 0], id: \.self) { band in
                VStack(spacing: 4 * scale) {
                    Knob(value: $deck.eq[band], label: ["LOW", "MID", "HIGH"][band], color: color)
                    Button("KILL") { deck.kills[band].toggle() }
                        .buttonStyle(PadButtonStyle(isOn: deck.kills[band], color: Color(red: 1, green: 0.28, blue: 0.33), minWidth: 34, height: 18))
                        .help("Cut the \(["bass", "mids", "highs"][band]) completely")
                }
            }
            Knob(value: $deck.filter, label: "FILTER", color: Color(red: 0.75, green: 0.5, blue: 1.0))
        }
    }

    private var loops: some View {
        VStack(alignment: width >= 424 * scale ? .trailing : .leading, spacing: 6 * scale) {
            HStack(spacing: 4 * scale) {
                GroupLabel(text: "LOOP")
                Button("½") { deck.scaleLoop(by: 0.5) }.buttonStyle(PadButtonStyle(minWidth: 26))
                Button(loopLabel) { deck.toggleLoop() }
                    .buttonStyle(PadButtonStyle(isOn: deck.loop != nil, color: WaveMarks.loopColor, minWidth: 52))
                    .help("Loop from the current beat")
                Button("×2") { deck.scaleLoop(by: 2) }.buttonStyle(PadButtonStyle(minWidth: 26))
            }
            HStack(spacing: 4 * scale) {
                GroupLabel(text: "REPEAT")
                ForEach([(0.5, "½"), (0.25, "¼"), (0.125, "⅛")], id: \.1) { beats, label in
                    HoldButton(label: label, color: WaveMarks.loopColor, minWidth: 26) { deck.repeatBeat($0 ? beats : nil) }
                }
            }
            .help("Hold to repeat a fraction of a beat")
        }
    }

    private var loopLabel: String {
        let beats = deck.loopBeats
        return beats >= 1 ? "\(Int(beats)) beats" : "1/\(Int((1 / beats).rounded())) beat"
    }

    private var cues: some View {
        HStack(spacing: 4 * scale) {
            ForEach(1...8, id: \.self) { slot in
                Button("\(slot)") { deck.hotCue(slot) }
                    .buttonStyle(PadButtonStyle(isOn: deck.cues[slot] != nil, color: WaveMarks.color(forCue: slot), minWidth: 24, height: 24))
                    .contextMenu {
                        Button("Clear Cue \(slot)") { deck.clearHotCue(slot) }.disabled(deck.cues[slot] == nil)
                        Button("Edit Cue Points…") { editCues() }
                    }
                    .help(padHelp(slot))
            }
            Button("EDIT") { editCues() }
                .buttonStyle(PadButtonStyle(minWidth: 38, height: 24))
                .help("The cue editor: name the pads, move them along the waveform, make saved loops, and have cues suggested")
        }
    }

    private func padHelp(_ slot: Int) -> String {
        guard let cue = deck.cuePoints[slot] else { return "Set hot cue \(slot) here" }
        let name = cue.name.isEmpty ? "hot cue \(slot)" : "“\(cue.name)”"
        return cue.isLoop ? "Go to \(name) and loop it. Right-click to clear or edit." : "Jump to \(name). Right-click to clear or edit."
    }

    private var effects: some View {
        HStack(spacing: 4 * scale) {
            Button("ECHO") { deck.echoOn.toggle() }
                .buttonStyle(PadButtonStyle(isOn: deck.echoOn, color: .orange, minWidth: 44, height: 24))
                .contextMenu {
                    ForEach([(0.25, "1/4 beat"), (0.5, "1/2 beat"), (0.75, "3/4 beat"), (1.0, "1 beat")], id: \.1) { beats, label in
                        Button(label) { deck.echoBeats = beats }
                    }
                }
                .help("Echo in time with the beat. Right-click for the echo time.")
            Button("OUT") { deck.echoOut() }.buttonStyle(PadButtonStyle(minWidth: 34, height: 24))
                .help("Echo out: the deck drops away on the next beat and echoes into silence")
            Button("CUT") { deck.killEcho() }.buttonStyle(PadButtonStyle(minWidth: 34, height: 24))
                .help("Cut the echo tail dead")
            Button("STOP") { deck.tapeStop() }.buttonStyle(PadButtonStyle(minWidth: 38, height: 24))
                .help("Tape stop")
            Button("REW") { deck.rewind() }.buttonStyle(PadButtonStyle(minWidth: 34, height: 24))
                .help("Spin the record back")
            Menu {
                Button("Edit Grid…") { editGrid() }
                Divider()
                Button("Move Grid 5 ms Earlier") { deck.shiftGrid(milliseconds: -5) }
                Button("Move Grid 5 ms Later") { deck.shiftGrid(milliseconds: 5) }
                Button("Move Grid 1 ms Earlier") { deck.shiftGrid(milliseconds: -1) }
                Button("Move Grid 1 ms Later") { deck.shiftGrid(milliseconds: 1) }
                Divider()
                Button("Move Grid Half a Beat") { deck.shiftGridHalfBeat() }
                Button("Bar Starts Here") { deck.setDownbeatHere() }
                Divider()
                Button("Half Tempo") { deck.scaleGrid(by: 0.5) }
                Button("Double Tempo") { deck.scaleGrid(by: 2) }
            } label: {
                Text("GRID ▾")
            }
            .menuStyle(.button)
            .buttonStyle(PadButtonStyle(minWidth: 48, height: 24))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(deck.grid == nil)
            .help("Edit the beat grid if the lines are off the beat")
        }
    }
}

// MARK: - Mixer

private struct MixerCenter: View {
    @Bindable var mixer: DJMixer
    let player: PlayerController
    @Bindable var director: MixDirector
    @Binding var isLarge: Bool
    @AppStorage("sampler.shown") private var showsSampler = false
    @Environment(\.deckScale) private var scale

    var body: some View {
        VStack(spacing: 8 * scale) {
            HStack(alignment: .center, spacing: 7 * scale) {
                channel(mixer.deck(.a))
                VStack(spacing: 4 * scale) {
                    HStack(spacing: 2.5 * scale) {
                        LevelMeter(level: mixer.masterLevel)
                        LevelMeter(level: mixer.masterLevel)
                    }
                    .frame(height: 96 * scale)
                    Text(mixer.isClipping ? "CLIP" : "MASTER")
                        .font(.system(size: 8 * scale, weight: .heavy, design: .rounded)).tracking(1)
                        .foregroundStyle(mixer.isClipping ? Color.red : Color.white.opacity(0.45))
                }
                channel(mixer.deck(.b))
            }
            HStack(spacing: 6 * scale) {
                Text("A").font(.system(size: 10 * scale, weight: .black, design: .rounded)).foregroundStyle(DeckStyle.color(0))
                HorizontalFader(
                    value: $mixer.crossfader, range: -1...1, resting: 0,
                    colors: [DeckStyle.color(0), DeckStyle.color(1)], label: "Crossfader"
                )
                .help("Crossfader. Both decks are at full level across the middle. Double-click to centre.")
                Text("B").font(.system(size: 10 * scale, weight: .black, design: .rounded)).foregroundStyle(DeckStyle.color(1))
            }
            HStack(spacing: 5 * scale) {
                Button { mixer.toggleRecording() } label: {
                    HStack(spacing: 4 * scale) {
                        Circle().fill(mixer.isRecording ? Color.white : Color(red: 1, green: 0.25, blue: 0.3)).frame(width: 7 * scale, height: 7 * scale)
                        Text(mixer.isRecording ? TrackFormat.duration(mixer.recordedSeconds) : "REC").monospacedDigit()
                    }
                }
                .buttonStyle(PadButtonStyle(isOn: mixer.isRecording, color: Color(red: 1, green: 0.25, blue: 0.3), minWidth: 52))
                .help(mixer.isRecording ? "Stop recording" : "Record the mix to Music/Crate Recordings")
                Button("SNAP") { mixer.snap.toggle() }
                    .buttonStyle(PadButtonStyle(isOn: mixer.snap, color: .white, minWidth: 42))
                    .help("Cues, loops and jumps land on beats")
                Button("AUTO") { director.isAuto.toggle() }
                    .buttonStyle(PadButtonStyle(isOn: director.isAuto, color: Color(red: 0.4, green: 1.0, blue: 0.85), minWidth: 42))
                    .help("Auto DJ: tracks that are up next are mixed in, chosen by the agent, instead of starting cold")
            }
            HStack(spacing: 5 * scale) {
                ForEach(mixer.decks) { deck in
                    Button {
                        deck.cueMonitor.toggle()
                    } label: {
                        Label(deck.id.name, systemImage: "headphones").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(PadButtonStyle(isOn: deck.cueMonitor, color: DeckStyle.color(deck.id.rawValue), minWidth: 42))
                    .help("Headphone cue: hear deck \(deck.id.name) in the headphones before its fader is up")
                }
                Knob(value: $mixer.headphoneMix, range: 0...1, resting: 0.5, label: "CUE·MIX", size: 24)
                    .help("What the headphones hear: the cued decks at one end, the master mix at the other")
            }
            .disabled(!mixer.hasHeadphones)
            .opacity(mixer.hasHeadphones ? 1 : 0.4)
            .help(mixer.hasHeadphones
                ? "Headphones play through outputs 3-4 of \(mixer.outputName)"
                : "Headphone cue needs a sound card with four outputs, such as a DJ controller's")
            HStack(spacing: 8 * scale) {
                Knob(value: $mixer.masterVolume, range: 0...1, resting: 1, label: "VOLUME", size: 30)
                status.frame(maxWidth: .infinity, alignment: .leading)
                Button { showsSampler.toggle() } label: {
                    Image(systemName: "square.grid.3x2.fill")
                }
                .buttonStyle(PadButtonStyle(isOn: showsSampler, color: .white, minWidth: 26))
                .help(showsSampler ? "Hide the sampler" : "Show the sampler: eight pads for one-shot sounds and loops")
                Button { isLarge.toggle() } label: {
                    Image(systemName: isLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(PadButtonStyle(isOn: isLarge, color: .white, minWidth: 26))
                .help(isLarge ? "Compact decks" : "Large decks: taller waveforms and bigger controls")
            }
        }
        .frame(width: 186 * scale)
        .frame(maxHeight: .infinity)
        .deckCard()
    }

    @ViewBuilder
    private var status: some View {
        if let note {
            Text(note).font(.system(size: 10 * scale, weight: .medium, design: .rounded)).foregroundStyle(.orange).lineLimit(3)
        } else if let summary = director.summary {
            HStack(spacing: 4) {
                Text(summary).font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.4, green: 1.0, blue: 0.85)).lineLimit(2)
                if director.isBusy {
                    Button { director.cancel() } label: { Image(systemName: "xmark") }
                        .buttonStyle(PadButtonStyle(minWidth: 20, height: 20))
                        .help("Cancel this mix and take over by hand")
                }
            }
        } else if let activity = director.activity, director.isAuto {
            Text(activity).font(.system(size: 10 * scale, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
        } else if !player.upNext.isEmpty {
            Text("\(player.upNext.count) up next").font(.system(size: 10 * scale, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    private var note: String? {
        mixer.problem ?? player.problem ?? mixer.decks.compactMap(\.problem).first
    }

    private func channel(_ deck: DeckModel) -> some View {
        @Bindable var deck = deck
        return HStack(spacing: 4 * scale) {
            if deck.id == .b { LevelMeter(level: deck.level).frame(height: 96 * scale) }
            VerticalFader(value: $deck.fader, colors: DeckStyle.colors(deck.id.rawValue), label: "Deck \(deck.id.name) volume")
                .frame(height: 110 * scale)
            if deck.id == .a { LevelMeter(level: deck.level).frame(height: 96 * scale) }
        }
    }
}
