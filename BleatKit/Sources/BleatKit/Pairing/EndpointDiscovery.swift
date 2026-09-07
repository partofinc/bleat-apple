import Foundation

/// What a host says its own reachable addresses are.
///
/// The three probes and the assembly of their answers live here, in `BleatKit`,
/// because **both ends ask the same question**. `HostInspector` runs them
/// locally with `Foundation.Process` while `bleat pair` is minting a QR; the
/// phone runs them over an exec channel on a connection it already has, to
/// notice that a host's addresses have moved without costing a re-pair.
///
/// Two copies of "which addresses does this machine offer" would drift, and the
/// way they would drift is silent: the phone would keep refreshing a peer into
/// a shape the host would never have produced. So `HostInspector` is reduced to
/// running the commands, and the parsing it already delegated —
/// `InterfaceAddresses`, `TailscaleStatus` — is joined here by the ordering and
/// the de-duplication.
public enum EndpointDiscovery {

    /// The raw answers, however they were obtained.
    ///
    /// All optional and all independently so: a host with no `tailscale`, or an
    /// older macOS without `scutil`, must still yield the addresses that *did*
    /// come back. Pairing has always worked that way and a refresh must not be
    /// stricter, or a missing optional tool would look like a host that has
    /// lost its addresses.
    public struct Outputs: Sendable, Equatable {
        public var localHostName: String?
        public var ifconfig: String?
        public var tailscaleStatusJSON: String?

        public init(
            localHostName: String? = nil,
            ifconfig: String? = nil,
            tailscaleStatusJSON: String? = nil
        ) {
            self.localHostName = localHostName
            self.ifconfig = ifconfig
            self.tailscaleStatusJSON = tailscaleStatusJSON
        }
    }

    /// Assembles the endpoint list from whatever came back.
    ///
    /// Order is not cosmetic. The mDNS name first, then the interface
    /// addresses, then Tailscale — and the de-duplication keeps whichever
    /// arrived first, which is why the tunnel's `utun` addresses are credited
    /// to `ifconfig` rather than to the CLI. What the CLI adds that no
    /// interface can is the MagicDNS name.
    public static func endpoints(
        from outputs: Outputs,
        port: Int = Endpoint.defaultPort
    ) -> [Endpoint] {
        var endpoints: [Endpoint] = []
        if let name = outputs.localHostName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            endpoints.append(Endpoint(host: "\(name).local", port: port))
        }
        if let text = outputs.ifconfig {
            endpoints.append(contentsOf: InterfaceAddresses.endpoints(ifconfigOutput: text, port: port))
        }
        if let json = outputs.tailscaleStatusJSON {
            endpoints.append(contentsOf: TailscaleStatus.endpoints(
                fromStatusJSON: Data(json.utf8), port: port
            ))
        }
        var seen = Set<Endpoint>()
        return endpoints.filter { seen.insert($0).inserted }
    }

    // MARK: - Asking a host over a shell

    /// `|| true` on every one of these, for the reason `HerdrLookup.command`
    /// has it: absence is a normal answer. Without it a host without `scutil`
    /// produces a *failed command* over the exec channel, and the caller
    /// reports "the host rejected a command (exit 1)" for a machine that is
    /// working perfectly.
    public static let localHostNameCommand =
        "/usr/sbin/scutil --get LocalHostName 2>/dev/null || true"

    public static let ifconfigCommand = "/sbin/ifconfig 2>/dev/null || true"

    /// Every `tailscale` on the host, until one answers — and a watchdog.
    ///
    /// Absolute paths only, and in the same order `HostInspector` uses. `PATH`
    /// is deliberately not searched: resolving a tool through the user's `PATH`
    /// on a machine we are about to record addresses from is a way to run
    /// something else entirely.
    ///
    /// **Existing is not the same as answering**, which is the whole reason
    /// this is a loop. `brew install tailscale` leaves a CLI in
    /// `/opt/homebrew/bin` that cannot reach the App Store app's sandboxed
    /// daemon, and having both is a common combination — so stopping at the
    /// first path that exists would take the one that exits non-zero and
    /// silently drop the MagicDNS name that the bundled binary next in the list
    /// would have given.
    ///
    /// The `kill` after five seconds mirrors the timeout `HostInspector`
    /// imposes from outside: `tailscale` has no flag for it, and a wedged or
    /// half-started `tailscaled` would otherwise hold this exec channel open
    /// for the life of the connection. The watchdog's own output goes to
    /// `/dev/null` so it is not a writer on the channel — left attached, it
    /// would hold the command open for the full five seconds every time,
    /// including the ordinary case where `tailscale` answered at once.
    public static let tailscaleStatusCommand = """
        for p in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
        /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
          [ -x "$p" ] || continue
          "$p" status --json 2>/dev/null &
          probe=$!
          ( sleep 5; kill -TERM $probe ) >/dev/null 2>&1 &
          watchdog=$!
          if wait $probe; then kill $watchdog >/dev/null 2>&1; exit 0; fi
          kill $watchdog >/dev/null 2>&1
        done
        true
        """

    /// Asks a host, over a shell it already has, what its addresses are now.
    ///
    /// Best effort throughout: a probe that fails contributes nothing rather
    /// than failing the refresh. This runs in the background behind a
    /// connection the user is already using, and the worst outcome worth
    /// having is "the endpoints did not change today".
    ///
    /// Returning an empty list is meaningful — see
    /// `PairedPeer.refreshingEndpoints(discovered:)`, which treats it as "the
    /// host did not answer" and changes nothing, never as "the host has no
    /// addresses".
    public static func probe(
        _ shell: any ShellRunner,
        port: Int = Endpoint.defaultPort
    ) async -> [Endpoint] {
        // Serial, not `async let`. Three concurrent exec channels would shave
        // a few hundred milliseconds off work that nobody is waiting for, in
        // exchange for exercising concurrent use of `SSHTransport` — which
        // wraps a Citadel client that is not `Sendable`-audited and is
        // lock-guarded for that reason. The trade is the wrong way round for a
        // background refresh.
        let name = try? await shell.run(shell: localHostNameCommand)
        let interfaces = try? await shell.run(shell: ifconfigCommand)
        let tailscale = try? await shell.run(shell: tailscaleStatusCommand)
        return endpoints(
            from: Outputs(
                localHostName: name,
                ifconfig: interfaces,
                tailscaleStatusJSON: tailscale
            ),
            port: port
        )
    }
}
