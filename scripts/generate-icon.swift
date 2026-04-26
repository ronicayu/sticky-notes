import AppKit
import Foundation

// Renders the StickyNotes icon (per the user's SVG: yellow rounded body
// with a translucent amber tab) at every size .icns needs, plus template
// PNGs for the menu bar.
//
// Layout in 512-unit SVG space:
//   body: rect (80, 100) 352×332, corner radius 60, fill #FDE68A
//   tab:  rect (176, 70) 160×60,  corner radius 12, fill #F59E0B @ 0.4

let bodyColor = NSColor(srgbRed: 0xFD / 255.0, green: 0xE6 / 255.0, blue: 0x8A / 255.0, alpha: 1.0)
let tabColor  = NSColor(srgbRed: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0, alpha: 0.4)

func draw(in size: CGFloat, template: Bool) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = size / 512.0
    // Convert SVG top-left coords to AppKit bottom-left.
    let bodyRect = NSRect(
        x: 80 * scale,
        y: size - (100 + 332) * scale,
        width: 352 * scale,
        height: 332 * scale
    )
    let tabRect = NSRect(
        x: 176 * scale,
        y: size - (70 + 60) * scale,
        width: 160 * scale,
        height: 60 * scale
    )

    if template {
        drawMenuBarTemplate(size: size)
    } else {
        bodyColor.setFill()
        NSBezierPath(roundedRect: bodyRect, xRadius: 60 * scale, yRadius: 60 * scale).fill()
        tabColor.setFill()
        NSBezierPath(roundedRect: tabRect, xRadius: 12 * scale, yRadius: 12 * scale).fill()
    }

    return rep
}

/// Menu-bar version: at 18pt the original body+tab silhouette flattens into
/// what looks like a featureless square. We redraw with a slightly portrait
/// body, a clearly-detached tab on top, and three knocked-out "text lines"
/// so the silhouette reads as a written note rather than a square.
func drawMenuBarTemplate(size: CGFloat) {
    let scale = size / 512.0
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // Wider gap between body and tab makes them legible at 18pt.
    let bodyRect = NSRect(
        x: 96 * scale,
        y: size - (172 + 280) * scale,
        width: 320 * scale,
        height: 280 * scale
    )
    let tabRect = NSRect(
        x: 200 * scale,
        y: size - (84 + 60) * scale,
        width: 112 * scale,
        height: 60 * scale
    )

    NSColor.black.setFill()
    NSBezierPath(roundedRect: bodyRect, xRadius: 48 * scale, yRadius: 48 * scale).fill()
    NSBezierPath(roundedRect: tabRect, xRadius: 16 * scale, yRadius: 16 * scale).fill()

    // Knock out three horizontal text lines using destination-out blending.
    let lines: [NSRect] = [
        NSRect(x: 152 * scale, y: size - (220 + 32) * scale, width: 208 * scale, height: 32 * scale),
        NSRect(x: 152 * scale, y: size - (276 + 32) * scale, width: 208 * scale, height: 32 * scale),
        NSRect(x: 152 * scale, y: size - (332 + 32) * scale, width: 144 * scale, height: 32 * scale)
    ]
    ctx.saveGState()
    ctx.setBlendMode(.destinationOut)
    for line in lines {
        NSBezierPath(roundedRect: line, xRadius: 8 * scale, yRadius: 8 * scale).fill()
    }
    ctx.restoreGState()
}

func png(_ rep: NSBitmapImageRep) -> Data {
    return rep.representation(using: .png, properties: [:])!
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = cwd.appendingPathComponent("Resources", isDirectory: true)
let iconset = cwd.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let iconSizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, dim) in iconSizes {
    let data = png(draw(in: dim, template: false))
    try data.write(to: iconset.appendingPathComponent(name))
}

// Menu bar template at 1x and 2x. Common menubar size is 18pt.
try png(draw(in: 18, template: true))
    .write(to: resources.appendingPathComponent("MenuBarIcon.png"))
try png(draw(in: 36, template: true))
    .write(to: resources.appendingPathComponent("MenuBarIcon@2x.png"))

print("Wrote \(iconSizes.count) icon PNGs to build/AppIcon.iconset")
print("Wrote menu bar templates to Resources/")
