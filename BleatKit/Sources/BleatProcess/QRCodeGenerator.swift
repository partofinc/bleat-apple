#if os(macOS)
import BleatKit
import CoreImage
import Foundation

/// Turns text into a `QRMatrix` with CoreImage.
///
/// macOS only: `CIQRCodeGenerator` has no Linux equivalent, and choosing what
/// to do there is deliberately still open (see CLAUDE.md). Everything past the
/// matrix — padding, half-block rendering — lives in `BleatKit` and is shared.
public enum QRCodeGenerator {

    /// Error correction level.
    ///
    /// `.low` is the default, and for this medium it is the right one. The
    /// higher levels buy recovery from damage — print wear, dirt, a crease, a
    /// bad camera angle on a curled sticker. None of that exists here: the code
    /// is drawn pixel-exact on a screen, scanned from a foot away, and gone
    /// within minutes. The recovery is paid for in modules, and modules are
    /// rows of terminal the user may not have.
    public enum Correction: String, Sendable {
        case low = "L", medium = "M", quartile = "Q", high = "H"
    }

    /// - Parameter quietZone: Extra light border in modules. `CIQRCodeGenerator`
    ///   emits one and the spec asks for four, so the default adds three.
    public static func matrix(
        for text: String,
        correction: Correction = .low,
        quietZone: Int = 3
    ) -> QRMatrix? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(correction.rawValue, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }

        let size = Int(image.extent.width)
        guard size > 0, Int(image.extent.height) == size else { return nil }

        // One byte per module: render at native scale, where one pixel is one
        // module, so nothing has to be sampled or rounded.
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }

        // The buffer must stay alive for the draw as well as the context's
        // construction: an inout-to-pointer conversion is only guaranteed for
        // the duration of the call it appears in, so writing through it
        // afterwards is undefined even though it happens to work.
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drew else { return nil }

        // Read straight through: a CGBitmapContext's *coordinate* origin is
        // bottom-left, but its backing buffer is stored top row first, so
        // `pixels[0..<size]` is already the top scanline.
        //
        // This file previously reversed the rows on the strength of that
        // coordinate origin, which mirrored the symbol vertically — finder
        // patterns landed top-left, bottom-left and bottom-right instead of
        // top-left, top-right and bottom-left. It survived review because the
        // check used was `CIDetector`, and Apple's decoder reads mirrored
        // symbols happily; zbar, ZXing and many Android scanners do not. Assert
        // finder positions, not decodability, when changing this.
        var modules = [Bool](repeating: false, count: size * size)
        for index in 0..<(size * size) {
            modules[index] = pixels[index] < 128
        }
        return QRMatrix(size: size, modules: modules)?.padded(quietZone: quietZone)
    }
}

#elseif os(Linux)
import BleatKit

/// No generator on Linux yet, and saying so is the whole implementation.
///
/// CoreImage has no equivalent there, and the choice between a vendored encoder
/// and a dependency is still deliberately open (see CLAUDE.md). Returning nil
/// is not a stub that pretends: `bleat pair` already has a branch for "no
/// generator" — it prints the `bleat://pair?d=…` link, with the scrollback
/// warning, and the phone's paste field redeems it exactly as it would a scan.
/// The renderer in BleatKit is portable and will not need changing.
public enum QRCodeGenerator {
    public static func matrix(for text: String, quietZone: Int = 3) -> QRMatrix? { nil }
}

#endif
