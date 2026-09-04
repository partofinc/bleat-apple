import Foundation
import Testing
@testable import BleatKit

@Suite("QR matrix")
struct QRMatrixTests {

    /// A 3×3 with a known pattern:
    /// ```
    /// # . #
    /// . # .
    /// # . #
    /// ```
    private func checker() throws -> QRMatrix {
        try #require(QRMatrix(size: 3, modules: [
            true, false, true,
            false, true, false,
            true, false, true,
        ]))
    }

    @Test("a matrix rejects a module count that does not match its size")
    func rejectsBadShape() {
        #expect(QRMatrix(size: 3, modules: [true, false]) == nil)
        #expect(QRMatrix(size: 0, modules: []) == nil)
    }

    @Test("out-of-range lookups read as light rather than trapping")
    func boundsAreLight() throws {
        let m = try checker()
        #expect(m[0, 0])
        #expect(!m[-1, 0])
        #expect(!m[3, 0])
        #expect(!m[0, 99])
    }

    /// Ink is dark, so a dark module is a filled half. Getting this inverted
    /// produces a code that looks like a QR and scans as nothing on the
    /// scanners that do not auto-invert.
    @Test("glyphs map dark modules to filled halves")
    func glyphMapping() {
        #expect(QRMatrix.glyph(top: true, bottom: true) == "█")
        #expect(QRMatrix.glyph(top: true, bottom: false) == "▀")
        #expect(QRMatrix.glyph(top: false, bottom: true) == "▄")
        #expect(QRMatrix.glyph(top: false, bottom: false) == " ")
    }

    /// Terminal cells are about twice as tall as they are wide, so two module
    /// rows share one line and the modules come out roughly square. One module
    /// per cell would double the height and many scanners refuse that.
    @Test("two module rows share one terminal row")
    func packsTwoRowsPerLine() throws {
        let m = try checker()
        #expect(m.renderedRows == 2)                       // 3 rows -> 2 lines
        #expect(m.terminalLines(colour: false).count == 2)
        #expect(try #require(QRMatrix(size: 4, modules: .init(repeating: false, count: 16))).renderedRows == 2)
    }

    /// The final row of an odd-sized grid has no partner. Treating the missing
    /// half as light keeps the quiet zone intact; treating it as dark would put
    /// a stripe of ink along the bottom border.
    @Test("an odd-sized grid pads its last row with light, not dark")
    func oddHeightPadsLight() throws {
        let lines = try checker().terminalLines(colour: false)
        #expect(lines[0] == "▀▄▀")   // rows 0 and 1
        #expect(lines[1] == "▀ ▀")   // row 2, with no row 3 beneath it
    }

    /// The spec asks for a four-module light border and scanners use it to find
    /// the symbol. `CIQRCodeGenerator` emits only one.
    @Test("padding adds a light border on every side and keeps the payload")
    func padding() throws {
        let padded = try checker().padded(quietZone: 2)
        #expect(padded.size == 7)
        // Border light all the way round.
        for i in 0..<7 {
            #expect(!padded[i, 0]); #expect(!padded[i, 6])
            #expect(!padded[0, i]); #expect(!padded[6, i])
        }
        // Original pattern intact, shifted by the quiet zone.
        #expect(padded[2, 2]); #expect(!padded[3, 2]); #expect(padded[3, 3])
    }

    @Test("padding by zero is a no-op")
    func paddingZero() throws {
        #expect(try checker().padded(quietZone: 0) == checker())
    }

    /// Block glyphs carry the *foreground* colour as ink, so on a dark theme an
    /// unstyled render comes out inverted. Stating the colours removes the
    /// question — but the plain form has to stay clean for tests and for
    /// terminals without colour.
    ///
    /// The light modules are grey, not white: a white panel this size glares in
    /// a dark terminal, and black on `0xA0` is still 8:1 where a decoder wants
    /// roughly 3:1.
    @Test("colour is opt-out, and the plain form carries no escapes")
    func colourIsOptOut() throws {
        let plain = try checker().terminalLines(colour: false)
        #expect(plain.allSatisfy { !$0.contains("\u{1B}") })

        let coloured = try checker().terminalLines()
        #expect(coloured.allSatisfy { $0.contains("\u{1B}[38;2;0;0;0m") })
        #expect(coloured.allSatisfy { $0.contains("\u{1B}[48;2;160;160;160m") })
        #expect(coloured.allSatisfy { $0.hasSuffix("\u{1B}[0m") })
    }
}
