#if DEBUG
import BleatKit
import Foundation

/// The hosts previews are drawn against.
///
/// `#if DEBUG` so none of this can be reached from a release build, and in
/// `BleatUI` rather than `BleatKit` so the domain layer ships no sample data.
///
/// They are shaped like records a real pairing produces rather than like the
/// happy case: one Mac with every kind of address on it, one that is only
/// reachable over a tunnel, and one paired before `herdrPath` and the device
/// marker were stored. The second and third are where the screens have
/// something to say — an endpoint list that is all `overlay`, a "herdr" row
/// with nothing to put in it — and a preview that only ever showed the first
/// would not be exercising them.
extension PairedPeer {
    /// The everyday one: on the LAN, on a tailnet, and answering to its own
    /// name. Its last-good address is the LAN one, which is what a phone on
    /// Wi-Fi records.
    static var preview: PairedPeer {
        var peer = PairedPeer(
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5cjZ26Q+4UUiEfZnfwG+hUvC3MasbyQN8yihaMCcTY",
            name: "rawillk.air",
            username: "ravil",
            endpoints: [
                Endpoint(host: "rawillkair.local"),
                Endpoint(host: "192.168.11.54"),
                Endpoint(host: "rawillk.tail2a3bab.ts.net"),
            ],
            herdrPath: "/opt/homebrew/bin/herdr",
            deviceMarker: "bleat-device-9f2c1a4e"
        )
        peer.lastGoodEndpoint = Endpoint(host: "192.168.11.54")
        peer.hostInfo = .sampleMac
        return peer
    }

    /// Reachable only over the tunnel, and on a non-default port. Every row in
    /// its endpoint list reads "VPN", which is the case the connection failure
    /// messages are written for.
    static var previewOverlayOnly: PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBv4kDh8Wq2LZ0nT1sRr9xYcPmKjEuA6oVdHgNfSbQwX",
            name: "studio",
            username: "ravil",
            endpoints: [
                Endpoint(host: "studio.tail2a3bab.ts.net", port: 2222),
                Endpoint(host: "100.114.119.30", port: 2222),
            ],
            herdrPath: "/usr/local/bin/herdr",
            deviceMarker: "bleat-device-3d70b8c5",
            hostInfo: .sampleLinux
        )
    }

    /// Paired before `herdrPath` and the marker were recorded, and known only
    /// by an mDNS name — so the detail screen has to say "not resolved", and
    /// the unpair screen has no marker to name in its command. Never connected
    /// to either, so it has not said what it is: its row falls back to where
    /// it is.
    static var previewSparse: PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqW3mR8tYvL5aBnKzXcJ2dPfEoUi7SgMhVrQwZyNbTA",
            name: "mini",
            username: "ravil",
            endpoints: [Endpoint(host: "mini.local")]
        )
    }

    /// The everyday peer, but with two of its sessions started from this
    /// phone — so the session rows can show what a swipe offers and, more to
    /// the point, what it does *not*.
    ///
    /// `work` and `phone` both run and so both offer Stop; `bleat-test` is
    /// stopped and so offers Start then Delete. The row worth looking at is
    /// `phone`, started at the Mac: it has the same swipe as `work` and a
    /// different confirmation behind it, which is where the claim went when it
    /// stopped being a gate.
    static var previewOwningSessions: PairedPeer {
        var peer = preview
        peer.createdSessions = ["work", "bleat-test"]
        // `work` is running because this phone started it, so its confirmation
        // is the shorter one; `bleat-test` is down, so the claim has expired.
        peer.startedSessions = ["work"]
        return peer
    }

    /// What the peer list is drawn from.
    static var samples: [PairedPeer] { [preview, previewOverlayOnly, previewSparse] }
}

extension PeerRegistry {
    /// A throwaway registry with the sample hosts in it.
    ///
    /// A file rather than an in-memory list because `PeerStore` wraps a
    /// registry and nothing about that is worth mocking for a preview: writing
    /// three records into the temporary directory costs nothing and exercises
    /// the same decode path the app uses.
    ///
    /// **Never `applicationSupport()`, which is the device's own peer list.**
    /// `AddEndpointView` and the unpair flow both write, so a preview pointed
    /// at the real registry would edit hosts outside the canvas — an earlier
    /// version of that view's preview built a plain `PeerStore()` and did
    /// exactly this.
    ///
    /// A fresh directory per call rather than one wiped and reused: Xcode keeps
    /// more than one preview alive, and a shared path means the one you are
    /// editing has its file rebuilt underneath it the moment another renders.
    static func sample(_ peers: [PairedPeer] = PairedPeer.samples) -> PeerRegistry {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BleatPreviews/\(UUID().uuidString)", isDirectory: true)
        let registry = PeerRegistry(url: directory.appendingPathComponent("peers.json"))
        for peer in peers { _ = try? registry.save(peer) }
        return registry
    }
}
#endif
