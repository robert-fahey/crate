import CrateCore
import SwiftUI

/// How large the decks are drawn: 1 is compact, 1.5 is the large mode. Every deck
/// control sizes itself by this, so text and drawing stay sharp at either size.
private struct DeckScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var deckScale: CGFloat {
        get { self[DeckScaleKey.self] }
        set { self[DeckScaleKey.self] = newValue }
    }
}

/// The look of the decks: colours, surfaces and glows shared by every control.
enum DeckStyle {
    /// Deck A is blue to cyan, deck B is orange to pink.
    static func colors(_ index: Int) -> [Color] {
        index == 0
            ? [Color(red: 0.30, green: 0.56, blue: 1.00), Color(red: 0.38, green: 0.88, blue: 1.00)]
            : [Color(red: 1.00, green: 0.56, blue: 0.24), Color(red: 1.00, green: 0.32, blue: 0.56)]
    }
    static func color(_ index: Int) -> Color { index == 0 ? Color(red: 0.36, green: 0.66, blue: 1.00) : Color(red: 1.00, green: 0.52, blue: 0.32) }
    static func gradient(_ index: Int) -> LinearGradient {
        LinearGradient(colors: colors(index), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let base = Color(red: 0.035, green: 0.035, blue: 0.055)
    static let panel = Color(red: 0.075, green: 0.075, blue: 0.11)
    static let well = Color(red: 0.03, green: 0.03, blue: 0.05)
    static let hairline = Color.white.opacity(0.09)

    /// The backdrop behind the decks: near black, lit faintly from each deck's side in its colour.
    static var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.085, green: 0.085, blue: 0.125), base], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [colors(0)[0].opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [colors(1)[1].opacity(0.20), .clear], center: .topTrailing, startRadius: 0, endRadius: 620)
        }
    }

    /// A colour for a Camelot key: the wheel's twelve positions run round the hue circle,
    /// so neighbouring (compatible) keys have neighbouring colours. Minor keys are deeper.
    static func keyColor(_ key: CamelotKey?) -> Color {
        guard let key else { return .white.opacity(0.7) }
        let hue = Double((key.number + 4) % 12) / 12
        return Color(hue: hue, saturation: key.isMajor ? 0.48 : 0.72, brightness: 1)
    }
}

/// A raised surface with a faint edge, tinted along the top in a deck's colour.
struct DeckCard: ViewModifier {
    var tint: [Color] = [.white.opacity(0.18), .white.opacity(0.03)]
    @Environment(\.deckScale) private var scale

    func body(content: Content) -> some View {
        content
            .padding(10 * scale)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.025)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

extension View {
    func deckCard(tint: [Color]? = nil) -> some View {
        modifier(DeckCard(tint: tint ?? [.white.opacity(0.18), .white.opacity(0.03)]))
    }
}

/// The face of a pad: dark glass when off, lit in its colour with a glow when on.
private struct PadFace: View {
    let isOn: Bool
    let isPressed: Bool
    let color: Color
    var radius: CGFloat = 7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(
                isOn
                    ? LinearGradient(colors: [color.opacity(0.95), color.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(
                        colors: [.white.opacity(isPressed ? 0.26 : 0.15), .white.opacity(isPressed ? 0.16 : 0.06)],
                        startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(isOn ? 0.55 : 0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: isOn ? color.opacity(0.65) : .clear, radius: isOn ? 8 : 0)
    }
}

/// A small lit button, as on a mixer.
struct PadButtonStyle: ButtonStyle {
    var isOn = false
    var color: Color = .white
    var minWidth: CGFloat = 30
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View { Pad(style: self, configuration: configuration) }

    private struct Pad: View {
        let style: PadButtonStyle
        let configuration: Configuration
        @Environment(\.deckScale) private var scale

        var body: some View {
            configuration.label
                .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7 * scale)
                .frame(minWidth: style.minWidth * scale, minHeight: style.height * scale)
                .foregroundStyle(style.isOn ? Color.black.opacity(0.85) : Color.white.opacity(0.86))
                .background(PadFace(isOn: style.isOn, isPressed: configuration.isPressed, color: style.color, radius: 7 * scale))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: style.isOn)
        }
    }
}

/// The round play and cue buttons.
struct TransportButtonStyle: ButtonStyle {
    var isOn = false
    var colors: [Color] = [.white, .white]
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View { Face(style: self, configuration: configuration) }

