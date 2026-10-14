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

// Optional second argument: the Windows .ico (rivet.rktd's windows-icon).
// PNG-compressed entries across the standard size ladder — Explorer list
// view, taskbar and title bar each pick a crisp scale instead of one
// blurry 256 px downscale (same output chain as podlens' make-icons.py).
if CommandLine.arguments.count > 2 {
    func le16(_ value: UInt16, into data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func le32(_ value: UInt32, into data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    let sizes = [16, 24, 32, 48, 64, 128, 256]
    var blobs: [Data] = []
    for edge in sizes {
        let icoCtx = CGContext(data: nil, width: edge, height: edge,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        icoCtx.interpolationQuality = .high
        icoCtx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(edge), height: CGFloat(edge)))
        let scaled = icoCtx.makeImage()!
        let data = NSMutableData()
        let icoDest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(icoDest, scaled, nil)
        CGImageDestinationFinalize(icoDest)
        blobs.append(data as Data)
    }

    var ico = Data()
    le16(0, into: &ico)                       // reserved
    le16(1, into: &ico)                       // type: icon
    le16(UInt16(sizes.count), into: &ico)     // entry count
    var offset = 6 + 16 * sizes.count
    for (index, edge) in sizes.enumerated() {
        ico.append(UInt8(edge == 256 ? 0 : edge))  // width (0 means 256)
        ico.append(UInt8(edge == 256 ? 0 : edge))  // height
        ico.append(0)                              // palette color count
        ico.append(0)                              // reserved
        le16(1, into: &ico)                        // color planes
        le16(32, into: &ico)                       // bits per pixel
        le32(UInt32(blobs[index].count), into: &ico)
        le32(UInt32(offset), into: &ico)
        offset += blobs[index].count
    }
    for blob in blobs { ico.append(blob) }
    try! ico.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("wrote \(CommandLine.arguments[2])")
}
