import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func paint(size: Int, name: String) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 84, y: 94, width: 856, height: 856),
                      cornerWidth: 190, cornerHeight: 190, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -20), blur: 25,
                      color: CGColor(red: 0.05, green: 0.1, blue: 0.22, alpha: 0.30))
    context.setFillColor(CGColor(red: 0.07, green: 0.18, blue: 0.46, alpha: 1))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.07, green: 0.16, blue: 0.40, alpha: 1),
        CGColor(red: 0.18, green: 0.38, blue: 0.74, alpha: 1),
        CGColor(red: 0.30, green: 0.57, blue: 0.91, alpha: 1)
    ] as CFArray, locations: [0, 0.61, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 900, y: 90),
                               end: CGPoint(x: 125, y: 950), options: [])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
    context.setLineWidth(5)
    context.strokePath()

    let paper = CGPath(roundedRect: CGRect(x: 278, y: 250, width: 468, height: 540),
                       cornerWidth: 85, cornerHeight: 85, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -17), blur: 24,
                      color: CGColor(red: 0.02, green: 0.11, blue: 0.34, alpha: 0.45))
    context.setFillColor(CGColor(red: 0.95, green: 0.98, blue: 1, alpha: 1))
    context.addPath(paper)
    context.fillPath()
    context.restoreGState()

    context.setLineCap(.round)
    context.setLineWidth(28)
    let heights: [CGFloat] = [42, 98, 173, 120, 64, 34]
    for (index, height) in heights.enumerated() {
        let x = 366 + CGFloat(index) * 58
        context.setStrokeColor(CGColor(red: 0.15, green: 0.37 + CGFloat(index) * 0.025, blue: 0.80, alpha: 1))
        context.move(to: CGPoint(x: x, y: 574 - height / 2))
        context.addLine(to: CGPoint(x: x, y: 574 + height / 2))
        context.strokePath()
    }
    context.setStrokeColor(CGColor(red: 0.52, green: 0.67, blue: 0.88, alpha: 1))
    context.setLineWidth(21)
    for (end, y) in [(660.0, 420.0), (575.0, 367.0)] {
        context.move(to: CGPoint(x: 365, y: y))
        context.addLine(to: CGPoint(x: end, y: y))
        context.strokePath()
    }

    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for size in [16, 32, 128, 256, 512] {
    try paint(size: size, name: "icon_\(size)x\(size).png")
    try paint(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}

func lengthBytes(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
]
var chunks = Data()
for (type, file) in representations {
    let png = try Data(contentsOf: folder.appendingPathComponent(file))
    chunks.append(Data(type.utf8))
    chunks.append(lengthBytes(8 + png.count))
    chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(lengthBytes(8 + chunks.count))
icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
