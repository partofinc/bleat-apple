#if os(macOS)
import BleatKit
import CoreImage
import Foundation
import Testing
@testable import BleatProcess

/// `QREncoder` is what Linux draws with. macOS is the only place an oracle
/// exists, so it is held against CoreImage here — **module for module** where
/// the two can agree, which pins the capacity and block tables, the
/// Reed–Solomon arithmetic, the zigzag, and the format and version bits.
///
/// Two things legitimately differ, both measured 19 Sept 2026:
///
/// - **The mask choice**, about a third of the time. The spec allows any of the
///   eight and its penalty rules only rank them; encoders are known to differ
///   on the finder-like rule, and this one follows Nayuki's literal reading. So
///   the comparison forces CoreImage's mask, read out of its format bits, and
///   this encoder's own choice is checked by decoding it.
/// - **Segmentation.** CoreImage splits text into mixed-mode segments — on a
///   real pairing URL its first byte segment declares 80 of 201 bytes, then
///   switches mode inside the base64. This encoder is byte mode throughout.
///   Both are valid, so the exact comparison uses text with no cheaper mode,
///   and real payloads are checked for the thing segmentation could cost: a
///   larger version, which is terminal rows.
@Suite("QR encoder")
struct QREncoderTests {

    private func pair(_ level: QREncoder.Correction) -> QRCodeGenerator.Correction {
        switch level {
        case .low: .low
        case .medium: .medium
        case .quartile: .quartile
        case .high: .high
        }
    }

    /// The mask a symbol was drawn with, read back out of its format bits —
    /// the first copy, beside the top-left finder. `offset` skips a border.
    private func mask(of matrix: QRMatrix, offset: Int = 1) -> Int {
        var positions = (0...5).map { (8, $0) } + [(8, 7), (8, 8), (7, 8)]
        positions += (9..<15).map { (14 - $0, 8) }
        var bits = 0
        for (i, (x, y)) in positions.enumerated() where matrix[x + offset, y + offset] {
            bits |= 1 << i
        }
        return (bits ^ 0x5412) >> 10 & 7
    }

    /// Lowercase letters and punctuation outside the alphanumeric set: byte
    /// mode is the only mode either encoder can use for it.
    private func byteOnlyText(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz!?_~&=@;'")
        return String((0..<count).map { alphabet[$0 * 7 % alphabet.count] })
    }

    private func pairingURL(_ endpoints: [String]) throws -> String {
        try PairingPayload(
            name: "adam", username: "pi",
            endpoints: endpoints.map { try #require(Endpoint(string: $0)) },
            enrollmentSeed: Data(repeating: 0xA7, count: 32),
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct"
        ).urlString()
    }

    /// What the Raspberry Pi this was verified on offers.
    private var piURL: String {
        get throws { try pairingURL(["adam.local", "192.168.11.67", "[2a00:f3c:5ad0:0:2ecf:67ff:fec0:fa8c]"]) }
    }

    /// Each version filled to its exact capacity, so all forty are reached by
    /// construction — including 7 (the first with version bits), 10 (the count
    /// field widens to 16 bits) and 32 (the irregular alignment step) — and a
    /// capacity table off by one byte would pick a different version.
    @Test("every version and correction level matches CoreImage, given its mask",
          arguments: QREncoder.Correction.allCases)
    func everyVersionMatches(level: QREncoder.Correction) throws {
        for version in 1...40 {
            let capacity = try #require((1...2953).last { QREncoder.fits($0, version: version, level) })
            let text = byteOnlyText(capacity)
            let core = try #require(QRCodeGenerator.matrix(for: text, correction: pair(level), quietZone: 0))
            let ours = try #require(QREncoder.encode(text, level, mask: mask(of: core))).padded(quietZone: 1)
            #expect(ours.size == version * 4 + 17 + 2, "version \(version) at \(level)")
            #expect(ours == core, "version \(version) at \(level)")
        }
    }

    /// Byte mode throughout must not cost a version on what `bleat pair`
    /// really encodes: the Pi's payload, and the worst case
    /// `QRPayloadSizeTests` defends — every endpoint a Tailscale Mac offers.
    @Test("real pairing payloads come out the same size as CoreImage's")
    func pairingPayloadsSameSize() throws {
        let worst = try pairingURL([
            "rawillkair.local", "[2a00:f3c:5ad0:0:c29:6db5:4a49:dc53]", "192.168.11.54",
            "[fd74:e60:b537:4fb6:4bd:a9e4:d43:fc95]", "100.114.119.30",
            "[fd7a:115c:a1e0::42a:771f]", "rawillk.tail2a3bab.ts.net",
        ])
        for url in [try piURL, worst] {
            let core = try #require(QRCodeGenerator.matrix(for: url, quietZone: 3))
            let ours = try #require(QREncoder.matrix(for: url)).padded(quietZone: 4)
            #expect(ours.size == core.size, "\(url.count) bytes")
        }
    }

    /// Orientation is what a decode cannot see (`QRCodeGeneratorTests` has
    /// the history), so it is asserted on its own.
    @Test("finder patterns sit top-left, top-right and bottom-left")
    func orientation() throws {
        let matrix = try #require(QREncoder.matrix(for: try piURL)).padded(quietZone: 4)
        #expect(matrix.hasCanonicalFinderPatterns(quietZone: 4))
    }

    /// The mask *this* encoder chooses, which CoreImage cannot vouch for, read
    /// back by Apple's decoder — the Pi's pairing URL, and level L at every
    /// version a pairing code can realistically reach.
    @Test("CIDetector reads back the exact text")
    func decodes() throws {
        #expect(try decoded(try piURL) == [try piURL])
        for version in 1...12 {
            let capacity = try #require((1...2953).last { QREncoder.fits($0, version: version, .low) })
            let text = byteOnlyText(capacity)
            #expect(try decoded(text) == [text], "version \(version)")
        }
    }

    private func decoded(_ text: String) throws -> [String] {
        let matrix = try #require(QREncoder.matrix(for: text)).padded(quietZone: 4)
        let scale = 8
        let side = matrix.size * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<side {
            for x in 0..<side where matrix[x / scale, y / scale] {
                pixels[y * side + x] = 0
            }
        }
        let image = CIImage(
            bitmapData: Data(pixels), bytesPerRow: side,
            size: CGSize(width: side, height: side), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
        )
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil))
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    @Test("text beyond version 40 is refused, not truncated")
    func tooLong() {
        #expect(QREncoder.matrix(for: String(repeating: "x", count: 2954)) == nil)
        #expect(QREncoder.matrix(for: String(repeating: "x", count: 2953)) != nil)
    }
}
#endif