    private struct Face: View {
        let style: TransportButtonStyle
        let configuration: Configuration
        @Environment(\.deckScale) private var scale

        var body: some View {
            let size = style.size * scale, isOn = style.isOn
            let gradient = LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            configuration.label
                .font(.system(size: 13 * scale, weight: .heavy, design: .rounded))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(gradient))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        isOn
                            ? AnyShapeStyle(gradient)
                            : AnyShapeStyle(RadialGradient(
                                colors: [.white.opacity(configuration.isPressed ? 0.22 : 0.12), .white.opacity(0.03)],
                                center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: size * 0.7)))
                )
                .overlay(Circle().strokeBorder(gradient.opacity(isOn ? 1 : 0.7), lineWidth: 1.5 * scale))
                .shadow(color: style.colors[0].opacity(isOn ? 0.75 : 0.0), radius: isOn ? 10 * scale : 0)
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: isOn)
        }
    }
}

/// A button that acts for as long as it is held: `action(true)` on press, `action(false)` on release.
struct HoldButton: View {
    let label: String
    var color: Color = .white
    var minWidth: CGFloat = 30
    let action: (Bool) -> Void
    @State private var isHeld = false
    @Environment(\.deckScale) private var scale

    var body: some View {
        Text(label)
            .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 8 * scale)
            .frame(minWidth: minWidth * scale, minHeight: 26 * scale)
            .foregroundStyle(isHeld ? Color.black.opacity(0.85) : Color.white.opacity(0.86))
            .background(PadFace(isOn: isHeld, isPressed: false, color: color, radius: 7 * scale))
            .contentShape(Rectangle())
            .scaleEffect(isHeld ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: isHeld)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHeld {
                            isHeld = true
                            action(true)
                        }
                    }
                    .onEnded { _ in
                        isHeld = false
                        action(false)
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }
}

