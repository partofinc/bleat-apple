import Foundation

/// A square grid of QR modules, `true` where the module is dark.
///
/// Separate from whatever produced it so the rendering — the part with all the
/// fiddly detail — is testable without CoreImage, and so a Linux generator can
/// feed the same renderer later.
public struct QRMatrix: Sendable, Equatable {
    public let size: Int
    /// Row-major, `size * size` entries. Row 0 is the top.
    public let modules: [Bool]

    public init?(size: Int, modules: [Bool]) {
        guard size > 0, modules.count == size * size else { return nil }
        self.size = size
        self.modules = modules
    }

    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return modules[y * size + x]
    }

    /// The QR spec asks for a four-module light border, and scanners rely on it
    /// to find the symbol against its surroundings. `CIQRCodeGenerator` emits
    /// only one, so the rest has to be added here.
    public func padded(quietZone: Int) -> QRMatrix {
        guard quietZone > 0 else { return self }
        let newSize = size + quietZone * 2
        var grid = [Bool](repeating: false, count: newSize * newSize)
        for y in 0..<size {
            for x in 0..<size where self[x, y] {
                grid[(y + quietZone) * newSize + (x + quietZone)] = true
            }
        }
        return QRMatrix(size: newSize, modules: grid)!
    }

    /// Whether a 7×7 finder pattern sits with its corner at `(x, y)`.
    ///
    /// The pattern is a solid dark ring, a light ring inside it, then a 3×3
    /// dark core — distinctive enough that finding one is not a coincidence.
    public func hasFinderPattern(atX ox: Int, y oy: Int) -> Bool {
        guard ox >= 0, oy >= 0, ox + 7 <= size, oy + 7 <= size else { return false }
        func dark(_ x: Int, _ y: Int) -> Bool { self[ox + x, oy + y] }
        for i in 0..<7 where !dark(i, 0) || !dark(i, 6) || !dark(0, i) || !dark(6, i) {
            return false
        }
        for i in 1..<6 where dark(i, 1) || dark(i, 5) { return false }
        for y in 2..<5 {
            for x in 2..<5 where !dark(x, y) { return false }
        }
        return true
    }

    /// Whether the finder patterns sit where a QR reader expects them: top-left,
    /// top-right and bottom-left, and **not** bottom-right.
    ///
    /// Worth checking explicitly because the obvious test does not catch a
    /// mirror. `CIDetector` decodes a vertically flipped symbol without
    /// complaint, so "it decoded" says nothing about orientation — while zbar,
    /// ZXing and many Android scanners simply fail. This is the assertion that
    /// distinguishes them.
    ///
    /// - Parameter quietZone: Light border to skip before looking.
    public func hasCanonicalFinderPatterns(quietZone: Int) -> Bool {
        let far = size - quietZone - 7
        return hasFinderPattern(atX: quietZone, y: quietZone)
            && hasFinderPattern(atX: far, y: quietZone)
            && hasFinderPattern(atX: quietZone, y: far)
            && !hasFinderPattern(atX: far, y: far)
    }

    /// How many terminal rows `terminalLines` will produce.
    public var renderedRows: Int { (size + 1) / 2 }

    /// Renders as half-block characters, two module rows per terminal row.
    ///
    /// Terminal cells are about twice as tall as they are wide, so one module
    /// per cell would produce a QR stretched to double height that many
    /// scanners refuse. Packing two rows into each cell makes the modules
    /// roughly square.
    ///
    /// Colours are set explicitly rather than left to the theme. The block
    /// glyphs carry the *foreground* colour as ink, so on a dark theme an
    /// unstyled render comes out inverted — readable by some scanners and not
    /// others. Stating the colours removes the question.
    ///
    /// The light modules are grey, not white. A white panel this size glares in
    /// a dark terminal, and the contrast a decoder needs — roughly 3:1 — leaves
    /// a lot of room: black on `0x8C` measures **6.3:1**, against 21:1 for pure
    /// white. That is still twice what a decoder asks for, but it is now close
    /// enough to the floor that going further should be measured rather than
    /// guessed. Only the light modules move; dimming the dark ones would spend
    /// the same margin while making the ink itself less distinct.
    ///
    /// - Parameter colour: Set false for a plain-text grid, which is what tests
    ///   read and what a terminal without colour support gets.
    public static let lightModule = 0x8C
    public static let darkModule = 0x00

    public func terminalLines(colour: Bool = true) -> [String] {
        let dark = "\u{1B}[38;2;\(Self.darkModule);\(Self.darkModule);\(Self.darkModule)m"
        let light = "\u{1B}[48;2;\(Self.lightModule);\(Self.lightModule);\(Self.lightModule)m"
        let start = colour ? dark + light : ""
        let end = colour ? "\u{1B}[0m" : ""
        var lines: [String] = []
        lines.reserveCapacity(renderedRows)

        for row in stride(from: 0, to: size, by: 2) {
            var line = start
            for x in 0..<size {
                let top = self[x, row]
                // An odd-sized grid has no partner for the final row; the
                // missing half is light, which keeps the quiet zone intact.
                let bottom = row + 1 < size ? self[x, row + 1] : false
                line.append(Self.glyph(top: top, bottom: bottom))
            }
            line += end
            lines.append(line)
        }
        return lines
    }

    /// Ink is dark, so a dark module is a filled half.
    static func glyph(top: Bool, bottom: Bool) -> Character {
        switch (top, bottom) {
        case (true, true):   "\u{2588}"   // █
        case (true, false):  "\u{2580}"   // ▀
        case (false, true):  "\u{2584}"   // ▄
        case (false, false): " "
        }
    }
}
