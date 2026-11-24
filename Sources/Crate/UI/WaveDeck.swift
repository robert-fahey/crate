import AppKit
import CrateCore
import SwiftUI

// The waveform display: a zoomed wave that scrolls under a fixed playhead,
// with the whole track in a strip below it.
//
// Colour shows what is in the music at each moment: blue for bass, pink for
// mids, gold for highs, drawn as three layers.

enum WavePalette {
    static let low = SIMD3<Double>(0.27, 0.42, 1.00)
    static let mid = SIMD3<Double>(1.00, 0.30, 0.55)
    static let high = SIMD3<Double>(1.00, 0.86, 0.48)
    static let screenTop = Color(red: 0.10, green: 0.10, blue: 0.15)
    static let screenBottom = Color(red: 0.04, green: 0.04, blue: 0.07)
    static let screen = Color(red: 0.06, green: 0.06, blue: 0.10)

    static func color(_ rgb: SIMD3<Double>, opacity: Double = 1) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z).opacity(opacity)
    }

    /// Stored levels are the square root of amplitude; a little more contrast reads better.
    static func height(_ level: Float) -> CGFloat { CGFloat(pow(level, 1.3)) }

    /// One colour for a stretch of the track: which bands are stronger there than
    /// they are in the track as a whole. A breakdown with no kick turns pink and
    /// gold; a bass-heavy passage turns blue.
    static func blend(_ levels: (low: Float, mid: Float, high: Float), typical: (low: Float, mid: Float, high: Float)) -> Color {
        func weight(_ level: Float, _ usual: Float) -> Double {
            guard usual > 0.001 else { return 0 }
            return pow(Double(level / usual), 4) * Double(level)
        }
        let weights = SIMD3<Double>(
            weight(levels.low, typical.low), weight(levels.mid, typical.mid), weight(levels.high, typical.high))
        let total = weights.x + weights.y + weights.z
        guard total > 0 else { return color(mid) }
        return color((low * weights.x + mid * weights.y + high * weights.z) / total)
    }

    static var screenBackground: LinearGradient {
        LinearGradient(colors: [screenTop, screenBottom], startPoint: .top, endPoint: .bottom)
    }
}

enum WaveZoom {
    /// Points of width per second of music.
    static let standard = 110.0
    static let range = 30.0...420.0
    static func clamp(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
}

// MARK: - Drawing the scrolling wave

/// What is marked on a deck's waveform besides the audio itself.
struct WaveMarks: Equatable {
    var grid: BeatGrid?
    /// Hot cues by slot.
    var cues: [Int: Double] = [:]
    var cuePoint: Double?
    var loop: ClosedRange<Double>?

