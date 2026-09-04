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

        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let bitmap = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        // CGContext's origin is bottom-left and the matrix's row 0 is the top,
        // so the rows are read back in reverse. A QR is not symmetric — the
        // finder patterns sit in three specific corners — so getting this
        // backwards produces a code that looks plausible and scans as garbage.
        var modules = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            let sourceRow = size - 1 - y
            for x in 0..<size {
                modules[y * size + x] = pixels[sourceRow * size + x] < 128
            }
        }
        return QRMatrix(size: size, modules: modules)?.padded(quietZone: quietZone)
    }
}

#elseif os(Linux)

// Linux port pending, and the approach is deliberately undecided: CoreImage has
// no equivalent, so this is either a vendored encoder or a dependency. The
// renderer in BleatKit is already portable and will not need changing.

#endif
