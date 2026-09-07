// Renders Ledge's app icon and assembles it into an .icns.
//
// The design is original: a dark rounded tile carrying the notch the app draws
// in, with a pair of eyes lit inside it — the face Ledge shows when it starts.
//
// On the obvious question: a pair of simple geometric eyes is not anyone's
// property, but a *specific* character design is, so this deliberately avoids
// the things that would make it read as one. There is no robot, no white
// ovoid head, no blue-on-black. The subject is the MacBook's notch, which is
// this app's own, and the eyes are warm — the amber Ledge already uses — cut
// with a flat base and a soft dome rather than the slanted lozenges of any
// character in particular.
//
// Run: swift Scripts/makeicon.swift  (writes build/AppIcon.icns)

import AppKit
import CoreGraphics
import Foundation

/// Draws the icon at a given pixel size into a bitmap.
func renderIcon(size: Int) -> CGImage? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS icons leave a transparent margin; content fills the middle ~80%.
    let margin = dimension * 0.10
    let tile = CGRect(x: margin, y: margin, width: dimension - margin * 2, height: dimension - margin * 2)
    let corner = tile.width * 0.235   // Apple's continuous-corner proportion

    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Background: a soft top-to-bottom gradient, espresso into near-black, so
    // the notch reads as light on dark.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let bgColors = [
        CGColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: bgColors,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end: CGPoint(x: tile.midX, y: tile.minY),
            options: []
        )
    }
    context.restoreGState()

    // The notch silhouette: a rounded pill hanging from the top of the tile,
    // roughly the proportion of the real cutout, with a warm glow behind it.
    //
    // Wider and deeper than the real cutout on purpose. At sixteen points the
    // icon has room for one idea, and the idea is the face: the pill has to be
    // big enough to hold two eyes that still read at that size.
    let notchWidth = tile.width * 0.72
    let notchHeight = tile.height * 0.42
    // Hung from the top edge, not floating in the middle. A notch is a bite
    // taken out of a screen; a rounded rectangle sitting in space is a box.
    // Square where it meets the top, generously rounded where it ends.
    let notch = CGRect(
        x: tile.midX - notchWidth / 2,
        y: tile.maxY - notchHeight,
        width: notchWidth,
        height: notchHeight
    )
    let notchCorner = notchHeight * 0.46
    let notchPath = CGMutablePath()
    notchPath.move(to: CGPoint(x: notch.minX, y: notch.maxY))
    notchPath.addLine(to: CGPoint(x: notch.minX, y: notch.minY + notchCorner))
    notchPath.addQuadCurve(
        to: CGPoint(x: notch.minX + notchCorner, y: notch.minY),
        control: CGPoint(x: notch.minX, y: notch.minY)
    )
    notchPath.addLine(to: CGPoint(x: notch.maxX - notchCorner, y: notch.minY))
    notchPath.addQuadCurve(
        to: CGPoint(x: notch.maxX, y: notch.minY + notchCorner),
        control: CGPoint(x: notch.maxX, y: notch.minY)
    )
    notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY))
    notchPath.closeSubpath()

    // The notch itself is black — it is a hole in a screen, and drawing it
    // bright made the icon a lamp rather than a display.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.addPath(notchPath)
    context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
    context.fillPath()
    // A hairline of warm light along its edge, which is what separates the
    // black of the notch from the near-black of the tile at small sizes.
    context.addPath(notchPath)
    context.setStrokeColor(CGColor(red: 1.0, green: 0.62, blue: 0.36, alpha: 0.28))
    context.setLineWidth(max(dimension * 0.004, 1))
    context.strokePath()
    context.restoreGState()

    // The eyes: two domes, flat along the base, lit warm.
    let eyeWidth = notch.width * 0.30
    let eyeHeight = notch.height * 0.30
    let eyeGap = notch.width * 0.15
    // Sat in the lower half of the notch, where a face's eyes are — and where
    // the shape is widest, so they are not crowded by the corners.
    let baseline = notch.minY + notch.height * 0.26
    for side in [-1.0, 1.0] as [CGFloat] {
        let centre = notch.midX + side * (eyeGap / 2 + eyeWidth / 2)
        let box = CGRect(
            x: centre - eyeWidth / 2,
            y: baseline,
            width: eyeWidth,
            height: eyeHeight
        )
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: box.minX, y: box.minY))
        // The dome peaks away from the middle, so the pair leans outward —
        // the same asymmetry the app's own greeting draws.
        let lean = box.width * 0.16 * side
        eye.addCurve(
            to: CGPoint(x: box.maxX, y: box.minY),
            control1: CGPoint(x: box.minX + box.width * 0.06 + lean, y: box.maxY),
            control2: CGPoint(x: box.maxX - box.width * 0.06 + lean, y: box.maxY)
        )
        eye.closeSubpath()

        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        context.setShadow(
            offset: .zero,
            blur: eyeHeight * 0.75,
            color: CGColor(red: 1.0, green: 0.68, blue: 0.36, alpha: 0.85)
        )
        context.addPath(eye)
        context.setFillColor(CGColor(red: 1.0, green: 0.80, blue: 0.55, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "makeicon", code: 1)
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let buildDir = root.appendingPathComponent("build")
let iconset = buildDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, base and @2x.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = renderIcon(size: variant.size) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try writePNG(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

// Assemble.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", buildDir.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

print("wrote build/AppIcon.icns")
