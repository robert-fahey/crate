// Draws Crate's app icon, a vinyl record, and writes it as a 1024-pixel PNG.
// Usage: swift Scripts/make-icon.swift <output.png>     (Scripts/make-icon.sh builds the .icns)
import AppKit
import CoreGraphics

let side = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

// The standard macOS icon tile: 824 points square on a 1024 canvas, with a soft shadow beneath.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
context.addPath(tilePath)
context.setFillColor(color(0.2, 0.1, 0.3))
context.fillPath()
context.restoreGState()

// Background: the waveform's colours, gold through pink to blue.
context.saveGState()
context.addPath(tilePath)
context.clip()
context.drawLinearGradient(
    gradient([(0, color(1.00, 0.80, 0.42)), (0.45, color(1.00, 0.32, 0.55)), (1, color(0.27, 0.30, 0.95))]),
    start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// A soft light from the top.
context.drawLinearGradient(
    gradient([(0, color(1, 1, 1, 0.22)), (0.5, color(1, 1, 1, 0))]),
    start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
context.restoreGState()

let center = CGPoint(x: 512, y: 512)
let recordRadius: CGFloat = 338
let labelRadius: CGFloat = 118

// The record, with a shadow onto the tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0.10, 0.02, 0.25, 0.55))
context.setFillColor(color(0.05, 0.05, 0.07))
context.fillEllipse(in: circle(center, recordRadius))
context.restoreGState()

// A touch of depth: slightly lighter towards the middle.
context.saveGState()
context.addEllipse(in: circle(center, recordRadius))
context.clip()
context.drawRadialGradient(
    gradient([(0, color(0.16, 0.16, 0.20)), (1, color(0.04, 0.04, 0.06))]),
    startCenter: center, startRadius: labelRadius, endCenter: center, endRadius: recordRadius, options: [])

// Grooves: fine rings, with wider dark gaps between the "tracks".
let gaps: [CGFloat] = [176, 232, 281]
var radius = labelRadius + 22
var ring = 0
while radius < recordRadius - 14 {
    let nearGap = gaps.contains { abs($0 - radius) < 5 }
    if !nearGap {
        context.setStrokeColor(color(1, 1, 1, ring % 2 == 0 ? 0.085 : 0.035))
        context.setLineWidth(1.3)
        context.strokeEllipse(in: circle(center, radius))
    }
    radius += 3.6
    ring += 1
}

// The sheen: two bright wedges opposite each other, as light catches the grooves.
for degree in stride(from: 0.0, to: 360.0, by: 0.5) {
    let angle = degree * .pi / 180
    let lobe = pow(max(0, cos(2 * (angle - 0.62 * .pi))), 6)   // two lobes, half a turn apart
    guard lobe > 0.002 else { continue }
    let step = 0.5 * Double.pi / 180
    let wedge = CGMutablePath()
    wedge.move(to: center)
    wedge.addArc(center: center, radius: recordRadius - 6, startAngle: angle, endAngle: angle + step * 1.3, clockwise: false)
    wedge.closeSubpath()
    context.addPath(wedge)
    context.setFillColor(color(1, 1, 1, 0.30 * lobe))
    context.fillPath()
}
// A thin bright rim.
context.setStrokeColor(color(1, 1, 1, 0.16))
context.setLineWidth(3)
context.strokeEllipse(in: circle(center, recordRadius - 2.5))
context.restoreGState()

// The label.
context.saveGState()
context.addEllipse(in: circle(center, labelRadius))
context.clip()
context.drawLinearGradient(
    gradient([(0, color(1.00, 0.95, 0.84)), (1, color(1.00, 0.84, 0.62))]),
    start: CGPoint(x: center.x - labelRadius, y: center.y + labelRadius),
    end: CGPoint(x: center.x + labelRadius, y: center.y - labelRadius), options: [])
context.restoreGState()
context.setStrokeColor(color(1.00, 0.32, 0.55))
context.setLineWidth(9)
context.strokeEllipse(in: circle(center, labelRadius - 20))
context.setStrokeColor(color(0.27, 0.30, 0.95))
context.setLineWidth(4)
context.strokeEllipse(in: circle(center, labelRadius - 36))
context.setStrokeColor(color(0, 0, 0, 0.35))
context.setLineWidth(2)
context.strokeEllipse(in: circle(center, labelRadius))

// The spindle hole.
context.setFillColor(color(0.08, 0.06, 0.12))
context.fillEllipse(in: circle(center, 15))

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
