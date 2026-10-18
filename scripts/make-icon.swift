// Draws the dmucode app icon: a "D" and a "C" as thick strokes that
// partly overlap, the overlap blended into a third color, on a macOS-style
// rounded square.
//
//   swift scripts/make-icon.swift preview <out.png>          all palettes side by side
//   swift scripts/make-icon.swift png <palette> <out.png> [size]
//   swift scripts/make-icon.swift icns <palette> <out.icns>
import AppKit

struct Palette {
    let name: String
    let label: String
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let d: NSColor
    let c: NSColor
    /// How the C is drawn over the D; decides the overlap color.
    let blend: CGBlendMode
}

func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha)
}

let palettes = [
    Palette(name: "mocha", label: "Mocha",
            backgroundTop: hex(0x313244), backgroundBottom: hex(0x11111B),
            d: hex(0xCBA6F7), c: hex(0x89DCEB), blend: .screen),
    Palette(name: "sunrise", label: "Sunrise",
            backgroundTop: hex(0xFFF7ED), backgroundBottom: hex(0xFED7AA),
            d: hex(0xF97316), c: hex(0x8B5CF6), blend: .multiply),
    Palette(name: "lagoon", label: "Lagoon",
            backgroundTop: hex(0x0F766E), backgroundBottom: hex(0x042F2E),
            d: hex(0x5EEAD4), c: hex(0xFDE68A), blend: .screen),
    Palette(name: "terminal", label: "Terminal",
            backgroundTop: hex(0x2A2A2A), backgroundBottom: hex(0x0A0A0A),
            d: hex(0xF5F5F5), c: hex(0x22C55E, alpha: 0.85), blend: .normal),
]

/// Draws the icon into `ctx` in a 1024×1024 coordinate space (y up).
func drawIcon(_ palette: Palette, in ctx: CGContext) {
    // Apple's macOS icon grid: an 824pt rounded square centered on 1024.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(palette.backgroundBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient, top to bottom.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [palette.backgroundTop.cgColor, palette.backgroundBottom.cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.restoreGState()

    // Letter geometry: both letters 420 tall, stroked 88 wide.
    let height: CGFloat = 420
    let radius = height / 2
    let stroke: CGFloat = 88
    let centerY: CGFloat = 512
    let stemX: CGFloat = 293
    let bowlX: CGFloat = 403
    let cCenter = CGPoint(x: 591, y: centerY)
    let opening: CGFloat = 48 * .pi / 180

    let d = CGMutablePath()
    d.move(to: CGPoint(x: stemX, y: centerY - radius))
    d.addLine(to: CGPoint(x: stemX, y: centerY + radius))
    d.addLine(to: CGPoint(x: bowlX, y: centerY + radius))
    d.addArc(center: CGPoint(x: bowlX, y: centerY), radius: radius,
             startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    d.closeSubpath()

    let c = CGMutablePath()
    c.addArc(center: cCenter, radius: radius, startAngle: opening, endAngle: 2 * .pi - opening, clockwise: false)

    // Draw the letters in their own layer so the blend mode only mixes the
    // C with the D, not with the background.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setLineWidth(stroke)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    ctx.addPath(d)
    ctx.setStrokeColor(palette.d.cgColor)
    ctx.strokePath()

    ctx.setBlendMode(palette.blend)
    ctx.addPath(c)
    ctx.setStrokeColor(palette.c.cgColor)
    ctx.strokePath()

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Hairline highlight along the tile edge.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ ctx: CGContext, to path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func renderIcon(_ palette: Palette, size: Int) -> CGContext {
    let ctx = makeContext(width: size, height: size)
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(palette, in: ctx)
    return ctx
}

func palette(named name: String) -> Palette {
    guard let palette = palettes.first(where: { $0.name == name }) else {
        fatalError("unknown palette \(name); choose from \(palettes.map(\.name))")
    }
    return palette
}

/// A comparison sheet: each palette large, plus Dock (64) and Finder (32) sizes.
func renderPreview(to path: String) {
    let cell = 520, big = 440
    let width = cell * palettes.count, height = 720
    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(hex(0xECECEC).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, palette) in palettes.enumerated() {
        let x = i * cell + (cell - big) / 2
        ctx.draw(renderIcon(palette, size: big).makeImage()!, in: CGRect(x: x, y: 230, width: big, height: big))
        ctx.draw(renderIcon(palette, size: 128).makeImage()!, in: CGRect(x: x + 90, y: 110, width: 64, height: 64))
        ctx.draw(renderIcon(palette, size: 64).makeImage()!, in: CGRect(x: x + 190, y: 126, width: 32, height: 32))
        ctx.draw(renderIcon(palette, size: 32).makeImage()!, in: CGRect(x: x + 258, y: 134, width: 16, height: 16))
        let title = "\(i + 1)  \(palette.label)" as NSString
        title.draw(at: CGPoint(x: x + 90, y: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ])
    }
    NSGraphicsContext.current = nil
    writePNG(ctx, to: path)
}

func renderICNS(_ palette: Palette, to path: String) {
    let iconset = FileManager.default.temporaryDirectory
        .appendingPathComponent("dmucode-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    for points in [16, 32, 128, 256, 512] {
        writePNG(renderIcon(palette, size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png").path)
        writePNG(renderIcon(palette, size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png").path)
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    precondition(iconutil.terminationStatus == 0, "iconutil failed")
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "preview" where args.count == 2:
    renderPreview(to: args[args.startIndex + 1])
case "png" where args.count >= 3:
    let size = args.count > 3 ? Int(args[args.startIndex + 3])! : 1024
    writePNG(renderIcon(palette(named: args[args.startIndex + 1]), size: size), to: args[args.startIndex + 2])
case "icns" where args.count == 3:
    renderICNS(palette(named: args[args.startIndex + 1]), to: args[args.startIndex + 2])
default:
    print("usage: make-icon.swift preview <out.png> | png <palette> <out.png> [size] | icns <palette> <out.icns>")
    exit(1)
}
