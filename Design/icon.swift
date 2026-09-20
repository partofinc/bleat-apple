// Renders the Bleat app icon's layers, and a contact sheet of the real thing.
//
//   swift Design/icon.swift                       # regenerate the layers in place
//   swift Design/icon.swift <layers> <extras>     # or say where they go
//
// What ships is the two layers, into `App/AppIcon.icon/Assets`: the head with
// its eyes punched through, and the caret. `icon.json` composes them over its
// own fill, so the ground colour, the shadows and the specular live there and
// not here, and iOS derives dark, tinted and clear from the result.
//
// The contact sheet is rendered from `App/AppIcon.icon` itself, with Icon
// Composer's `ictool`. An earlier version drew its own flat approximation
// instead — which meant the review that chose this mark at 29pt was done
// against a ground and a surface treatment the icon does not have.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon: \(message)\n".utf8))
    exit(1)
}

// Defaults resolve against this file, never the working directory. A relative
// default plus `withIntermediateDirectories` quietly builds a whole
// `App/AppIcon.icon/Assets` tree wherever the script happens to be run from,
// writes the layers into it, and reports success over the committed files it
// never touched.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().path
let bundlePath = "\(repoRoot)/App/AppIcon.icon"
let defaultOut = "\(bundlePath)/Assets"
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultOut
let extras = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSTemporaryDirectory()

for directory in [out, extras] {
    do {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
    } catch {
        fail("could not create \(directory) — \(error.localizedDescription)")
    }
}

let S = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

let k = 1.06
let headW = 420 * k, headH = 470 * k
let headY = 263.0, headX = 512 - headW / 2
let earL = 208 * k, earH = 118 * k
let eyeW = 92 * k, eyeH = 52 * k, eyeGap = 110 * k
let caretW = 176 * k, caretH = 46 * k

let CORAL: UInt32 = 0xFF6B4A, CREAM: UInt32 = 0xF4EADF

func ctx(_ w: Double = S, _ h: Double = S) -> CGContext {
    guard let c = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a \(Int(w))×\(Int(h)) context") }
    return c
}
func C(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: a)
}
func rr(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Every step is checked. `CGImageDestinationFinalize` is where a full disk or
/// an unwritable file actually surfaces, so dropping its result is how a tool
/// comes to announce where it put files it never wrote.
func save(_ c: CGContext, _ name: String, _ dir: String = out) {
    let path = "\(dir)/\(name).png"
    guard let image = c.makeImage() else { fail("could not render \(name)") }
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not open \(path) for writing") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not finish writing \(path)") }
}

/// Head plus both ears, as one path — filled in one pass, so the nonzero
/// winding unions them and the ears cannot seam against the head.
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

// The eyes are punched right through the wool rather than filled, so the
// document's own ground shows through them in every appearance the system
// derives — including the clear ones, where a filled eye would be a flat blob
// sitting on glass.
let mark = ctx()
mark.addPath(headPath())
mark.setFillColor(C(CREAM))
mark.fillPath()
mark.setBlendMode(.clear)
mark.addPath(eyesPath())
mark.fillPath()
save(mark, "mark")

let caret = ctx()
caret.addPath(caretPath())
caret.setFillColor(C(CORAL))
caret.fillPath()
save(caret, "caret")

print("layers -> \(out)")

// ── The contact sheet, rendered from the document ────────────────────────────

// Only when the layers just written are the ones the document composes;
// otherwise the sheet would show the committed icon beside layers it does not
// contain, which is exactly the stand-in problem this replaced.
guard out == defaultOut else {
    print("contact sheet skipped — layers were written somewhere other than \(defaultOut)")
    exit(0)
}

func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// Icon Composer's own `ictool`, which is **not** the `ictool` on `PATH` — that
// one is actool-family and answers `Unknown argument '--export-image'`.
let developer = run("/usr/bin/xcode-select", ["-p"]).output
    .trimmingCharacters(in: .whitespacesAndNewlines)
let ictool = URL(fileURLWithPath: developer)
    .deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool").path

guard FileManager.default.isExecutableFile(atPath: ictool) else {
    print("contact sheet skipped — no ictool at \(ictool)")
    exit(0)
}

let renditions = ["Default", "Dark", "TintedDark", "ClearDark"]
let sizes = [230.0, 120.0, 60.0, 29.0]
let scale = 2.0

/// Each size is rendered by `ictool` rather than one render being scaled down,
/// because the system masks and treats an icon per size — which is the whole
/// reason for looking at 29pt at all.
var rendered: [String: [Double: CGImage]] = [:]
for rendition in renditions {
    for size in sizes {
        let path = "\(extras)/\(rendition)-\(Int(size)).png"
        let result = run(ictool, [
            bundlePath, "--export-image", "--output-file", path,
            "--platform", "iOS", "--rendition", rendition,
            "--width", "\(Int(size))", "--height", "\(Int(size))", "--scale", "\(Int(scale))",
        ])
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            fail("ictool did not render \(rendition) at \(Int(size))pt — "
                + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        rendered[rendition, default: [:]][size] = image
    }
}

let pad = 34.0, labelW = 250.0, rowH = 268.0
let sheetW = labelW + sizes.reduce(0) { $0 + $1 + 44 } + pad
let sheetH = rowH * Double(renditions.count) + pad
let sheet = ctx(sheetW * scale, sheetH * scale)
sheet.scaleBy(x: scale, y: scale)
let font = CTFontCreateWithName("SFMono-Semibold" as CFString, 21, nil)

for (i, rendition) in renditions.enumerated() {
    let rowY = sheetH - Double(i + 1) * rowH
    // A dark shelf under everything but Default, since three of the four are
    // what a dark home screen shows and the clear ones are transparent.
    let onDark = rendition != "Default"
    sheet.setFillColor(CGColor(gray: onDark ? 0.10 : 0.90, alpha: 1))
    sheet.fill(CGRect(x: 0, y: rowY, width: sheetW, height: rowH))

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key:
            CGColor(gray: onDark ? 0.85 : 0.15, alpha: 1),
    ]
    sheet.textPosition = CGPoint(x: pad, y: rowY + rowH / 2 - 8)
    CTLineDraw(CTLineCreateWithAttributedString(
        NSAttributedString(string: rendition, attributes: attrs)), sheet)

    var x = labelW
    for size in sizes {
        guard let image = rendered[rendition]?[size] else { continue }
        // Drawn as ictool made it: it has already applied the mask, so nothing
        // here clips or rounds anything.
        sheet.draw(image, in: CGRect(x: x, y: rowY + (rowH - size) / 2, width: size, height: size))
        x += size + 44
    }
}
save(sheet, "renditions", extras)
print("contact sheet -> \(extras)/renditions.png")
