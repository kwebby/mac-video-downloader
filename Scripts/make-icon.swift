import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("MVDIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Draw the exact geometry of Assets/mvd-download.svg, preserving vector edges
// at every macOS icon size. No third-party renderer or font is required.
func png(_ pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "MVDIcon", code: 1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 64, y: CGFloat(pixels) / 64)
    NSColor(srgbRed: 22.0/255, green: 135.0/255, blue: 75.0/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 60, height: 60), xRadius: 15, yRadius: 15).fill()
    NSColor.white.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 4.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 32, y: 50)); arrow.line(to: NSPoint(x: 32, y: 24))
    arrow.move(to: NSPoint(x: 22, y: 34)); arrow.line(to: NSPoint(x: 32, y: 24)); arrow.line(to: NSPoint(x: 42, y: 34))
    arrow.move(to: NSPoint(x: 17, y: 24)); arrow.line(to: NSPoint(x: 17, y: 16))
    arrow.curve(to: NSPoint(x: 20, y: 13), controlPoint1: NSPoint(x: 17, y: 14.3), controlPoint2: NSPoint(x: 18.3, y: 13))
    arrow.line(to: NSPoint(x: 44, y: 13))
    arrow.curve(to: NSPoint(x: 47, y: 16), controlPoint1: NSPoint(x: 45.7, y: 13), controlPoint2: NSPoint(x: 47, y: 14.3))
    arrow.line(to: NSPoint(x: 47, y: 24)); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "MVDIcon", code: 2) }
    return data
}

for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(128).write(to: output.appendingPathComponent("MVDMark.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("MVDIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { throw NSError(domain: "MVDIcon", code: 3) }
