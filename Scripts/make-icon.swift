// Draws Docklane's app icon with Core Graphics and packs it into Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift [icns-dir] [preview.png]   (defaults: Resources, docs/icon.png)
//
// Design: a dark glass squircle with a blue rim light, and three window cards stepping
// forward from left to right — two dim ones behind, the focused one bright in front.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let previewPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "docs/icon.png"

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ stops: [(UInt32, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: locations)!
}

/// Apple-style continuous-corner squircle (superellipse) filling `rect`.
func squircle(_ rect: CGRect, exponent n: CGFloat = 4.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// A quadrilateral with rounded corners. Points go clockwise from the top-left.
func roundedQuad(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let count = points.count
    let start = CGPoint(x: (points[count - 1].x + points[0].x) / 2, y: (points[count - 1].y + points[0].y) / 2)
    path.move(to: start)
    for index in 0..<count {
        path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % count], radius: radius)
    }
    path.closeSubpath()
    return path
}

/// Glow that falls inside `path` from its edge.
func innerGlow(_ ctx: CGContext, _ path: CGPath, color glow: CGColor, blur: CGFloat, offset: CGSize = .zero) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let ring = CGMutablePath()
    ring.addRect(CGRect(x: -size, y: -size, width: size * 3, height: size * 3))
    ring.addPath(path)
    ctx.setShadow(offset: offset, blur: blur, color: glow)
    ctx.addPath(ring)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

