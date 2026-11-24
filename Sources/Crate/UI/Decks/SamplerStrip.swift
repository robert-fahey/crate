import AppKit
import CrateCore
import SwiftUI
import UniformTypeIdentifiers

/// The sampler: a row of eight pads under the decks. Hit a pad and its sound plays.
///
/// A pad takes an audio file dragged from the Finder, a track dragged from the list (its first
/// two minutes at most), or the loop a deck is playing. Right-click a pad for the rest.
struct SamplerStrip: View {
    let model: AppModel
    static let height: CGFloat = 60

    private var sampler: SamplerModel { model.mixer.sampler }

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
            ForEach(sampler.pads) { pad in
                SamplerPadView(model: model, pad: pad)
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
    }
}

private struct SamplerPadView: View {
    let model: AppModel
    let pad: SamplerModel.Pad
    @State private var isTargeted = false

    private var sampler: SamplerModel { model.mixer.sampler }
    private var color: Color { WaveMarks.color(forCue: pad.id + 1) }

    var body: some View {
        // A loaded pad sounds as the mouse goes down, not when it comes up. An empty one asks for a file.
        Button {
            if !pad.isLoaded, !pad.isLoading { chooseFile() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(pad.id + 1)").font(.system(size: 10, weight: .black, design: .rounded)).foregroundStyle(color)
                    if pad.loops {
                        Image(systemName: "repeat").font(.system(size: 8, weight: .bold)).foregroundStyle(color.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    if pad.isLoaded {
                        Text(TrackFormat.duration(pad.seconds)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
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
        .buttonStyle(SamplerPadStyle(color: color, isLoaded: pad.isLoaded, isPlaying: pad.isPlaying, progress: pad.progress, isTargeted: isTargeted) { down in
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
            ? "“\(pad.name)”: click to start it going round, click again to stop. Right-click for more."
            : "“\(pad.name)”: click to play it from the top. Right-click for more."
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
            Toggle("Loop", isOn: Binding(get: { pad.loops }, set: { sampler.setLoops($0, on: pad.id) }))
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
        panel.message = "Choose a sound for pad \(pad.id + 1)"
        if panel.runModal() == .OK, let url = panel.url { sampler.load(path: url.path, on: pad.id) }
    }
}

private struct SamplerPadStyle: ButtonStyle {
    let color: Color
    let isLoaded: Bool
    let isPlaying: Bool
    let progress: Double
    let isTargeted: Bool
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        let lit = isPlaying || (configuration.isPressed && isLoaded)
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(lit ? 0.42 : (isLoaded ? 0.16 : 0.05)))
            )
            // How far through the sound it is, along the bottom.
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    if isPlaying {
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
