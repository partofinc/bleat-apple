// Renders the Bleat app icon.
//
//   swift Design/icon.swift                       # regenerate the layers in place
//   swift Design/icon.swift <layers> <extras>     # or say where they go
//
// What ships is the two layers, into `App/AppIcon.icon/Assets`: the head with
// its eyes punched through, and the caret. `icon.json` composes them and iOS
// derives dark, tinted and clear itself.
//
// `extras` gets what is only for looking at — flat renders of the same
// geometry in the three appearances, and a contact sheet at 230/120/83/60/29pt,
// which is the size small marks have to be judged at. Nothing there is built.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText
import AppKit

// The Bleat mark: a terminal block cursor with a sheep's ears, and the cursor
// bar sitting on the line where a terminal's own cursor sits.
//
// Geometry is stated once here and scaled by `k`, so the three appearances and
// the Icon Composer layers cannot drift from each other.

let S = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "App/AppIcon.icon/Assets"
let extras = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSTemporaryDirectory()

let k = 1.06
let headW = 420 * k, headH = 470 * k
let headY = 263.0, headX = 512 - headW / 2
let earL = 208 * k, earH = 118 * k
let eyeW = 92 * k, eyeH = 52 * k, eyeGap = 110 * k
let caretW = 176 * k, caretH = 46 * k

for d in [out, extras] {
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
}

func ctx(_ w: Double = S, _ h: Double = S, opaque: Bool = true) -> CGContext {
    CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
              space: cs,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
}
func C(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: a)
}
func rr(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}
func save(_ c: CGContext, _ n: String, _ dir: String = out) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(n).png") as CFURL,
                                            UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil)
    CGImageDestinationFinalize(d)
}

/// Head plus both ears, as one path — filled in one pass so the ears cannot
/// seam against the head.
func headPath() -> CGPath {
    let p = CGMutablePath()
    p.addPath(rr(headX, headY, headW, headH, headW * 0.238))
    let earY = headY + headH - headH * 0.175
    p.addPath(rr(-earL + 14 * k, -earH / 2, earL, earH, earH / 2),
              transform: CGAffineTransform(translationX: headX + 26 * k, y: earY).rotated(by: 0.26))
    p.addPath(rr(-14 * k, -earH / 2, earL, earH, earH / 2),
              transform: CGAffineTransform(translationX: headX + headW - 26 * k, y: earY)
                  .rotated(by: -0.26))
    return p
}
func eyesPath() -> CGPath {
    let p = CGMutablePath()
    let y = headY + headH * 0.615 - eyeH / 2
    p.addPath(rr(512 - eyeGap - eyeW / 2, y, eyeW, eyeH, eyeH / 2))
    p.addPath(rr(512 + eyeGap - eyeW / 2, y, eyeW, eyeH, eyeH / 2))
    return p
}
func caretPath() -> CGPath {
    rr(512 - caretW / 2, headY + headH * 0.175 - caretH / 2, caretW, caretH, caretH / 2)
}

struct Palette { let top: UInt32, bottom: UInt32, wool: UInt32, caret: UInt32 }
let light = Palette(top: 0x2A2833, bottom: 0x121217, wool: 0xF4EADF, caret: 0xFF6B4A)
let dark = Palette(top: 0x1B1A21, bottom: 0x08080A, wool: 0xE9DED1, caret: 0xF2603F)
let tinted = Palette(top: 0x18181B, bottom: 0x08080A, wool: 0xF2F2F2, caret: 0x9E9E9E)

func gradient(_ c: CGContext, _ p: Palette) {
    let g = CGGradient(colorsSpace: cs, colors: [C(p.top), C(p.bottom)] as CFArray,
                       locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
}

/// The eyes are cut by re-drawing the background through them rather than
/// filled with a flat colour, so they stay exactly the ground behind them
/// however the gradient is tuned.
func icon(_ p: Palette) -> CGContext {
    let c = ctx()
    gradient(c, p)
    c.addPath(headPath())
    c.setFillColor(C(p.wool))
    c.fillPath()
    c.saveGState()
    c.addPath(eyesPath())
    c.clip()
    gradient(c, p)
    c.restoreGState()
    c.addPath(caretPath())
    c.setFillColor(C(p.caret))
    c.fillPath()
    return c
}

// The layers, on transparency. The eyes are punched right through the wool
// rather than filled, so the ground shows through them in every appearance the
// system derives — including the clear ones, where a filled eye would be a
// flat blob.
let m = ctx(opaque: false)
m.addPath(headPath())
m.setFillColor(C(light.wool))
m.fillPath()
m.setBlendMode(.clear)
m.addPath(eyesPath())
m.fillPath()
save(m, "mark")

let cr = ctx(opaque: false)
cr.addPath(caretPath())
cr.setFillColor(C(light.caret))
cr.fillPath()
save(cr, "caret")

// Flat renders of the same geometry, and a contact sheet. For review, and for
// anywhere that wants one image rather than a composition.
save(icon(light), "flat-light", extras)
save(icon(dark), "flat-dark", extras)
save(icon(tinted), "flat-tinted", extras)

let names = ["flat-light", "flat-dark", "flat-tinted"]
let labels = ["light", "dark", "tinted (grayscale)"]
let sizes = [230.0, 120.0, 83.0, 60.0, 29.0]
let pad = 34.0, labelW = 290.0, rowH = 268.0
let W = labelW + sizes.reduce(0) { $0 + $1 + 42 } + pad, H = rowH * Double(names.count) + pad
let s = ctx(W, H)
s.setFillColor(CGColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1))
s.fill(CGRect(x: 0, y: 0, width: W, height: H))
let font = CTFontCreateWithName("SFMono-Semibold" as CFString, 21, nil)
for (i, n) in names.enumerated() {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(extras)/\(n).png") as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let rowY = H - Double(i + 1) * rowH
    if i == 1 {
        s.setFillColor(CGColor(gray: 0.12, alpha: 1))
        s.fill(CGRect(x: 0, y: rowY, width: W, height: rowH))
    }
    let a: [NSAttributedString.Key: Any] = [
        .font: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key:
            CGColor(gray: i == 1 ? 0.85 : 0.15, alpha: 1),
    ]
    s.textPosition = CGPoint(x: pad, y: rowY + rowH / 2 - 8)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: labels[i], attributes: a)), s)
    var x = labelW
    for z in sizes {
        let y = rowY + (rowH - z) / 2
        s.saveGState()
        s.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: z, height: z),
                         cornerWidth: z * 0.2237, cornerHeight: z * 0.2237, transform: nil))
        s.clip()
        s.draw(img, in: CGRect(x: x, y: y, width: z, height: z))
        s.restoreGState()
        x += z + 42
    }
}
save(s, "sheet-final", extras)
print("layers -> \(out)\nflat renders and contact sheet -> \(extras)")