func render() -> CGImage {
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }

    // MARK: Body — macOS grid: 824 pt body centred in 1024.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.5))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0A0F1C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    // Deep navy, darkest in the middle, lifting toward the edges.
    ctx.drawRadialGradient(gradient([(0x04070D, 1), (0x0A101E, 1), (0x18243E, 1)], [0, 0.6, 1]),
                           startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 600, options: [.drawsAfterEndLocation])
    // Cool light pooling at the bottom and the upper right.
    ctx.drawRadialGradient(gradient([(0x1F4FB0, 0.4), (0x1F4FB0, 0)], [0, 1]),
                           startCenter: CGPoint(x: 560, y: 110), startRadius: 0,
                           endCenter: CGPoint(x: 560, y: 110), endRadius: 330, options: [])
    ctx.drawRadialGradient(gradient([(0x3B5C9A, 0.35), (0x3B5C9A, 0)], [0, 1]),
                           startCenter: CGPoint(x: 900, y: 700), startRadius: 0,
                           endCenter: CGPoint(x: 900, y: 700), endRadius: 360, options: [])
    ctx.restoreGState()

    // Rim light: soft inner glow all round, stronger along the top edge.
    innerGlow(ctx, bodyPath, color: color(0x4E6EAE, 0.5), blur: 40)
    innerGlow(ctx, bodyPath, color: color(0x9DB8EA, 0.4), blur: 14, offset: CGSize(width: 0, height: -5))
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xC8D8F5, 0.6), (0x6E8CC4, 0.25), (0x5A78B8, 0.45)], [0, 0.5, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // MARK: Cards (y grows upward; each card's top edge dips slightly to the right).
    func backCard(_ points: [CGPoint], radius: CGFloat, brightness: CGFloat, dots: CGPoint) {
        let path = roundedQuad(points, radius: radius)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 10, height: -6), blur: 30, color: color(0x000000, 0.7))
        ctx.addPath(path)
        ctx.setFillColor(color(0x0C1322))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let box = path.boundingBox
        ctx.drawLinearGradient(gradient([(0x5A6E96, 0.55 * brightness), (0x1B2640, 0.6), (0x0A101D, 0.9)],
                                        [0, 0.45, 1]),
                               start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.minX + 120, y: box.minY),
                               options: [])
        ctx.restoreGState()
        innerGlow(ctx, path, color: color(0x8FA8D8, 0.6 * brightness), blur: 14)

        // Thin glass edge, bright at the top-left.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0xDDE8FF, 0.85 * brightness), (0x7C93C4, 0.3)], [0, 1]),
                               start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.minX + 60, y: box.minY),
                               options: [])
        ctx.restoreGState()

        for index in 0..<2 {
            ctx.setFillColor(color(0xDCE6FA, 0.55 + 0.2 * brightness))
            let d: CGFloat = 23
            ctx.fillEllipse(in: CGRect(x: dots.x + CGFloat(index) * 32, y: dots.y, width: d, height: d))
        }
    }

    backCard([CGPoint(x: 194, y: 652), CGPoint(x: 330, y: 640), CGPoint(x: 330, y: 333), CGPoint(x: 194, y: 333)],
             radius: 36, brightness: 0.75, dots: CGPoint(x: 222, y: 592))
    backCard([CGPoint(x: 303, y: 700), CGPoint(x: 470, y: 690), CGPoint(x: 470, y: 335), CGPoint(x: 303, y: 335)],
             radius: 40, brightness: 1, dots: CGPoint(x: 335, y: 637))

    // Front card: the focused window.
    let front = [CGPoint(x: 442, y: 737), CGPoint(x: 836, y: 683), CGPoint(x: 836, y: 340), CGPoint(x: 442, y: 340)]
    let frontPath = roundedQuad(front, radius: 46)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: color(0x6F9BFF, 0.55))
    ctx.addPath(frontPath)
    ctx.setFillColor(color(0x5B83F0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x02040A, 0.6))
    ctx.addPath(frontPath)
    ctx.setFillColor(color(0x5B83F0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.clip()
    // Periwinkle base, frosted on the left.
    ctx.drawLinearGradient(gradient([(0x7184BE, 1), (0x6A86DF, 1), (0x5C86F6, 1)], [0, 0.45, 1]),
                           start: CGPoint(x: 442, y: 500), end: CGPoint(x: 836, y: 520), options: [])
    // Saturated blue core.
    ctx.drawRadialGradient(gradient([(0x2F62F4, 0.95), (0x3A6CF5, 0.45), (0x3A6CF5, 0)], [0, 0.5, 1]),
                           startCenter: CGPoint(x: 700, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 700, y: 540), endRadius: 260, options: [])
    // Aqua light from the top-right corner.
    ctx.drawRadialGradient(gradient([(0xA6F0F7, 1), (0x7FDDF2, 0.6), (0x7FDDF2, 0)], [0, 0.4, 1]),
                           startCenter: CGPoint(x: 850, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 850, y: 640), endRadius: 250, options: [])
    // Lavender at the bottom-right.
    ctx.drawRadialGradient(gradient([(0xE6D2FA, 1), (0xB9A2F2, 0.55), (0xB9A2F2, 0)], [0, 0.35, 1]),
                           startCenter: CGPoint(x: 845, y: 345), startRadius: 0,
                           endCenter: CGPoint(x: 845, y: 345), endRadius: 200, options: [])
    // Pale wash along the bottom-left.
    ctx.drawRadialGradient(gradient([(0xB4C4EC, 0.55), (0xB4C4EC, 0)], [0, 1]),
                           startCenter: CGPoint(x: 520, y: 330), startRadius: 0,
                           endCenter: CGPoint(x: 520, y: 330), endRadius: 200, options: [])
    // Gloss on the upper half.
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.22), (0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 600, y: 737), end: CGPoint(x: 600, y: 560), options: [])
    ctx.restoreGState()

    // Luminous glass edge: brightest at the top-left, softer toward the bottom-right.
    innerGlow(ctx, frontPath, color: color(0xFFFFFF, 0.75), blur: 20)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: color(0xCFE0FF, 0.8))
    ctx.addPath(frontPath)
    ctx.setLineWidth(3.5)
    ctx.setStrokeColor(color(0xFFFFFF, 0.5))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.setLineWidth(3.5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 1), (0xF2F6FF, 0.85), (0xE4DAFF, 0.55)], [0, 0.5, 1]),
                           start: CGPoint(x: 442, y: 737), end: CGPoint(x: 836, y: 340), options: [])
    ctx.restoreGState()

    // Title-bar dots.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 10, color: color(0xFFFFFF, 0.8))
    ctx.setFillColor(color(0xFFFFFF))
    for index in 0..<3 {
        let d: CGFloat = 31
        ctx.fillEllipse(in: CGRect(x: 475 + CGFloat(index) * 44, y: 672 - CGFloat(index) * 6, width: d, height: d))
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("image") }
    return image
}

func scaled(_ image: CGImage, to pixels: Int) -> CGImage {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("png") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let master = render()
let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(scaled(master, to: points), iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(scaled(master, to: points * 2), iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let preview = URL(fileURLWithPath: previewPath)
try fileManager.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
writePNG(master, preview)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fileManager.removeItem(at: iconset)
print("wrote \(outputDir)/AppIcon.icns and \(preview.path)")
