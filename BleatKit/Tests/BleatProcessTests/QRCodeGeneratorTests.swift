#if os(macOS)
import BleatKit
import Foundation
import Testing
@testable import BleatProcess

@Suite("QR generation")
struct QRCodeGeneratorTests {

    /// The test that would have caught a shipped bug.
    ///
    /// The generator used to reverse the bitmap's rows, reasoning from
    /// `CGContext`'s bottom-left *coordinate* origin — but the backing buffer
    /// is stored top row first, so the reversal mirrored every symbol
    /// vertically. It passed review because the check used was a `CIDetector`
    /// round-trip, and Apple's decoder reads mirrored codes happily; zbar,
    /// ZXing and many Android scanners do not. Decodability cannot see this;
    /// finder positions can.
    @Test("finder patterns land where a scanner expects them, not mirrored")
    func orientation() throws {
        let matrix = try #require(QRCodeGenerator.matrix(for: "ORIENTATION PROBE 12345", quietZone: 3))
        // CIQRCodeGenerator's own 1 module, plus the 3 added here.
        #expect(matrix.hasCanonicalFinderPatterns(quietZone: 4))
    }

    @Test("orientation holds regardless of quiet zone or correction level")
    func orientationAcrossOptions() throws {
        for quiet in [0, 1, 3] {
            for level in [QRCodeGenerator.Correction.low, .medium, .quartile, .high] {
                let m = try #require(QRCodeGenerator.matrix(
                    for: "bleat://pair?d=AAAABBBBCCCCDDDD", correction: level, quietZone: quiet))
                #expect(m.hasCanonicalFinderPatterns(quietZone: quiet + 1), "quiet=\(quiet) ecc=\(level)")
            }
        }
    }

    /// A real pairing URL, not a short probe: a bigger symbol has more
    /// alignment patterns and more chance for a coordinate mistake to show.
    @Test("a full-size pairing payload is correctly oriented")
    func fullSizeOrientation() throws {
        let payload = PairingPayload(
            name: "kestrel.air", username: "robin",
            endpoints: [Endpoint(host: "studio-mac.local"), Endpoint(host: "192.168.50.54"),
                        Endpoint(host: "2001:db8:5ad0:0:c29:6db5:4a49:dc53", port: 2222)],
            enrollmentSeed: Data(repeating: 0xA7, count: 32),
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct")
        let matrix = try #require(QRCodeGenerator.matrix(for: try payload.urlString()))
        #expect(matrix.hasCanonicalFinderPatterns(quietZone: 4))
    }

    @Test("the quiet zone is added on top of the one CoreImage already emits")
    func quietZone() throws {
        let bare = try #require(QRCodeGenerator.matrix(for: "SIZE", quietZone: 0))
        let padded = try #require(QRCodeGenerator.matrix(for: "SIZE", quietZone: 3))
        #expect(padded.size == bare.size + 6)
    }
}
#endif
