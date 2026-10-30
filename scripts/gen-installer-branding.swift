// Generate the installer branding assets from the app icon:
//   - Windows wizard bitmaps at WiX standard dimensions: banner 493x58
//     (WixUIBannerBmp; dark, so the white title text reads) and dialog
//     493x312 (WixUIDialogBmp; light, so body copy reads). The wizard text
//     overlays the right side, so the icon sits at the left edge.
//   - macOS DMG background 660x400, matching rivet's dmg-window geometry
//     (icons for the app and Applications live at mid-height, left and
//     right); the title and the drag hint stay clear of both.
//
// Usage: swift gen-installer-branding.swift <icon.png> <out-dir>

import AppKit

guard CommandLine.arguments.count == 3 else {
    print("usage: gen-installer-bitmaps.swift <icon.png> <out-dir>")
    exit(1)
}
let iconPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

func loadIcon(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else {
        print("cannot read icon: \(path)")
        exit(1)
    }
    return image
}

func renderText(_ text: String, size: CGFloat, weight: NSFont.Weight,
                color: NSColor, centeredAt y: CGFloat, in width: Int) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let drawn = NSAttributedString(string: text, attributes: attrs)
    let bounds = drawn.size()
    drawn.draw(at: NSPoint(x: (CGFloat(width) - bounds.width) / 2, y: y))
}

func render(width: Int, height: Int, icon: NSImage, iconSize: CGFloat,
            iconX: CGFloat, background: NSColor, out: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: width,
                               pixelsHigh: height,
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context

    background.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // subtle vertical divider shading so the field is not perfectly flat
    NSColor(white: 1.0, alpha: 0.04).setFill()
    NSRect(x: 0, y: 0, width: width, height: 1).fill()

    let target = NSRect(x: iconX, y: (CGFloat(height) - iconSize) / 2,
                        width: iconSize, height: iconSize)
    icon.draw(in: target,
              from: NSRect(x: 0, y: 0, width: icon.size.width, height: icon.size.height),
              operation: .sourceOver,
              fraction: 1.0,
              respectFlipped: false,
              hints: [.interpolation: NSImageInterpolation.high])
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .bmp, properties: [:]) else {
        print("BMP encoding failed for \(out)")
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(width)x\(height))")
    } catch {
        print("write failed: \(error)")
        exit(1)
    }
}

let icon = loadIcon(iconPath)
render(width: 493, height: 58, icon: icon, iconSize: 44, iconX: 7,
       background: NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1),
       out: outDir + "/wizard-banner.bmp")
render(width: 493, height: 312, icon: icon, iconSize: 56, iconX: 20,
       background: NSColor(calibratedWhite: 0.96, alpha: 1),
       out: outDir + "/wizard-dialog.bmp")

// DMG background: dark brand field; the window's icon row (app left,
// Applications right) sits at mid-height and must stay clear.
do {
    let width = 660, height = 400
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: width,
                               pixelsHigh: height,
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    // y in the bitmap context is bottom-up; the window is 400 tall
    renderText("Keyward", size: 28, weight: .semibold,
               color: NSColor(calibratedWhite: 0.97, alpha: 1),
               centeredAt: CGFloat(height) - 78, in: width)
    renderText("Release-signing key vault", size: 15, weight: .regular,
               color: NSColor(calibratedWhite: 0.72, alpha: 1),
               centeredAt: CGFloat(height) - 112, in: width)
    renderText("Drag Keyward into Applications to install", size: 13, weight: .regular,
               color: NSColor(calibratedWhite: 0.62, alpha: 1),
               centeredAt: 52, in: width)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("PNG encoding failed for dmg-background")
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: outDir + "/dmg-background.png"))
        print("wrote \(outDir)/dmg-background.png (660x400)")
    } catch {
        print("write failed: \(error)")
        exit(1)
    }
}