/// A rotary knob. Drag up and down to turn it; double-click to return it to its resting value.
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var resting = 0.0
    let label: String
    var color: Color = .white
    var size: CGFloat = 34
    @State private var dragStart: Double?
    @Environment(\.deckScale) private var scale

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    private func draw(_ context: inout GraphicsContext, _ canvas: CGSize) {
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius: CGFloat = min(canvas.width, canvas.height) / 2 - 3
        let start = 135.0, sweep = 270.0
        func angle(_ fraction: Double) -> Angle { .degrees(start + sweep * fraction) }
        var track = Path()
        track.addArc(center: center, radius: radius, startAngle: angle(0), endAngle: angle(1), clockwise: false)
        context.stroke(track, with: .color(.white.opacity(0.13)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // The lit arc runs from the resting position to the knob's position, with a glow under it.
        let rest: Double = (resting - range.lowerBound) / (range.upperBound - range.lowerBound)
        if abs(fraction - rest) > 0.004 {
            var lit = Path()
            lit.addArc(
                center: center, radius: radius, startAngle: angle(min(rest, fraction)), endAngle: angle(max(rest, fraction)),
                clockwise: false)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 3))
                layer.stroke(lit, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            context.stroke(lit, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // The cap: dark metal, lit from above.
        let cap = CGRect(x: center.x - radius + 4.5, y: center.y - radius + 4.5, width: (radius - 4.5) * 2, height: (radius - 4.5) * 2)
        context.fill(
            Path(ellipseIn: cap),
            with: .linearGradient(
                Gradient(colors: [Color(white: 0.36), Color(white: 0.11)]),
                startPoint: CGPoint(x: cap.midX, y: cap.minY), endPoint: CGPoint(x: cap.midX, y: cap.maxY)))
        context.stroke(Path(ellipseIn: cap), with: .color(.white.opacity(0.16)), lineWidth: 1)
        let direction = CGFloat(angle(fraction).radians)
        let reach = radius - 4.5
        var pointer = Path()
        pointer.move(to: CGPoint(x: center.x + cos(direction) * reach * 0.35, y: center.y + sin(direction) * reach * 0.35))
        pointer.addLine(to: CGPoint(x: center.x + cos(direction) * reach * 0.92, y: center.y + sin(direction) * reach * 0.92))
        context.stroke(pointer, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, canvas in
                var scaled = context
                scaled.scaleBy(x: scale, y: scale)
                draw(&scaled, CGSize(width: canvas.width / scale, height: canvas.height / scale))
            }
                .frame(width: size * scale, height: size * scale)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let start = dragStart ?? value
                            dragStart = start
                            let span = range.upperBound - range.lowerBound
                            value = min(range.upperBound, max(range.lowerBound, start - Double(drag.translation.height) / 120 * span))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .onTapGesture(count: 2) { value = resting }
            Text(label)
                .font(.system(size: 8.5 * scale, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// The cap of a fader: brushed metal with a stripe in its colour.
private struct FaderCap: View {
    let colors: [Color]
    let isVertical: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.52), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: isVertical ? nil : 3, height: isVertical ? 3 : nil)
                    .padding(isVertical ? .horizontal : .vertical, 3)
                    .shadow(color: colors[0].opacity(0.9), radius: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
    }
}

/// A vertical channel fader, 0 at the bottom to 1 at the top.
struct VerticalFader: View {
    @Binding var value: Double
    var colors: [Color] = [.white, .white]
    let label: String
    @Environment(\.deckScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height, cap: CGFloat = 18 * scale
            let travel = max(1, height - cap)
            ZStack(alignment: .top) {
                Capsule().fill(DeckStyle.well).frame(width: 6 * scale)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.8).frame(width: 6 * scale))
                    .frame(maxHeight: .infinity)
                // How far up the fader is, lit.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                        .frame(width: 2.5 * scale, height: max(0, travel * CGFloat(value)))
                        .opacity(0.85)
                }
                .padding(.bottom, cap / 2)
                FaderCap(colors: colors, isVertical: true)
                    .frame(width: 28 * scale, height: cap)
                    .offset(y: travel * CGFloat(1 - value))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = min(1, max(0, 1 - Double((drag.location.y - cap / 2) / travel)))
                }
            )
        }
        .frame(width: 32 * scale)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            value = min(1, max(0, value + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}

/// A horizontal fader with a mark at its resting position: the crossfader and the tempo faders.
/// Double-click to return it to rest.
struct HorizontalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var resting = 0.0
    var colors: [Color] = [.white, .white]
    let label: String
    @Environment(\.deckScale) private var scale

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, cap: CGFloat = 18 * scale
            let travel = max(1, width - cap)
            let rest = CGFloat((resting - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(DeckStyle.well).frame(height: 6 * scale)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.8).frame(height: 6 * scale))
                Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 12 * scale).offset(x: cap / 2 + travel * rest - 0.5)
                // From rest to where the fader is, lit.
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: abs(CGFloat(fraction) - rest) * travel, height: 2.5 * scale)
                    .offset(x: cap / 2 + travel * min(rest, CGFloat(fraction)))
                    .opacity(0.85)
                FaderCap(colors: colors, isVertical: false)
                    .frame(width: cap, height: 22 * scale)
                    .offset(x: travel * CGFloat(fraction))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let position = min(1, max(0, Double((drag.location.x - cap / 2) / travel)))
                    value = range.lowerBound + position * (range.upperBound - range.lowerBound)
                }
            )
            .onTapGesture(count: 2) { value = resting }
        }
        .frame(height: 24 * scale)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 40
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// A level meter: green, then amber, then red at full scale, each lit segment glowing a little.
struct LevelMeter: View {
    let level: Float
    @Environment(\.deckScale) private var scale

