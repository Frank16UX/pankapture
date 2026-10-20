// Renders Pankapture's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (or: make icon)
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824×824 body centered on a 1024 canvas, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    cg.addPath(shape)
    cg.setFillColor(CGColor(gray: 0, alpha: 1))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.33, green: 0.24, blue: 0.95, alpha: 1),
                                       CGColor(srgbRed: 0.16, green: 0.56, blue: 0.98, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Subtle top highlight.
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    cg.restoreGState()

    // Viewfinder corners.
    cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
    cg.setLineWidth(62)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    let inset: CGFloat = 250, arm: CGFloat = 150
    let minP = inset, maxP = 1024 - inset
    for (x, y, dx, dy) in [(minP, maxP, 1.0, -1.0), (maxP, maxP, -1.0, -1.0), (minP, minP, 1.0, 1.0), (maxP, minP, -1.0, 1.0)] {
        cg.move(to: CGPoint(x: x, y: y + dy * arm))
        cg.addLine(to: CGPoint(x: x, y: y))
        cg.addLine(to: CGPoint(x: x + dx * arm, y: y))
    }
    cg.strokePath()

    // Record dot.
    cg.setFillColor(CGColor(srgbRed: 1, green: 0.33, blue: 0.30, alpha: 1))
    cg.fillEllipse(in: CGRect(x: 512 - 92, y: 512 - 92, width: 184, height: 184))
    cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
    cg.setLineWidth(22)
    cg.strokeEllipse(in: CGRect(x: 512 - 92, y: 512 - 92, width: 184, height: 184))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "✓ \(output.path)" : "iconutil failed")
