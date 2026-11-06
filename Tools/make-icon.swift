// Draws the AI Session Radar app icon as a 1024 px PNG; build.sh turns it into AppIcon.icns.
//   swift Tools/make-icon.swift <out.png> [variant]
// A radar screen on the macOS icon grid. The app uses `spectrum`; the other variants
// were the alternatives and stay for comparison:
//   spectrum dark screen, the sweep runs through the board's column colours
//   clean    dark screen, rings and a blue sweep, nothing else
//   echo     dark screen, blue sweep, an orange echo arc where the sweep meets the rim
//   daylight light screen, navy rings, blue sweep
//   quadrant bold quarter-radar from the corner: three thick arcs and an orange sweep
import AppKit

let size: CGFloat = 1024
let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon_1024.png"
let variant = args.count > 2 ? args[2] : "spectrum"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func comps(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF))
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

let light = variant == "daylight"
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath

/// A sweep as a true angular gradient, computed per pixel, clipped to its sector.
/// `colour(t)` gives the colour and alpha at t = 0 (leading edge) … 1 (tail).
func sweep(centre c: CGPoint, radius: CGFloat, lead: CGFloat, trail: CGFloat,
           colour: (CGFloat) -> (UInt32, CGFloat)) {
    let n = Int(size)
    var pixels = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n {
        for x in 0..<n {
            let dx = CGFloat(x) + 0.5 - c.x, dy = CGFloat(n - 1 - y) + 0.5 - c.y
            guard dx * dx + dy * dy <= (radius + 2) * (radius + 2) else { continue }
            var angle = atan2(dy, dx) * 180 / .pi - lead
            if angle < 0 { angle += 360 }
            guard angle <= trail else { continue }
            let (hex, alpha) = colour(angle / trail)
            let (r, g, b) = comps(hex)
            let i = (y * n + x) * 4
            pixels[i] = UInt8(r * alpha); pixels[i + 1] = UInt8(g * alpha)
            pixels[i + 2] = UInt8(b * alpha); pixels[i + 3] = UInt8(255 * alpha)
        }
    }
    let image = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    ctx.saveGState()
    ctx.move(to: c)
    ctx.addArc(center: c, radius: radius, startAngle: lead * .pi / 180, endAngle: (lead + trail) * .pi / 180, clockwise: false)
    ctx.closePath()
    ctx.clip()
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
    let (ar, ag, ab) = comps(a), (br, bg, bb) = comps(b)
    let r = UInt32(ar + (br - ar) * t), g = UInt32(ag + (bg - ag) * t), bl = UInt32(ab + (bb - ab) * t)
    return (r << 16) | (g << 8) | bl
}

func edgeLine(_ c: CGPoint, _ radius: CGFloat, _ angle: CGFloat, _ colour: CGColor, _ width: CGFloat) {
    let a = angle * .pi / 180
    ctx.setStrokeColor(colour)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)))
    ctx.strokePath()
}

// Body with drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, light ? 0.22 : 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(light ? 0xF2F4F8 : 0x141A2B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = light
    ? CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xDCE2EC)] as CFArray, locations: [0, 1])!
    : CGGradient(colorsSpace: space, colors: [rgb(0x26304A), rgb(0x0C101C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

if variant == "quadrant" {
    // Bold quarter-radar anchored near the bottom-left corner of the body.
    let o = CGPoint(x: 250, y: 250)
    sweep(centre: o, radius: 600, lead: 62, trail: 62) { t in (mix(0xFF8A3D, 0xFFB36B, t), 0.62 * pow(1 - t, 1.6)) }
    ctx.setLineCap(.round)
    for (r, a) in [(190.0, 0.95), (370.0, 0.70), (550.0, 0.45)] as [(CGFloat, CGFloat)] {
        ctx.setStrokeColor(rgb(0xFFFFFF, a))
        ctx.setLineWidth(46)
        ctx.addArc(center: o, radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        ctx.strokePath()
    }
    edgeLine(o, 600, 62, rgb(0xFFD2A8, 0.95), 14)
} else {
    let c = CGPoint(x: 512, y: 512), radius: CGFloat = 354, lead: CGFloat = 52
    let ink: UInt32 = light ? 0x1C2740 : 0xFFFFFF

    if !light {  // soft glow in the middle of the screen
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0x5AA9EF, 0.16), rgb(0x5AA9EF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 400, options: [])
    }
    ctx.setStrokeColor(rgb(ink, light ? 0.22 : 0.13))
    ctx.setLineWidth(light ? 9 : 7)
    for r in [118.0, 236.0, 354.0] as [CGFloat] {
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    ctx.setStrokeColor(rgb(ink, light ? 0.10 : 0.07))
    ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: c.x - 354, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 354, y: c.y))
    ctx.move(to: CGPoint(x: c.x, y: c.y - 354)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 354))
    ctx.strokePath()

    switch variant {
    case "spectrum":
        // Orange at the leading edge, through purple to blue in the tail: the board's columns.
        sweep(centre: c, radius: radius, lead: lead, trail: 150) { t in
            let hex = t < 0.45 ? mix(0xFF8A3D, 0xA98BFF, t / 0.45) : mix(0xA98BFF, 0x5AA9EF, (t - 0.45) / 0.55)
            return (hex, 0.78 * pow(1 - t, 1.5))
        }
        edgeLine(c, radius, lead, rgb(0xFFC9A0, 0.95), 10)
    case "daylight":
        sweep(centre: c, radius: radius, lead: lead, trail: 125) { t in (0x1F78C8, 0.50 * pow(1 - t, 2.0)) }
        edgeLine(c, radius, lead, rgb(0x12305A, 0.95), 10)
    case "echo":
        sweep(centre: c, radius: radius, lead: lead, trail: 125) { t in (0x7CC4FF, 0.55 * pow(1 - t, 2.2)) }
        // Echo arcs: where the sweep has just passed, the rim lights up orange.
        for (r, a0, a1, alpha, w) in [(354.0, 52.0, 96.0, 1.0, 20.0), (236.0, 52.0, 80.0, 0.55, 14.0)]
            as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFF8A3D, 0.9 * alpha))
            ctx.setStrokeColor(rgb(0xFF8A3D, alpha))
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.addArc(center: c, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
            ctx.strokePath()
            ctx.restoreGState()
        }
        edgeLine(c, radius, lead, rgb(0xBFE3FF, 0.95), 9)
    default:  // clean
        sweep(centre: c, radius: radius, lead: lead, trail: 125) { t in (0x7CC4FF, 0.60 * pow(1 - t, 2.0)) }
        edgeLine(c, radius, lead, rgb(0xBFE3FF, 0.95), 10)
    }
    ctx.setFillColor(rgb(light ? 0x12305A : 0xE8F4FF))
    ctx.fillEllipse(in: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30))
}

// Top highlight and a fine inner edge, so the body reads as glass.
let shine = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, light ? 0.5 : 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()
ctx.addPath(shape)
ctx.setStrokeColor(light ? rgb(0x000000, 0.08) : rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
