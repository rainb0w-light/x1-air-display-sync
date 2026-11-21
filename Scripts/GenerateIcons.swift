import AppKit
import CoreGraphics
import Foundation

func png(size: Int, draw: (CGContext) -> Void) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(context)
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    guard let data = image.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, with color: CGColor) {
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
}

func gradient(_ context: CGContext, path: CGPath, from: CGPoint, to: CGPoint, colors: [CGColor]) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: from, end: to, options: [])
    context.restoreGState()
}

func appMark(size: Int) throws -> Data {
    try png(size: size) { context in
        let scale = CGFloat(size) / 1024
        context.scaleBy(x: scale, y: scale)

        let tile = rounded(CGRect(x: 70, y: 70, width: 884, height: 884), radius: 206)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0.01, 0.03, 0.08, 0.32))
        fill(context, tile, with: rgb(0.04, 0.12, 0.25))
        context.restoreGState()
        gradient(context, path: tile, from: CGPoint(x: 124, y: 130), to: CGPoint(x: 914, y: 914),
                 colors: [rgb(0.025, 0.065, 0.15), rgb(0.09, 0.28, 0.48)])

        for (index, screen) in [CGRect(x: 248, y: 530, width: 528, height: 226),
                           CGRect(x: 248, y: 268, width: 528, height: 226)].enumerated() {
            let frame = rounded(screen, radius: 42)
            fill(context, frame, with: rgb(0.6, 0.90, 0.98))
            let glass = rounded(screen.insetBy(dx: 20, dy: 20), radius: 26)
            let colors = index == 0
                ? [rgb(0.05, 0.33, 0.64), rgb(0.18, 0.72, 0.86)]
                : [rgb(0.04, 0.43, 0.57), rgb(0.21, 0.80, 0.73)]
            gradient(context, path: glass,
                     from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY),
                     colors: colors)
        }

        let link = rounded(CGRect(x: 490, y: 475, width: 44, height: 74), radius: 17)
        fill(context, link, with: rgb(0.83, 1, 0.98))
    }
}

func menuMark() throws -> Data {
    try png(size: 36) { context in
        context.scaleBy(x: 2, y: 2)
        context.setLineWidth(1.35)
        context.setStrokeColor(gray: 0, alpha: 1)
        for y: CGFloat in [3, 10] {
            context.addPath(rounded(CGRect(x: 2.75, y: y, width: 12.5, height: 5), radius: 1.1))
            context.strokePath()
        }
        fill(context, rounded(CGRect(x: 8.2, y: 7.7, width: 1.6, height: 2.6), radius: 0.65),
             with: .black)
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for dimension in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(dimension)x\(dimension)\(suffix).png"
        try appMark(size: dimension * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try appMark(size: 512).write(to: output.appendingPathComponent("Logo.png"))
try menuMark().write(to: output.appendingPathComponent("MenuBar.png"))
