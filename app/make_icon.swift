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

// A four-point star with concave, curved sides, like the ✨ emoji. `inner` sets how far the
// curves bow in toward the centre: smaller is a thinner, spikier star.
func sparkle(at c: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let tips = (0..<4).map { i -> CGPoint in
        let a = CGFloat(i) * .pi / 2 + .pi / 2
        return CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a))
    }
    p.move(to: tips[0])
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2 + .pi / 2 + .pi / 4
        let ctrl = CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a))
        p.addQuadCurve(to: tips[(i + 1) % 4], control: ctrl)
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

// A white message bubble at the lower left, white ✨ sparkles at the upper right.
func whiteShape(_ add: () -> Void, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x00306E, 0.30))
    add()
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    add()
    ctx.clip()
    gradient(0xFFFFFF, 0xE8F0FA, from: top, to: bottom)
    ctx.restoreGState()
}

// The original bubble (oval + lower-left tail), scaled down and moved left.
let bubble = CGMutablePath()
bubble.addEllipse(in: CGRect(x: 212, y: 318, width: 600, height: 478))
bubble.move(to: CGPoint(x: 300, y: 430))
bubble.addQuadCurve(to: CGPoint(x: 232, y: 262), control: CGPoint(x: 306, y: 318))
bubble.addQuadCurve(to: CGPoint(x: 450, y: 330), control: CGPoint(x: 352, y: 270))
bubble.closeSubpath()
let bs: CGFloat = 0.888
var bt = CGAffineTransform(translationX: 440, y: 440).scaledBy(x: bs, y: bs)
    .translatedBy(x: -512, y: -557)
let small = bubble.copy(using: &bt)!
whiteShape({ ctx.addPath(small) }, top: small.boundingBox.maxY, bottom: small.boundingBox.minY)

// Laid out like ✨: big star, a medium one up and to its left, a small one down and to its left.
for (c, o, i) in [(CGPoint(x: 786, y: 724), CGFloat(86), CGFloat(14)),
                  (CGPoint(x: 664, y: 836), CGFloat(42), CGFloat(7)),
                  (CGPoint(x: 676, y: 652), CGFloat(26), CGFloat(5))] {
    let s = sparkle(at: c, outer: o, inner: i)
    let rounded = s.union(s.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round,
                                 miterLimit: 10))
    whiteShape({ ctx.addPath(rounded) }, top: c.y + o, bottom: c.y - o)
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
