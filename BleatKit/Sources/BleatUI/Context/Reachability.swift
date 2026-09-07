import BleatKit
import Network
import Observation

/// Answers the two questions in `LinkState` from the system's own view of the
/// network.
///
/// **The whole rule used to be the interface type**: on Wi-Fi or Ethernet a
/// `.local` name and an RFC1918 address may work, on cellular they cannot, so
/// `endpointsToTry` dropped them. That is right for a bare cellular connection
/// and wrong the moment a VPN is up — a zero-trust client like Twingate reaches
/// a host by its *ordinary* private address, because that kind of overlay gives
/// the host no address of its own to discover. The address that works was being
/// discarded before it was ever dialled.
///
/// So there are two monitors. The default path answers "is a local network
/// directly attached", and a second one restricted to tunnel interfaces answers
/// "is there a VPN at all".
///
/// Starts optimistic on the link and pessimistic on the tunnel: the first path
/// update arrives in milliseconds, and the cost of each initial guess being
/// wrong is one extra candidate in a concurrent race, or one fewer for a few
/// milliseconds.
@Observable
public final class Reachability {
    public private(set) var link = LinkState.localLink

    /// The default path: what this device would use to reach the internet.
    private let monitor = NWPathMonitor()
    /// Restricted to `.other`, which is what a `utun` from a `NEPacketTunnelProvider`
    /// reports as — every VPN and zero-trust client on iOS is one.
    ///
    /// A *second* monitor rather than `usesInterfaceType(.other)` on the first,
    /// and the difference is the case that matters. Twingate and most
    /// zero-trust clients split-tunnel: they claim routes for the configured
    /// resources and leave everything else on cellular, so the **default** path
    /// is still cellular and does not use the tunnel at all. Asking the default
    /// path would answer "no tunnel" with the tunnel plainly up. A monitor with
    /// a required interface type reports satisfied when an interface of that
    /// type exists and can carry traffic, which is the question actually being
    /// asked.
    private let tunnelMonitor = NWPathMonitor(requiredInterfaceType: .other)
    private let queue = DispatchQueue(label: "team.partof.bleat.reachability")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let local = path.usesInterfaceType(.wifi)
                || path.usesInterfaceType(.wiredEthernet)
                || path.usesInterfaceType(.loopback)
            // Hops to the main actor because the value is read from view
            // bodies; `NWPathMonitor` calls back on its own queue.
            Task { @MainActor [weak self] in
                self?.link.onLocalLink = local
            }
        }
        tunnelMonitor.pathUpdateHandler = { [weak self] path in
            let tunnel = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.link.tunnelActive = tunnel
            }
        }
        monitor.start(queue: queue)
        tunnelMonitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        tunnelMonitor.cancel()
    }
}
