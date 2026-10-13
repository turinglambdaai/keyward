import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let S = 1024.0
let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let plate = CGRect(x: 100, y: 96, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
              color: CGColor(red: 0.32, green: 0.12, blue: 0.05, alpha: 0.30))
ctx.addPath(platePath)
ctx.setFillColor(CGColor(red: 0.42, green: 0.19, blue: 0.10, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(platePath)
ctx.clip()
let grad = CGGradient(colorsSpace: nil, colors: [
    CGColor(red: 0.906, green: 0.573, blue: 0.400, alpha: 1),
    CGColor(red: 0.757, green: 0.376, blue: 0.216, alpha: 1),
    CGColor(red: 0.596, green: 0.263, blue: 0.145, alpha: 1),
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// vault dial: ring + hub
let dial = CGPoint(x: 418, y: 512)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.97)
ctx.setStrokeColor(white)
ctx.setLineWidth(60)
ctx.addEllipse(in: CGRect(x: dial.x - 192, y: dial.y - 192, width: 384, height: 384))
ctx.strokePath()
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: dial.x - 50, y: dial.y - 50, width: 100, height: 100))

// key shaft + two teeth (round caps), clear of the ring
ctx.setStrokeColor(white)
ctx.setLineWidth(54)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: dial.x + 172, y: dial.y))
ctx.addLine(to: CGPoint(x: 800, y: dial.y))
ctx.strokePath()
for toothX in [716.0, 800.0] {
    ctx.move(to: CGPoint(x: toothX, y: dial.y - 2))
    ctx.addLine(to: CGPoint(x: toothX, y: dial.y - 108))
    ctx.strokePath()
}

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
