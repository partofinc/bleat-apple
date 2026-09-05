import Network
import Observation

/// Whether the phone is somewhere a `.local` name or an RFC1918 address could
/// resolve.
///
/// The whole rule is the interface type: on Wi-Fi or Ethernet those addresses
/// may work, on cellular they cannot resolve or route at all and attempting
/// them only spends the connection's timeout budget. `PairedPeer.endpointsToTry`
/// takes this and drops them rather than ordering them last.
///
/// Starts optimistic. The first path update arrives in milliseconds, and being
/// briefly wrong towards *trying* an address is cheaper than being wrong
/// towards refusing to.
@Observable
public final class Reachability {
    public private(set) var isOnLocalLink = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "team.partof.bleat.reachability")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let local = path.usesInterfaceType(.wifi)
                || path.usesInterfaceType(.wiredEthernet)
                || path.usesInterfaceType(.loopback)
            // Hops to the main actor because the value is read from view
            // bodies; `NWPathMonitor` calls back on its own queue.
            Task { @MainActor [weak self] in
                self?.isOnLocalLink = local
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