    static let cueColors: [Color] = [
        Color(red: 1.00, green: 0.30, blue: 0.30), Color(red: 1.00, green: 0.62, blue: 0.20),
        Color(red: 1.00, green: 0.90, blue: 0.25), Color(red: 0.35, green: 0.90, blue: 0.40),
        Color(red: 0.25, green: 0.85, blue: 0.95), Color(red: 0.40, green: 0.55, blue: 1.00),
        Color(red: 0.75, green: 0.45, blue: 1.00), Color(red: 1.00, green: 0.45, blue: 0.80),
    ]
    static func color(forCue slot: Int) -> Color { cueColors[(max(1, slot) - 1) % cueColors.count] }
    static let loopColor = Color(red: 0.30, green: 0.95, blue: 0.55)
}

/// One drawn frame of a scrolling wave.
struct WaveFrame {
    var position = 0.0
    /// Smoothed output level, 0...1; drives the pulse at the playhead.
    var level: CGFloat = 0
    /// Seconds since this track's wave first appeared; drives the rise-in.
    var age = 10.0
}

enum WaveRenderer {
    static func draw(
        _ context: inout GraphicsContext, size: CGSize, detail: WaveDetail, frame: WaveFrame,
        pointsPerSecond: Double, duration: Double, marks: WaveMarks = WaveMarks(), waveOnly: Bool = false
    ) {
        let centerX = size.width / 2
        let middle = size.height / 2
        let reach = middle - 9  // tallest half-height; leaves room for the ruler
        let columnsPerSecond = detail.columnsPerSecond
        let pointsPerColumn = pointsPerSecond / columnsPerSecond
        // When zoomed out, several columns share a point: take the loudest of each group.
        let step = max(1, Int((1.4 / pointsPerColumn).rounded(.up)))

        func x(atSeconds seconds: Double) -> CGFloat { centerX + CGFloat((seconds - frame.position) * pointsPerSecond) }

        let firstVisible = Int(((frame.position - Double(centerX) / pointsPerSecond) * columnsPerSecond).rounded(.down))
        let lastVisible = Int(((frame.position + Double(centerX) / pointsPerSecond) * columnsPerSecond).rounded(.up))
        // Start on a multiple of the step so groups do not shift as the wave scrolls.
        let first = max(0, (firstVisible / step - 1) * step)
        let last = min(detail.count, lastVisible + step)

        if first < last {
            var xs: [CGFloat] = []
            var heights: [[CGFloat]] = [[], [], []]
            xs.reserveCapacity((last - first) / step + 2)
            var column = first
            while column < last {
                let levels = step == 1
                    ? (low: detail.level(.low, at: column), mid: detail.level(.mid, at: column), high: detail.level(.high, at: column))
                    : detail.peak(in: column..<(column + step))
                let position = x(atSeconds: (Double(column) + Double(step) / 2) / columnsPerSecond)
                let distance = abs(position - centerX)
                // The wave swells a little where it passes the playhead, in time with the music.
                var scale = 1 + 0.28 * frame.level * exp(-(distance * distance) / 1800)
                // A new track's wave rises outwards from the playhead and overshoots slightly.
                if frame.age < 1.2 {
                    scale *= riseIn((frame.age - Double(distance / max(1, centerX)) * 0.35) / 0.5)
                }
                xs.append(position)
                heights[0].append(WavePalette.height(levels.low) * reach * scale)
                heights[1].append(WavePalette.height(levels.mid) * reach * scale * 0.92)
                heights[2].append(WavePalette.height(levels.high) * reach * scale * 0.74)
                column += step
            }

            let colors = [WavePalette.low, WavePalette.mid, WavePalette.high]
            for band in 0..<3 {
                let path = mirrored(xs: xs, heights: heights[band], middle: middle)
                let gradient = Gradient(stops: [
                    .init(color: WavePalette.color(colors[band], opacity: 0.55), location: 0),
                    .init(color: WavePalette.color(colors[band]), location: 0.5),
                    .init(color: WavePalette.color(colors[band], opacity: 0.55), location: 1),
                ])
                context.fill(
                    path,
                    with: .linearGradient(
                        gradient, startPoint: CGPoint(x: 0, y: middle - reach), endPoint: CGPoint(x: 0, y: middle + reach)))
            }
        }

        // Centre line, so silence is still a line rather than nothing.
        context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)), with: .color(.white.opacity(0.10)))
        // The grid editor draws its own grid, markers and playhead over a plain wave.
        if waveOnly { return }

        if let loop = marks.loop {
            let from = x(atSeconds: loop.lowerBound), to = x(atSeconds: loop.upperBound)
            context.fill(Path(CGRect(x: from, y: 0, width: to - from, height: size.height)), with: .color(WaveMarks.loopColor.opacity(0.16)))
            for edge in [from, to] {
                context.fill(Path(CGRect(x: edge - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(WaveMarks.loopColor.opacity(0.9)))
            }
        }
        if let grid = marks.grid {
            beatLines(&context, size: size, grid: grid, frame: frame, pointsPerSecond: pointsPerSecond, x: x)
        }

        // What has already played is dimmed.
        context.fill(Path(CGRect(x: 0, y: 0, width: centerX, height: size.height)), with: .color(WavePalette.screen.opacity(0.5)))

        ruler(
            &context, size: size, frame: frame, pointsPerSecond: pointsPerSecond, duration: duration,
            ticks: marks.grid == nil, x: x)
        cueFlags(&context, size: size, marks: marks, x: x)

        // The two ends of the track.
        for edge in [0, duration] {
            let position = x(atSeconds: edge)
            if position > -2, position < size.width + 2 {
                context.fill(
                    Path(CGRect(x: position - 0.5, y: 6, width: 1, height: size.height - 12)), with: .color(.white.opacity(0.35)))
            }
        }

        // Fade out at both sides.
        let fade = min(46, size.width / 6)
        for (start, end) in [(CGFloat(0), fade), (size.width, size.width - fade)] {
            context.fill(
                Path(CGRect(x: min(start, end), y: 0, width: fade, height: size.height)),
                with: .linearGradient(
                    Gradient(colors: [WavePalette.screen, WavePalette.screen.opacity(0)]),
                    startPoint: CGPoint(x: start, y: 0), endPoint: CGPoint(x: end, y: 0)))
        }

        // Playhead: a soft glow that breathes with the level, and a crisp line.
        let glowWidth = 22 + 26 * frame.level
        context.fill(
            Path(CGRect(x: centerX - glowWidth, y: 0, width: glowWidth * 2, height: size.height)),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(0.07 + 0.16 * Double(frame.level)), .white.opacity(0)]),
                startPoint: CGPoint(x: centerX - glowWidth, y: 0), endPoint: CGPoint(x: centerX + glowWidth, y: 0)))
        context.fill(
            Path(roundedRect: CGRect(x: centerX - 1, y: 3, width: 2, height: size.height - 6), cornerRadius: 1),
            with: .color(.white))
    }

    /// A shape mirrored around the centre line: along the top edge, then back along the bottom.
    private static func mirrored(xs: [CGFloat], heights: [CGFloat], middle: CGFloat) -> Path {
        var path = Path()
        guard xs.count > 1 else { return path }
        path.move(to: CGPoint(x: xs[0], y: middle))
        smooth(&path, points: xs.indices.map { CGPoint(x: xs[$0], y: middle - heights[$0]) })
        path.addLine(to: CGPoint(x: xs[xs.count - 1], y: middle))
        smooth(&path, points: xs.indices.reversed().map { CGPoint(x: xs[$0], y: middle + heights[$0]) })
        path.closeSubpath()
        return path
    }

    /// Runs through the points with curves between their midpoints, which rounds the corners.
    private static func smooth(_ path: inout Path, points: [CGPoint]) {
        guard let first = points.first else { return }
        path.addLine(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
    }

    /// 0 to 1 with a small overshoot at the end.
    private static func riseIn(_ progress: Double) -> CGFloat {
        let t = min(1, max(0, progress)) - 1
        return CGFloat(1 + 2.70158 * t * t * t + 1.70158 * t * t)
    }

    /// Ticks along the bottom with a time label every so often, so the scrolling
    /// is visible even through a quiet passage.
    private static func ruler(
        _ context: inout GraphicsContext, size: CGSize, frame: WaveFrame, pointsPerSecond: Double,
        duration: Double, ticks: Bool, x: (Double) -> CGFloat
    ) {
        let tickEvery = [1.0, 2, 5, 10, 30].first { $0 * pointsPerSecond >= 14 } ?? 60
        let labelEvery = [1.0, 2, 5, 10, 15, 30, 60, 120].first { $0 * pointsPerSecond >= 170 && $0 >= tickEvery } ?? 300
        let half = Double(size.width) / 2 / pointsPerSecond
        var tick = (max(0, frame.position - half) / tickEvery).rounded(.up) * tickEvery
        let end = min(duration, frame.position + half)
        while tick <= end {
            let position = x(tick)
            let labelled = tick.truncatingRemainder(dividingBy: labelEvery) < 0.001
            if ticks {
                context.fill(
                    Path(CGRect(x: position - 0.5, y: size.height - (labelled ? 7 : 4), width: 1, height: labelled ? 7 : 4)),
                    with: .color(.white.opacity(labelled ? 0.4 : 0.2)))
            }
            if labelled {
                context.draw(
                    Text(TrackFormat.duration(tick)).font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45)),
                    at: CGPoint(x: position + 4, y: size.height - 6), anchor: .leading)
            }
            tick += tickEvery
        }
    }
}