    var body: some View {
        Canvas { context, size in
            let segments = 20
            let gap: CGFloat = 1.5
            let height = (size.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
            // Decibels read better than raw level: -42 dB at the bottom, 0 at the top.
            let decibels = level > 0 ? 20 * log10(level) : -100
            let lit = Int((CGFloat(max(0, min(1, (decibels + 42) / 42))) * CGFloat(segments)).rounded())
            for segment in 0..<segments {
                let y = size.height - CGFloat(segment + 1) * height - CGFloat(segment) * gap
                let place = Double(segment) / Double(segments - 1)
                let color = place > 0.93 ? Color(red: 1, green: 0.25, blue: 0.3)
                    : (place > 0.75 ? Color(red: 1, green: 0.82, blue: 0.25) : Color(hue: 0.40 - place * 0.08, saturation: 0.75, brightness: 0.95))
                let rect = CGRect(x: 0, y: y, width: size.width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(segment < lit ? 1 : 0.13)))
            }
        }
        .frame(width: 5 * scale)
        .shadow(color: level > 0.02 ? Color.green.opacity(0.35) : .clear, radius: 3)
        .accessibilityHidden(true)
    }
}

/// A record on a platter. It turns as the deck plays (and backwards when it is scratched).
struct Platter: View {
    let deck: DeckModel
    @Environment(\.deckScale) private var scale

    var body: some View {
        let colors = DeckStyle.colors(deck.id.rawValue)
        // Read so that a scrub while stopped still turns the record.
        let polled = deck.position
        let isLoaded = deck.isLoaded
        let isPlaying = deck.isPlaying
        let audio = deck.deck
        ZStack {
            // In a host of its own, so that turning does not make the decks lay themselves out again.
            IsolatedHost {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { _ in
                    let seconds = isPlaying ? audio.state().position : polled
                    Canvas(rendersAsynchronously: true) { context, size in
                        Self.draw(&context, size: size, colors: colors, turns: seconds * 33.333 / 60, isLoaded: isLoaded)
                    }
                }
            }
            Text(deck.id.name)
                .font(.system(size: 13 * scale, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.8))
        }
        // A glow behind the record rather than a shadow of it: a shadow would be re-blurred on every frame it turns.
        .background(
            Circle().fill(deck.isPlaying ? colors[0].opacity(0.55) : .clear).blur(radius: 9 * scale).padding(-3 * scale)
        )
        .accessibilityHidden(true)
    }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, colors: [Color], turns: Double, isLoaded: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        func disc(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)) }

        context.fill(
            disc(radius),
            with: .radialGradient(Gradient(colors: [Color(white: 0.16), Color(white: 0.03)]), center: center, startRadius: radius * 0.3, endRadius: radius))
        for ring in stride(from: radius * 0.52, to: radius * 0.97, by: radius * 0.085) {
            context.stroke(disc(ring), with: .color(.white.opacity(0.07)), lineWidth: 0.8)
        }
        // Light catching the grooves: fixed, as the lamp does not turn with the record.
        context.fill(
            disc(radius),
            with: .conicGradient(
                Gradient(colors: [.clear, .white.opacity(0.20), .clear, .clear, .white.opacity(0.14), .clear, .clear]),
                center: center, angle: .degrees(-70)))
        context.stroke(disc(radius - 0.5), with: .color(.white.opacity(0.18)), lineWidth: 1)

        // The label turns with the record; a stripe across it shows the turning.
        let label = radius * 0.44
        var turning = context
        turning.translateBy(x: center.x, y: center.y)
        turning.rotate(by: .degrees(turns * 360))
        let labelDisc = Path(ellipseIn: CGRect(x: -label, y: -label, width: label * 2, height: label * 2))
        turning.fill(
            labelDisc,
            with: .linearGradient(
                Gradient(colors: isLoaded ? colors : [Color(white: 0.45), Color(white: 0.3)]),
                startPoint: CGPoint(x: -label, y: -label), endPoint: CGPoint(x: label, y: label)))
        turning.fill(Path(CGRect(x: label * 0.55, y: -1.2, width: label * 0.4, height: 2.4)), with: .color(.black.opacity(0.55)))
        turning.fill(Path(CGRect(x: -label * 0.95, y: -1.2, width: label * 0.4, height: 2.4)), with: .color(.white.opacity(0.6)))
    }
}
