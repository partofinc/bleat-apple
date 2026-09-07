#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import BleatProcess
import Foundation

/// `bleat inspect` — prints what `bleat pair` would put in a QR.
///
/// Exists on its own because pairing has exactly one hard-to-debug half: what
/// this machine thinks its own reachable addresses are. Seeing the list before
/// a phone is involved is the difference between "pairing failed" and "the
/// address it offered was the Tailscale one and the tunnel is down".
enum Inspect {
    static func run(options: Options) throws {
        let port = options.port ?? 22
        let report = try HostInspector().inspect(
            port: port,
            // Re-parsed here so an endpoint given without a port inherits
            // --port rather than silently defaulting to 22.
            extraEndpoints: options.endpoints.compactMap { Endpoint(string: $0, defaultPort: port) }
        )

        print("name          \(report.name)")
        print("username      \(report.username)")
        print("herdr         \(report.herdrPath)")
        print("host key      \(report.hostKeyFingerprint ?? report.hostKey)")
        print("endpoints     \(report.endpoints.isEmpty ? "(none found)" : "")")
        for endpoint in report.endpoints {
            let reach = switch endpoint.reach {
            case .multicastDNS:   "mdns      — same network only"
            // Named apart from the mDNS case because a VPN can carry this one
            // and cannot carry that one, which is the whole reason a phone on
            // cellular with a zero-trust client up can still reach this host.
            case .privateAddress: "lan       — same network, or a VPN routing it"
            case .overlay:        "overlay   — works over the tunnel, including cellular"
            case .routable:       "routable  — public"
            }
            print("  \(endpoint.description.padded(42)) \(reach)")
        }

        if !report.endpoints.contains(where: \.isUsableOffLink) {
            print("")
            print("note: every endpoint is LAN-only, so a phone will reach this host")
            print("      on the same network, or through a VPN that routes one of the")
            print("      private addresses above. Add one with --endpoint, or bring up")
            print("      a mesh VPN, if you want it to work from cellular unaided.")
        }
    }
}

#endif
