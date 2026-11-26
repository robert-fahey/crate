import AppKit
import CrateCore
import SwiftUI
import UniformTypeIdentifiers

/// The sampler: under the decks, a row of eight pads for each deck (its sample bank). Hit a pad
/// and its sound plays. The label at the start of a row names the bank and opens its menu: other
/// banks, new ones, and tying the bank to the track on that deck.
/// Each pad is one of two things: a one-shot, which plays from the top at every hit, or a mini
/// deck, which loops until stopped and shows its waveform, its playhead and its tempo.
///
/// A pad takes an audio file dragged from the Finder, a track dragged from the list (its first
/// two minutes at most), or the loop a deck is playing. Right-click a pad for the rest.
/// Q puts every hit on the playing deck's grid; a loop with Sync on (the metronome mark) keeps to its tempo.
struct SamplerStrip: View {
    let model: AppModel
    static let height: CGFloat = 108

    private var sampler: SamplerModel { model.mixer.sampler }
    @State private var renaming: DeckID?
    @State private var newName = ""
    @State private var deleting: DeckID?

    var body: some View {
        @Bindable var sampler = model.mixer.sampler
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Knob(value: $sampler.level, range: 0...1.5, resting: 1, label: "SAMPLER", size: 24)
                    .help("The sampler's level in the mix. Double-click for full.")
            }
            .frame(width: 58)
            if model.mixer.hasHeadphones {
                Button { sampler.cue.toggle() } label: { Image(systemName: "headphones") }
                    .buttonStyle(PadButtonStyle(isOn: sampler.cue, color: .white, minWidth: 28))
                    .help("Hear the sampler in the headphones, whatever its level")
            }
            Button { sampler.isQuantized.toggle() } label: {
                VStack(spacing: 0) {
                    Text("Q").font(.system(size: 12, weight: .black, design: .rounded))
                    Text(Self.short(sampler.quantum)).font(.system(size: 8, weight: .bold, design: .rounded)).opacity(0.75)
                }
            }
            .buttonStyle(PadButtonStyle(isOn: sampler.isQuantized, color: .white, minWidth: 30))
            .help("Quantize: pad hits land on the \(sampler.quantum == 4 ? "bar" : "beat grid (\(SamplerModel.gridName(sampler.quantum)))") of the deck that is playing. Right-click to change the grid.")
            .contextMenu {
                Toggle("Quantize", isOn: $sampler.isQuantized)
                Picker("Grid", selection: $sampler.quantum) {
                    ForEach(SamplerSync.grids, id: \.self) { Text(SamplerModel.gridName($0)).tag($0) }
                }
            }
            VStack(spacing: 6) {
                ForEach(DeckID.allCases) { deck in
                    HStack(spacing: 8) {
                        bankLabel(deck)
                        ForEach(sampler.pads(of: deck)) { pad in
                            SamplerPadView(model: model, pad: pad)
                        }
                    }
                }
            }
            Button { sampler.stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(PadButtonStyle(minWidth: 28))
                .help("Stop every pad")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(DeckStyle.base)
        .overlay(alignment: .bottomLeading) {
            if let problem = sampler.problem {
                Text(problem).font(.caption2).foregroundStyle(.orange).padding(.leading, 82).padding(.bottom, 1)
            }
        }
        .alert("Rename Sample Bank", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { sampler.renameBank(on: renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete the sample bank “\(deleting.flatMap { sampler.bank(on: $0)?.name } ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { deck in
            Button("Delete Bank", role: .destructive) { sampler.deleteBank(on: deck) }
        } message: { _ in
            Text("Its pads are forgotten. The audio files stay where they are.")
        }
    }

    /// The name of the bank a deck has up, which is also the menu for changing it.
    private func bankLabel(_ deck: DeckID) -> some View {
        let color = DeckStyle.color(deck.rawValue)
        let bank = sampler.bank(on: deck)
        let track = model.mixer.deck(deck).track
        let isTied = sampler.bankIsTied[deck.rawValue]
        return Menu {
            Section("Sample Bank on Deck \(deck.name)") {
                ForEach(sampler.banks) { each in
                    let elsewhere = each.id == sampler.bankOn[deck.other.rawValue]
                    Toggle(elsewhere ? "\(each.name) (on Deck \(deck.other.name))" : each.name, isOn: Binding(
                        get: { each.id == sampler.bankOn[deck.rawValue] }, set: { if $0 { sampler.show(each.id, on: deck) } }))
                        .disabled(elsewhere)
                }
            }
            Divider()
            Button("New Bank") { sampler.newBank(on: deck) }
            Button("Duplicate Bank") { sampler.duplicateBank(on: deck) }
            Button("Rename Bank…") {
                newName = bank?.name ?? ""
                renaming = deck
            }
            Button("Delete Bank…", role: .destructive) { deleting = deck }
            Divider()
            Toggle(
                track.map { "Bring This Bank Up with “\($0.title)”" } ?? "Bring This Bank Up with the Track on Deck \(deck.name)",
                isOn: Binding(get: { isTied }, set: { sampler.setBankTied($0, on: deck) }))
                .disabled(track == nil)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(deck.name).font(.system(size: 11, weight: .black, design: .rounded)).foregroundStyle(color)
                    if isTied {
                        Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundStyle(color.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                }
                Text(bank?.name ?? "No bank").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .frame(width: 78, height: 42, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isTied
            ? "Deck \(deck.name)'s sample bank, “\(bank?.name ?? "")”. It comes up whenever “\(track?.title ?? "")” is loaded. Click for other banks."
            : "Deck \(deck.name)'s sample bank, “\(bank?.name ?? "")”. Click for other banks, or to have this one come up with the track on the deck.")
    }

    /// A grid size under the Q: "1", "¼", "BAR".
    private static func short(_ beats: Double) -> String {
        switch beats {
        case 0.25: return "¼"
        case 0.5: return "½"
        case 4: return "BAR"
        default: return "1"
        }
    }
}

private struct SamplerPadView: View {
    let model: AppModel
    let pad: SamplerModel.Pad
    @State private var isTargeted = false

    private var sampler: SamplerModel { model.mixer.sampler }
    private var color: Color { WaveMarks.color(forCue: pad.slot + 1) }

    var body: some View {
        // A loaded pad sounds as the mouse goes down, not when it comes up. An empty one asks for a file.
        Button {
            if !pad.isLoaded, !pad.isLoading { chooseFile() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(pad.slot + 1)").font(.system(size: 10, weight: .black, design: .rounded)).foregroundStyle(color)
                    if pad.loops {
                        Image(systemName: "repeat").font(.system(size: 8, weight: .bold)).foregroundStyle(color.opacity(0.9))
                    }
                    if pad.loops, pad.syncs {
                        Image(systemName: "metronome.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(color.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    if pad.isLoaded {
                        // A mini deck shows its tempo, as a deck does: the one it is playing at while it follows the decks.
                        if pad.loops, let bpm = pad.playedBPM ?? pad.bpm {
                            Text(Self.tempo(bpm)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(pad.playedBPM == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                        } else {
                            Text(TrackFormat.duration(pad.seconds)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(pad.isLoading ? "Loading…" : (pad.isLoaded ? pad.name : "Drop a sound"))
                    .font(.system(size: 11, weight: pad.isLoaded ? .semibold : .regular))
                    .foregroundStyle(pad.isLoaded ? Color.white.opacity(0.92) : Color.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SamplerPadStyle(
            color: color, isLoaded: pad.isLoaded, isPlaying: pad.isPlaying, progress: pad.progress, isTargeted: isTargeted,
            wave: pad.loops ? pad.peaks : []
        ) { down in
            if down, pad.isLoaded { sampler.hit(pad.id) }
        })
        .help(help)
        .contextMenu { menu }
        .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            let index = pad.id
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.mixer.sampler.load(path: url.path, on: index) }
                }
            } else {
                // A track dragged from the list arrives as its number.
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let id = text?.split(separator: ",").compactMap({ Int64($0) }).first else { return }
                    Task { @MainActor in model.sendToSampler(trackID: id, pad: index) }
                }
            }
            return true
        }
    }

    private var help: String {
        guard pad.isLoaded else { return "Drop an audio file or a track here, or click to choose a file. Right-click to take a loop from a deck." }
        return pad.loops
            ? "“\(pad.name)”, a mini deck: click to start it going round, click again to stop.\(pad.syncs ? " " + syncHelp : "") Right-click for more."
            : "“\(pad.name)”, a one-shot: click to play it from the top. Right-click for more."
    }

    /// A tempo to a tenth, without the tenth when there is none: 124, 93.5.
    private static func tempo(_ bpm: Double) -> String {
        let tenths = (bpm * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    private var syncHelp: String {
        guard let bpm = pad.bpm else { return "Sync is on, but Crate does not know its tempo: set Length in its menu." }
        let length = pad.beatCount.map { "\($0) \($0 == 1 ? "beat" : "beats") at " } ?? ""
        return "Sync is on: \(length)\(Self.tempo(bpm)) BPM, played at the tempo of the deck that is playing and kept on its beat."
    }

    @ViewBuilder
    private var menu: some View {
        Button("Choose File…") { chooseFile() }
        ForEach(model.mixer.decks) { deck in
            Button(deck.loop == nil ? "Take Four Beats from Deck \(deck.id.name)" : "Take the Loop from Deck \(deck.id.name)") {
                sampler.capture(from: deck, on: pad.id)
            }
            .disabled(!deck.isLoaded)
        }
        if pad.isLoaded {
            Divider()
            Picker("Plays as", selection: Binding(get: { pad.loops }, set: { sampler.setLoops($0, on: pad.id) })) {
                Text("One-Shot: from the top at each hit").tag(false)
                Text("Mini Deck: loops in time until stopped").tag(true)
            }
            .pickerStyle(.inline)
            if pad.loops {
                Toggle("Sync to the Decks' Tempo", isOn: Binding(get: { pad.syncs }, set: { sampler.setSync($0, on: pad.id) }))
            }
            let lengths = SamplerModel.beatCounts(for: pad.seconds)
            if pad.loops, pad.syncs, !lengths.isEmpty {
                Picker("Length", selection: Binding(get: { pad.beatCount ?? 0 }, set: { sampler.setBeats($0, on: pad.id) })) {
                    ForEach(lengths, id: \.beats) { length in
                        Text("\(length.beats) \(length.beats == 1 ? "beat" : "beats") · \(Self.tempo(length.bpm)) BPM").tag(length.beats)
                    }
                }
            }
            Picker("Level", selection: Binding(get: { pad.gain }, set: { sampler.setGain($0, on: pad.id) })) {
                Text("+6 dB").tag(2.0)
                Text("Full").tag(1.0)
                Text("−6 dB").tag(0.5)
                Text("−12 dB").tag(0.25)
            }
            Button("Stop") { sampler.stop(pad.id) }.disabled(!pad.isPlaying)
            Divider()
            Button("Clear Pad", role: .destructive) { sampler.clear(pad.id) }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound for pad \(pad.slot + 1) of deck \(pad.deck.name)'s bank"
        if panel.runModal() == .OK, let url = panel.url { sampler.load(path: url.path, on: pad.id) }
    }
}

private struct SamplerPadStyle: ButtonStyle {
    let color: Color
    let isLoaded: Bool
    let isPlaying: Bool
    let progress: Double
    let isTargeted: Bool
    /// A mini deck's outline; empty for a one-shot, which has none drawn.
    var wave: [Float] = []
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        let lit = isPlaying || (configuration.isPressed && isLoaded)
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            // A mini deck: its waveform behind the name, what has played brighter, and a playhead across it.
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(lit ? (wave.isEmpty ? 0.42 : 0.3) : (isLoaded ? 0.16 : 0.05)))
                if !wave.isEmpty {
                    Canvas { context, size in
                        let step = size.width / CGFloat(wave.count)
                        let played = isPlaying ? size.width * progress : 0
                        for (index, peak) in wave.enumerated() {
                            let x = CGFloat(index) * step
                            let height = max(1.5, CGFloat(peak) * (size.height - 10))
                            let bar = CGRect(x: x + 0.5, y: (size.height - height) / 2, width: max(1, step - 1), height: height)
                            context.fill(Path(roundedRect: bar, cornerRadius: 0.5), with: .color(color.opacity(x < played ? 0.6 : 0.28)))
                        }
                        if isPlaying {
                            context.fill(Path(CGRect(x: min(size.width - 1.5, played), y: 2, width: 1.5, height: size.height - 4)), with: .color(.white.opacity(0.9)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            // A one-shot: how far through the sound it is, along the bottom.
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    if isPlaying, wave.isEmpty {
                        Rectangle().fill(color)
                            .frame(width: max(2, geometry.size.width * progress), height: 2.5)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isTargeted ? Color.white : color.opacity(lit ? 0.95 : (isLoaded ? 0.5 : 0.18)), lineWidth: isTargeted ? 2 : 1)
            )
            .shadow(color: color.opacity(lit ? 0.5 : 0), radius: lit ? 7 : 0)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}