extension WaveRenderer {
    /// A line on every beat, a stronger one at the start of each bar, and a marker where a phrase starts.
    static func beatLines(
        _ context: inout GraphicsContext, size: CGSize, grid: BeatGrid, frame: WaveFrame, pointsPerSecond: Double,
        x: (Double) -> CGFloat
    ) {
        let half = Double(size.width) / 2 / pointsPerSecond
        let first = Int(grid.beatPosition(at: frame.position - half).rounded(.down))
        let last = Int(grid.beatPosition(at: frame.position + half).rounded(.up))
        guard last > first, last - first < 2000 else { return }
        let spacing = size.width / CGFloat(last - first)
        for beat in first...last {
            let position = x(grid.time(atBeat: Double(beat)))
            let inBar = grid.beatInBar(beat)
            if inBar == 1 {
                let isPhrase = (beat - grid.phrase) % BeatGrid.beatsPerPhrase == 0
                context.fill(
                    Path(CGRect(x: position - 0.75, y: 0, width: 1.5, height: size.height)),
                    with: .color(.white.opacity(isPhrase ? 0.75 : 0.42)))
                if isPhrase {
                    var marker = Path()
                    marker.move(to: CGPoint(x: position - 5, y: 0))
                    marker.addLine(to: CGPoint(x: position + 5, y: 0))
                    marker.addLine(to: CGPoint(x: position, y: 7))
                    marker.closeSubpath()
                    context.fill(marker, with: .color(WavePalette.color(WavePalette.high)))
                }
            } else if spacing >= 7 {
                context.fill(
                    Path(CGRect(x: position - 0.5, y: size.height * 0.18, width: 1, height: size.height * 0.64)),
                    with: .color(.white.opacity(0.2)))
            }
        }
    }

