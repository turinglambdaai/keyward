// Generate the Windows installer wizard bitmaps (WiX standard dimensions)
// from the app icon: banner 493x58 (WixUIBannerBmp) and dialog 493x312
// (WixUIDialogBmp). The wizard text overlays the right side, so the icon
// sits at the left edge and the rest stays a quiet dark field matching the
// app's dark theme.
//
// Usage: swift gen-installer-bitmaps.swift <icon.png> <out-dir>

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
