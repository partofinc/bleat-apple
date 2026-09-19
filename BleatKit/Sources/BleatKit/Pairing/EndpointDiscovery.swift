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

    /// What each probe said, kept apart rather than flattened into one list.
    ///
    /// **The separation is the whole safety of pruning.** A refresh may delete
    /// an address the host has stopped reporting, and the only thing that makes
    /// that safe is knowing the host actually *answered* about it. Flattened,
    /// one flaky probe is indistinguishable from a host that has dropped a
    /// whole category: `tailscale` timing out — or simply being switched off,
    /// which is a `BackendState` of `Stopped` and not an error at all — while
    /// `scutil` and `ifconfig` answer normally yields a perfectly non-empty
    /// report with no overlay endpoints in it. Pruning against that deletes the
    /// MagicDNS name and both tunnel addresses in one pass, and the next time
    /// the phone is on cellular the host is unreachable for good. A permanent
    /// re-pair caused by a transient condition is precisely the cost this
    /// feature exists to remove.
    ///
    /// So each field is independently optional, and **`nil` means "this probe
    /// gave no confident answer", which prunes nothing.** An empty array is a
    /// real answer: the probe ran and the host has none of that kind.
    public struct Report: Sendable, Equatable, Codable {
        /// The host's mDNS name, from `scutil`.
        public var localHostName: [Endpoint]?
        /// Interface addresses, from `ifconfig`. Includes the tunnel's `utun`
        /// addresses, which is why the Tailscale CLI contributes only a name.
        public var interfaces: [Endpoint]?
        /// The MagicDNS name, from a `tailscale` that reported a running
        /// tailnet. `nil` covers "not installed", "not logged in" and "stopped"
        /// alike — none of which is evidence that the node's addresses are
        /// gone, since they outlive a stopped daemon.
        public var tailscale: [Endpoint]?

        /// Not a probe: the last-good address a refresh put back after the
        /// host stopped reporting it.
        ///
        /// Recorded so the exemption lasts **one refresh instead of forever**.
        /// Re-adding it to the endpoint list without noting it here would leave
        /// it looking like an address the host never claimed — permanently
        /// sticky, immune to every later refresh, and still there long after
        /// `recordSuccess` had moved on. A recycled DHCP lease that won a race
        /// once would live in the peer for good, which is the stale-address
        /// hazard the pruning exists for.
        public var reinstated: [Endpoint]?

        public init(
            localHostName: [Endpoint]? = nil,
            interfaces: [Endpoint]? = nil,
            tailscale: [Endpoint]? = nil,
            reinstated: [Endpoint]? = nil
        ) {
            self.localHostName = localHostName
            self.interfaces = interfaces
            self.tailscale = tailscale
            self.reinstated = reinstated
        }

        /// Whether any probe answered. A report where none did must change
        /// nothing at all — it is the host being unaskable, not the host being
        /// addressless.
        public var answered: Bool {
            localHostName != nil || interfaces != nil || tailscale != nil
        }

        /// Everything reported, in the order that matters.
        ///
        /// The mDNS name first, then the interface addresses, then Tailscale —
        /// and the de-duplication keeps whichever arrived first, which is why
        /// the tunnel's `utun` addresses are credited to `ifconfig` rather than
        /// to the CLI. What the CLI adds that no interface can is the name.
        public var all: [Endpoint] {
            var seen = Set<Endpoint>()
            return ((localHostName ?? []) + (interfaces ?? []) + (tailscale ?? []))
                .filter { seen.insert($0).inserted }
        }

        /// What a newer report is entitled to delete from this one.
        ///
        /// Only the categories the newer report actually answered for. A probe
        /// that said nothing this time leaves its previous answers untouched,
        /// which is what stops a stopped Tailscale from erasing a peer's only
        /// route home.
        public func superseded(by newer: Report) -> Set<Endpoint> {
            var result: Set<Endpoint> = []
            if newer.localHostName != nil { result.formUnion(localHostName ?? []) }
            if newer.interfaces != nil { result.formUnion(interfaces ?? []) }
            if newer.tailscale != nil { result.formUnion(tailscale ?? []) }
            // One refresh only — see `reinstated`. Any answering probe is
            // enough to end the exemption, because the address was put back on
            // the strength of a handshake that is now a refresh old.
            if newer.answered { result.formUnion(reinstated ?? []) }
            return result
        }

        /// Folds a newer report in, per category. A category the newer report
        /// was silent about keeps the older answer, so the stored view is the
        /// most recent *confident* answer for each rather than the most recent
        /// attempt.
        public func merging(_ newer: Report) -> Report {
            Report(
                localHostName: newer.localHostName ?? localHostName,
                interfaces: newer.interfaces ?? interfaces,
                tailscale: newer.tailscale ?? tailscale,
                // Deliberately not carried forward: it is recomputed by
                // whichever refresh needs it, and stale otherwise.
                reinstated: newer.reinstated
            )
        }
    }

    /// The raw answers, however they were obtained.
    ///
    /// All optional and all independently so, for `Report`'s reason: a host
    /// with no `tailscale`, or an older macOS without `scutil`, must still
    /// yield the addresses that *did* come back — and must not have the rest
    /// pruned on its behalf.
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

    /// Assembles a report from whatever came back.
    ///
    /// Empty output is read as **no answer**, not as an empty answer. Every one
    /// of these probes ends in `|| true`, so a missing tool and a tool that
    /// found nothing both arrive as an empty string — and treating that as "the
    /// host has none of these" would let an absent `scutil` prune the host's
    /// own name.
    public static func report(
        from outputs: Outputs,
        port: Int = Endpoint.defaultPort
    ) -> Report {
        var report = Report()
        if let name = outputs.localHostName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            report.localHostName = [Endpoint(host: "\(name).local", port: port)]
        }
        if let text = outputs.ifconfig, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.interfaces = InterfaceAddresses.endpoints(ifconfigOutput: text, port: port)
        }
        if let json = outputs.tailscaleStatusJSON,
           !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.tailscale = TailscaleStatus.endpoints(fromStatusJSON: Data(json.utf8), port: port)
        }
        return report
    }

    /// The flat list, for `bleat pair` — which wants every address at once and
    /// has no peer to prune against.
    public static func endpoints(
        from outputs: Outputs,
        port: Int = Endpoint.defaultPort
    ) -> [Endpoint] {
        report(from: outputs, port: port).all
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

    /// Every `tailscale` on the host until one speaks for a **running**
    /// tailnet, with a watchdog and a scratch file.
    ///
    /// Absolute paths only, and in the same order `HostInspector` uses. `PATH`
    /// is deliberately not searched: resolving a tool through the user's `PATH`
    /// on a machine we are about to record addresses from is a way to run
    /// something else entirely.
    ///
    /// Five details, and four of them were bugs:
    ///
    /// - **Existing is not answering, and neither is exiting 0.**
    ///   `brew install tailscale` leaves a CLI in `/opt/homebrew/bin` that
    ///   cannot reach the App Store app's sandboxed daemon, and having both is
    ///   a common combination. Such a CLI may exit cleanly reporting
    ///   `NeedsLogin` or `Stopped`, so stopping at the first clean exit takes
    ///   that one and never tries the bundled binary that would have answered.
    ///   The success condition is `BackendState` — matched here and by
    ///   `TailscaleStatus.isRunning` locally, which have to agree.
    /// - **Each attempt writes to its own scratch file.** Writing to stdout
    ///   directly concatenates the attempts: a first binary that emits a
    ///   partial object before failing, or one killed mid-write by the
    ///   watchdog, leaves that fragment glued to the front of the next
    ///   binary's reply. Verified — the result is
    ///   `{"partial":{...}{"BackendState":...}`, which parses as nothing, so
    ///   the loop written to save the MagicDNS name would have lost it in the
    ///   exact case it exists for.
    /// - **The watchdog's own output goes to `/dev/null`** so it is not a
    ///   writer on the channel. Left attached it would hold the command open
    ///   for the full five seconds on every run, including the ordinary case
    ///   where `tailscale` answered at once. `tailscale` has no timeout flag,
    ///   and a wedged `tailscaled` would otherwise hold this exec channel for
    ///   the life of the connection.
    /// - **`status` is a read-only variable in zsh**, which is what sshd runs
    ///   on a modern macOS — an exec channel goes through the user's login
    ///   shell. Naming the exit status that made the whole loop abort under the
    ///   one shell it will actually meet, while working under `sh` and `bash`
    ///   where it was written and tried. It fails *safe* now that a silent
    ///   probe prunes nothing, but the feature would simply never have worked.
    ///   Found by running the string under all three, not by reading it.
    /// - **`exec 2>/dev/null`** because killing the watchdog makes the shell
    ///   announce the job's death — `Terminated: 15` — on stderr. Harmless to
    ///   the parsed stdout, and noise in every log that ever carries it.
    public static let tailscaleStatusCommand = """
        exec 2>/dev/null
        t=$(mktemp) || exit 0
        for p in /usr/bin/tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
        /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
          [ -x "$p" ] || continue
          : > "$t"
          "$p" status --json >"$t" 2>/dev/null &
          probe=$!
          ( sleep 5; kill -TERM $probe ) >/dev/null 2>&1 &
          watchdog=$!
          wait $probe
          answered=$?
          kill $watchdog >/dev/null 2>&1
          if [ $answered -eq 0 ] && grep -q '"BackendState"[^,]*"Running"' "$t"; then
            cat "$t"
            rm -f "$t"
            exit 0
          fi
        done
        rm -f "$t"
        true
        """

    /// Asks a host, over a shell it already has, what its addresses are now.
    ///
    /// Best effort throughout: a probe that fails contributes `nil` — no
    /// answer, prune nothing — rather than failing the refresh. This runs in
    /// the background behind a connection the user is already using, and the
    /// worst outcome worth having is "the endpoints did not change today".
    ///
    /// **Cancellation is checked between every command, and a cancelled probe
    /// reports nothing at all.** Two separate hazards, and neither is theory:
    ///
    /// - `SSHTransport` re-dials lazily when its client is nil, and
    ///   `SSHClient.connect` does not observe cancellation. So a command run
    ///   after `ConnectionStore.release()` has disconnected opens a *brand new*
    ///   SSH session that nothing holds a reference to and nothing will close —
    ///   an orphaned session on the user's Mac, which is the one thing
    ///   `ConnectionStore` promises not to leave behind.
    /// - A partial report is worse than no report. Cancelled after `scutil` and
    ///   before the rest, this would answer "the host's only address is its
    ///   mDNS name" — non-empty, so it would be written, and every interface
    ///   and tunnel address the host had previously reported would be pruned
    ///   against it.
    public static func probe(
        _ shell: any ShellRunner,
        port: Int = Endpoint.defaultPort
    ) async -> Report {
        var outputs = Outputs()
        // Serial, not `async let`. Three concurrent exec channels would shave a
        // few hundred milliseconds off work nobody is waiting for, in exchange
        // for exercising concurrent use of `SSHTransport` — which wraps a
        // Citadel client that is not `Sendable`-audited and is lock-guarded for
        // exactly that reason. Serial is also what makes the cancellation
        // checks between them mean anything.
        if Task.isCancelled { return Report() }
        outputs.localHostName = try? await shell.run(shell: localHostNameCommand)
        if Task.isCancelled { return Report() }
        outputs.ifconfig = try? await shell.run(shell: ifconfigCommand)
        if Task.isCancelled { return Report() }
        outputs.tailscaleStatusJSON = try? await shell.run(shell: tailscaleStatusCommand)
        if Task.isCancelled { return Report() }
        return report(from: outputs, port: port)
    }
}