    static func cueFlags(_ context: inout GraphicsContext, size: CGSize, marks: WaveMarks, x: (Double) -> CGFloat) {
        if let cue = marks.cuePoint {
            let position = x(cue)
            if position > -10, position < size.width + 10 {
                var marker = Path()
                marker.move(to: CGPoint(x: position - 5, y: size.height))
                marker.addLine(to: CGPoint(x: position + 5, y: size.height))
                marker.addLine(to: CGPoint(x: position, y: size.height - 8))
                marker.closeSubpath()
                context.fill(marker, with: .color(.white))
            }
        }
        for (slot, time) in marks.cues.sorted(by: { $0.key < $1.key }) {
            let position = x(time)
            guard position > -20, position < size.width + 20 else { continue }
            let color = WaveMarks.color(forCue: slot)
            context.fill(Path(CGRect(x: position - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(color))
            let flag = CGRect(x: position, y: 0, width: 13, height: 13)
            context.fill(Path(roundedRect: flag, cornerSize: CGSize(width: 2, height: 2)), with: .color(color))
            context.draw(
                Text("\(slot)").font(.system(size: 9, weight: .bold)).foregroundStyle(.black),
                at: CGPoint(x: flag.midX, y: flag.midY))
        }
    }
}

// MARK: - Whole-track strip

/// The whole track in one strip. Click or drag to jump; the box shows what the
/// scrolling wave above is looking at.
struct WaveOverview: View {
    let detail: WaveDetail?
    /// The plain peak overview, used until the detailed waveform exists.
    let peaks: Data?
    let position: Double
    let duration: Double
    /// How many seconds the scrolling wave shows; 0 hides the box.
    let visibleSeconds: Double
    let isEnabled: Bool
    var marks = WaveMarks()
    let onSeek: (Double) -> Void

    @State private var pointer: CGFloat?
    private var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(&context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in if isEnabled { pointer = value.location.x } }
                    .onEnded { value in
                        guard isEnabled, geometry.size.width > 0 else { return }
                        onSeek(min(1, max(0, value.location.x / geometry.size.width)) * duration)
                    }
            )
            .onContinuousHover { phase in
                if case .active(let location) = phase, isEnabled { pointer = location.x } else { pointer = nil }
            }
            .overlay(alignment: .topLeading) {
                if let pointer, duration > 0, geometry.size.width > 0 {
                    let fraction = min(1, max(0, pointer / geometry.size.width))
                    Text(TrackFormat.duration(fraction * duration))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: Capsule())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .alignmentGuide(.leading) { $0.width / 2 }
                        .offset(x: min(max(18, pointer), geometry.size.width - 18), y: -20)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Track position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let played = size.width * CGFloat(progress)
        let barWidth: CGFloat = 2, gap: CGFloat = 1
        let count = max(1, Int(size.width / (barWidth + gap)))

        if let detail, detail.count > 0 {
            // Each bar is the average of its stretch of the track, scaled so the loudest bar is full height.
            let bars = (0..<count).map { bar -> (low: Float, mid: Float, high: Float) in
                let from = bar * detail.count / count
                return detail.mean(in: from..<max(from + 1, (bar + 1) * detail.count / count))
            }
            let typical = detail.mean(in: 0..<detail.count)
            let loudest = bars.map { max($0.low, $0.mid, $0.high) }.max() ?? 0
            for (bar, levels) in bars.enumerated() {
                let level = loudest > 0 ? max(levels.low, levels.mid, levels.high) / loudest : 0
                let height = max(1.5, CGFloat(pow(level, 1.5)) * size.height)
                fill(&context, bar: bar, height: height, size: size, played: played,
                     color: WavePalette.blend(levels, typical: typical))
            }
        } else if let peaks, !peaks.isEmpty {
            for bar in 0..<count {
                let from = bar * peaks.count / count
                let to = max(from + 1, (bar + 1) * peaks.count / count)
                var peak: UInt8 = 0
                for index in from..<min(to, peaks.count) { peak = max(peak, peaks[peaks.startIndex + index]) }
                let height = max(1.5, CGFloat(peak) / 255 * size.height)
                fill(&context, bar: bar, height: height, size: size, played: played, color: WavePalette.color(WavePalette.mid))
            }
        } else {
            // No waveform (a streaming track, or nothing playing): a plain progress line.
            let line = CGRect(x: 0, y: size.height / 2 - 2, width: size.width, height: 4)
            context.fill(Path(roundedRect: line, cornerRadius: 2), with: .color(.white.opacity(0.15)))
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: line.minY, width: played, height: 4), cornerRadius: 2),
                with: .linearGradient(
                    Gradient(colors: [WavePalette.color(WavePalette.low), WavePalette.color(WavePalette.mid)]),
                    startPoint: .zero, endPoint: CGPoint(x: max(1, played), y: 0)))
        }

        guard duration > 0 else { return }
        if let loop = marks.loop {
            let from = size.width * CGFloat(loop.lowerBound / duration), to = size.width * CGFloat(loop.upperBound / duration)
            context.fill(
                Path(CGRect(x: from, y: 0, width: max(2, to - from), height: size.height)),
                with: .color(WaveMarks.loopColor.opacity(0.55)))
        }
        for (slot, time) in marks.cues {
            let position = size.width * CGFloat(time / duration)
            context.fill(Path(CGRect(x: position - 1, y: 0, width: 2, height: size.height)), with: .color(WaveMarks.color(forCue: slot)))
        }
        if visibleSeconds > 0 {
            // What the scrolling wave is showing.
            let width = max(8, size.width * CGFloat(visibleSeconds / duration))
            let box = CGRect(x: played - width / 2, y: 0.5, width: width, height: size.height - 1)
            context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.white.opacity(0.12)))
            context.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(.white.opacity(0.55)), lineWidth: 1)
        }
        if position > 0 || visibleSeconds > 0 {
            context.fill(Path(CGRect(x: played - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
        }
        if let pointer {
            context.fill(Path(CGRect(x: pointer - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.5)))
        }
    }

    private func fill(
        _ context: inout GraphicsContext, bar: Int, height: CGFloat, size: CGSize, played: CGFloat, color: Color
    ) {
        let x = CGFloat(bar) * 3
        let rect = CGRect(x: x, y: (size.height - height) / 2, width: 2, height: height)
        // Played bars fade back, as in the scrolling wave.
        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(x < played ? 0.4 : 1)))
    }
}
