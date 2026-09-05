#if DEBUG
import BleatKit
import Foundation

/// A peer for previews, shaped like one a real pairing produces: several
/// endpoints of different reach, one of them the last that worked.
///
/// `#if DEBUG` so it cannot be reached from a release build, and in `BleatUI`
/// rather than `BleatKit` so the domain layer ships no sample data.
extension PairedPeer {
    static var preview: PairedPeer {
        var peer = PairedPeer(
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5cjZ26Q+4UUiEfZnfwG+hUvC3MasbyQN8yihaMCcTY",
            name: "rawillk.air",
            username: "ravil",
            endpoints: [
                Endpoint(host: "rawillkair.local"),
                Endpoint(host: "192.168.11.54"),
                Endpoint(host: "rawillk-air.tail1234.ts.net"),
            ],
            herdrPath: "/opt/homebrew/bin/herdr"
        )
        peer.lastGoodEndpoint = Endpoint(host: "192.168.11.54")
        return peer
    }
}
#endif
