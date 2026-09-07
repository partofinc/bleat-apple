import BleatKit
import SwiftUI

/// One address a peer answers on, and how far away it works from.
struct EndpointRow: View {
    let endpoint: Endpoint
    /// The one that last completed a handshake. Tried first next time.
    let isLastGood: Bool

    var body: some View {
        LabeledContent {
            Text(reachDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            // A checkmark as well as the label, so the distinction survives for
            // anyone who cannot rely on position or colour alone.
            Label {
                Text(endpoint.description)
                    .font(.footnote.monospaced())
            } icon: {
                Image(systemName: isLastGood ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isLastGood ? .green : .secondary)
            }
            .accessibilityLabel(
                isLastGood
                    ? "\(endpoint.description), last used"
                    : endpoint.description
            )
        }
    }

    /// Says where the address works from, which is the only thing about it a
    /// user can act on: a LAN address that fails on cellular is not broken.
    private var reachDescription: String {
        switch endpoint.reach {
        case .linkScoped: "local network"
        // Distinguished from the case above because it is not the same promise:
        // a VPN that routes this subnet reaches it from anywhere, and that is
        // how a zero-trust client like Twingate works. Nothing carries an mDNS
        // name, a loopback or a link-local address off the link it belongs to.
        case .privateAddress: "local network or VPN"
        case .overlay: "VPN"
        case .routable: "anywhere"
        }
    }
}

#if DEBUG
/// One row per `Endpoint.Reach`, because the only thing this row says is which
/// one it is — and "local network" against "local network or VPN" is the
/// distinction the whole Twingate fix turns on.
#Preview("Every reach", traits: .sampleData) {
    List {
        EndpointRow(endpoint: Endpoint(host: "rawillkair.local"), isLastGood: false)
        EndpointRow(endpoint: Endpoint(host: "192.168.11.54"), isLastGood: true)
        EndpointRow(endpoint: Endpoint(host: "rawillk.tail2a3bab.ts.net"), isLastGood: false)
        EndpointRow(endpoint: Endpoint(host: "100.114.119.30"), isLastGood: false)
        EndpointRow(endpoint: Endpoint(host: "home.example.com", port: 2222), isLastGood: false)
        EndpointRow(endpoint: Endpoint(host: "[2a00:f3c:5ad0:0:c29:6db5:4a49:dc53]"), isLastGood: false)
    }
}
#endif
