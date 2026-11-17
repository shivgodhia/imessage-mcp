// Draws the app icon. Run from the repo root:
//   swift app/make_icon.swift app/icon.png && sh app/make_icns.sh
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ top: UInt32, _ bottom: UInt32, from: CGFloat, to: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
}

func sparkle(at c: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<8 {
        let r = i % 2 == 0 ? outer : inner
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

// Tile: the standard macOS rounded square in iMessage blue, soft shadow under it.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(tile)
ctx.setFillColor(color(0x0A84FF))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
gradient(0x5AB8FF, 0x0062E0, from: 924, to: 100)
ctx.restoreGState()

// White speech bubble: an oval with a tail at the lower left.
let bubble = CGMutablePath()
bubble.addEllipse(in: CGRect(x: 212, y: 318, width: 600, height: 478))
let tail = CGMutablePath()
tail.move(to: CGPoint(x: 300, y: 430))
tail.addQuadCurve(to: CGPoint(x: 232, y: 262), control: CGPoint(x: 306, y: 318))
tail.addQuadCurve(to: CGPoint(x: 450, y: 330), control: CGPoint(x: 352, y: 270))
tail.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x00306E, 0.30))
ctx.addPath(bubble)
ctx.addPath(tail)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bubble)
ctx.addPath(tail)
ctx.clip()
gradient(0xFFFFFF, 0xE8F0FA, from: 796, to: 262)
ctx.restoreGState()

// The modification: sparkles pressed into the bubble, for the assistant. Mid grey, with a
// light rim below (the bubble catching light) and an inner shadow along the top edge.
for (c, o, i) in [(CGPoint(x: 486, y: 552), CGFloat(112), CGFloat(33)),
                  (CGPoint(x: 654, y: 664), CGFloat(62), CGFloat(19)),
                  (CGPoint(x: 660, y: 452), CGFloat(40), CGFloat(12))] {
    let s = sparkle(at: c, outer: o, inner: i)
    // Soften the points, and merge into one outline so the even-odd fill below works.
    let rounded = s.union(s.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round,
                                 miterLimit: 10))
    func shape() { ctx.addPath(rounded) }

    // Highlight rim: a white copy nudged down, peeking out under the recess.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: -4)
    shape()
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Recess fill: dark grey, slightly darker at the top where the light doesn't reach.
    ctx.saveGState()
    shape()
    ctx.clip()
    gradient(0x8A8E95, 0xA9ADB3, from: c.y + o, to: c.y - o)

    // Inner shadow: fill everything outside the sparkle with a shadow cast downward,
    // clipped to the sparkle, so a dark band hugs its upper edges.
    let outside = CGMutablePath()
    outside.addRect(CGRect(x: c.x - o * 3, y: c.y - o * 3, width: o * 6, height: o * 6))
    outside.addPath(rounded)
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 8, color: color(0x000000, 0.45))
    ctx.addPath(outside)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
