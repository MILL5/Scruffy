#!/usr/bin/swift

import Cocoa

let width = 660
let height = 400
let s = CGFloat(width)
let h = CGFloat(height)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("Failed to create bitmap")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

let bounds = CGRect(x: 0, y: 0, width: s, height: h)

// Scruffy slate background
context.setFillColor(NSColor(red: 0.30, green: 0.42, blue: 0.48, alpha: 1.0).cgColor)
context.fill(bounds)

// Radial gradient for subtle depth
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradColors = [
    NSColor(red: 0.36, green: 0.50, blue: 0.57, alpha: 1.0).cgColor,
    NSColor(red: 0.24, green: 0.34, blue: 0.40, alpha: 1.0).cgColor,
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
    context.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: s * 0.5, y: h * 0.5), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.5, y: h * 0.5), endRadius: s * 0.6,
                               options: .drawsAfterEndLocation)
}

// Arrow pointing from app to Applications
let arrowY = h * 0.52
let arrowStartX = s * 0.36
let arrowEndX = s * 0.64
let arrowColor = NSColor(white: 1.0, alpha: 0.5)

context.setStrokeColor(arrowColor.cgColor)
context.setLineWidth(3.5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: arrowStartX, y: arrowY))
context.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
context.strokePath()
// Arrowhead
context.move(to: CGPoint(x: arrowEndX - 16, y: arrowY + 12))
context.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
context.addLine(to: CGPoint(x: arrowEndX - 16, y: arrowY - 12))
context.strokePath()

// Branding text at the top using Core Text (works correctly with CG coordinates)
import CoreText

let titleStr = NSAttributedString(string: "Scruffy", attributes: [
    .font: NSFont.systemFont(ofSize: 26, weight: .bold),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.95),
])
let subtitleStr = NSAttributedString(string: "by Richard Crane  \u{00B7}  Inventing Fire with AI", attributes: [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.75),
])

let urlStr = NSAttributedString(string: "https://inventingfirewith.ai", attributes: [
    .font: NSFont.systemFont(ofSize: 18, weight: .bold),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.65),
])

let titleLine = CTLineCreateWithAttributedString(titleStr)
let subtitleLine = CTLineCreateWithAttributedString(subtitleStr)
let urlLine = CTLineCreateWithAttributedString(urlStr)

let titleWidth = CTLineGetBoundsWithOptions(titleLine, []).width
let subtitleWidth = CTLineGetBoundsWithOptions(subtitleLine, []).width
let urlWidth = CTLineGetBoundsWithOptions(urlLine, []).width

let topY = h - 38  // top of the image in CG coords (Y goes up)

context.saveGState()
context.textPosition = CGPoint(x: (s - titleWidth) / 2, y: topY)
CTLineDraw(titleLine, context)
context.textPosition = CGPoint(x: (s - subtitleWidth) / 2, y: topY - 26)
CTLineDraw(subtitleLine, context)
context.textPosition = CGPoint(x: (s - urlWidth) / 2, y: topY - 52)
CTLineDraw(urlLine, context)
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to create PNG")
    exit(1)
}

let outputPath = CommandLine.arguments.dropFirst().first ?? "dist/dmg-background.png"
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Created \(outputPath) (\(width)x\(height))")
