#if os(macOS)
import BleatKit
import Foundation
import Testing
@testable import BleatProcess

/// How tall the pairing QR gets as endpoints accumulate.
///
/// **Height is the binding constraint on this code**, not width: it is drawn
/// two module rows per terminal line, and when the window is too short
/// `bleat pair` gives up on the QR and prints a link instead. Every endpoint is
/// bytes in the payload and bytes are modules, so anything that adds one is
/// spending the user's terminal rows.
///
/// Measured 7 Sept 2026, at correction level L with a 4-module quiet zone:
///
/// | endpoints | URL chars | modules | rows |
/// |---|---|---|---|
/// | 4 (LAN + Tailscale addresses) | 227 | 63 | 32 |
/// | 5 (+ the MagicDNS name) | 262 | 67 | 34 |
/// | 7 (everything this Mac offers) | 363 | 75 | 38 |
///
/// So the MagicDNS name costs two terminal rows, and a Tailscale-connected Mac
/// costs six over a LAN-only one. Three rows of chrome sit above and below, so
/// the worst case here needs 41 rows — inside the 47 a full-screen window has,
/// and inside the 41 that CLAUDE.md measured as the reduced-margin threshold,
/// with nothing to spare. That is the number this test exists to defend.
@Suite("Pairing QR size")
struct QRPayloadSizeTests {

    private func matrix(endpoints: [String]) throws -> QRMatrix {
        let payload = PairingPayload(
            name: "rawillk.air",
            username: "ravil",
            endpoints: endpoints.map { Endpoint(string: $0)! },
            enrollmentSeed: Data(repeating: 7, count: 32),
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB8x2Vw0jKQe5vJ0aXqE1YQ7pQ0mZ8Nn4T6cLd9RfKpP"
        )
        return try #require(QRCodeGenerator.matrix(for: try payload.urlString(), quietZone: 4))
    }

    /// Every endpoint a Tailscale-connected Mac offers: mDNS name, a global v6,
    /// an RFC1918 v4, a ULA, both Tailscale addresses and the MagicDNS name.
    /// Taken from a live `bleat inspect` rather than imagined, because the v6
    /// literals are 39 characters each and dominate the payload.
    @Test("the worst realistic payload still fits a full-screen terminal")
    func worstCaseFits() throws {
        let matrix = try matrix(endpoints: [
            "rawillkair.local",
            "[2a00:f3c:5ad0:0:c29:6db5:4a49:dc53]",
            "192.168.11.54",
            "[fd74:e60:b537:4fb6:4bd:a9e4:d43:fc95]",
            "100.114.119.30",
            "[fd7a:115c:a1e0::42a:771f]",
            "rawillk.tail2a3bab.ts.net",
        ])
        let rows = (matrix.size + 1) / 2
        // 3 rows of chrome — title, host key, footer — and no blank spacers.
        #expect(rows + 3 <= 41, "\(matrix.size) modules is \(rows) rows, past the reduced-margin threshold")
        #expect(matrix.size <= 100, "too wide for an ordinary terminal")
    }

    /// The name is worth its rows — it is the only endpoint that survives the
    /// machine being removed from the tailnet and re-added — but it should stay
    /// cheap. A jump here means the payload encoding has regressed, most likely
    /// out of byte mode.
    @Test("the MagicDNS name costs a couple of rows, not a screenful")
    func theNameIsCheap() throws {
        let lan = ["rawillkair.local", "192.168.11.54", "[fd7a:115c:a1e0::42a:771f]", "100.114.119.30"]
        let withName = try matrix(endpoints: lan + ["rawillk.tail2a3bab.ts.net"]).size
        let without = try matrix(endpoints: lan).size
        #expect(withName > without)
        #expect((withName - without) / 2 <= 4, "the name grew the code by \((withName - without) / 2) rows")
    }
}
#endif
