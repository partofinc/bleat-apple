import Foundation

/// Installs herdr-core on a paired host with its official installer, over the
/// same SSH path the herdr-core check uses.
///
/// **The official installer, run as published.** It is non-interactive: no
/// tty, no sudo, nothing asked (`install.sh`, read 12 Nov 2026). It writes
/// `~/.local/bin/herdr-core`, an `hc` link beside it when no `hc` exists, and
/// on a Mac the signed `Herdr Core.app` it points into. A fresh install does
/// not start a core; the first `hc connect` does. On a host that already has
/// one under `~/.local/bin` it updates in place and running terminals keep
/// running — which is why Bleat only offers it to a host that answered
/// "missing".
///
/// The user is shown `displayCommand` before anything runs. What runs is the
/// same script, fetched to a temporary file first: piped into `sh`, a failed
/// download is an empty script that exits 0, and the only sign is that hc is
/// still missing afterwards, with curl's reason thrown away.
public enum HerdrCoreInstall {
    public static let scriptURL = "https://releases.herdr.dev/core/install.sh"

    /// What the user is told will run: herdr-core's documented one-liner.
    public static let displayCommand = "curl -fsSL \(scriptURL) | sh"

    /// What does run. `/bin/sh` inside single quotes, as the lookup's
    /// `standardLocations`, so a fish login shell only passes a string.
    /// The script's exit status is kept through the cleanup.
    public static let command =
        #"/bin/sh -c 'f=$(mktemp) || exit 1; curl -fsSL "# + scriptURL
        + #" -o "$f" && sh "$f"; s=$?; rm -f "$f"; exit $s'"#

    public enum Outcome: Sendable, Equatable {
        /// The installer ran and the lookup now finds herdr-core.
        /// `endpoint` is the address that won, as for a check.
        case installed(HerdrCore, endpoint: Endpoint)
        /// The host was reached and the install did not work. The message is
        /// the installer's own words where it gave any.
        case failed(String)
        /// The connection dropped while the installer ran: the phone went to
        /// the background, or the network went. It may or may not have
        /// finished on the host, and running it again either finishes it or
        /// updates in place. The message is the transport's.
        case interrupted(String)
        /// Nothing was reachable, or the host key did not match.
        case unreachable(String)
        /// Cancelled before an answer. Nothing may be recorded from it.
        case cancelled
    }

    /// Connects, installs, looks again, disconnects. Never throws.
    @concurrent
    public static func run(peer: PairedPeer, deviceKey: SSHKeyPair, link: LinkState) async -> Outcome {
        let visit = await PeerVisit.run(to: peer, deviceKey: deviceKey, link: link) { connection in
            await install(over: connection.transport, endpoint: connection.endpoint)
        }
        switch visit {
        case .reached(let outcome):
            return kept(outcome, wasCancelled: Task.isCancelled)
        case .unreachable(let message):
            return .unreachable(message)
        case .cancelled:
            return .cancelled
        }
    }

    /// What a cancellation late in the run leaves of its outcome.
    ///
    /// **A finished install is kept.** The installer ran and the lookup found
    /// herdr-core: that is true of the host whatever happened to the task, and
    /// dropping it would leave "Install herdr-core" on screen for a host that
    /// has it, and run the installer again on the next tap. Anything else is
    /// voided, as for a check: a command cut short can read as anything.
    static func kept(_ outcome: Outcome, wasCancelled: Bool) -> Outcome {
        guard wasCancelled else { return outcome }
        if case .installed = outcome { return outcome }
        return .cancelled
    }

    /// The install and the look afterwards, over a shell already connected.
    static func install(over shell: any ShellRunner, endpoint: Endpoint) async -> Outcome {
        let printed: String
        do {
            printed = try await shell.run(shell: command)
        } catch is CancellationError {
            return .cancelled
        } catch let error as ShellError {
            // The installer says why on stderr, prefixed `hc:`: "needs curl",
            // "no build for armv7l", "cannot reach …".
            return .failed(error.stderr.isEmpty ? String(describing: error) : error.stderr)
        } catch {
            // Connected a moment ago, so not "unreachable": the installer was
            // running when the connection went.
            return .interrupted(String(describing: error))
        }
        let found: HerdrCore
        do {
            found = try await HerdrCoreCheck.find(over: shell)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .interrupted(String(describing: error))
        }
        guard found.isInstalled else {
            // Exit 0 and still nothing: say what the installer printed, which
            // names where it put hc.
            let said = printed.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(said.isEmpty
                ? "the installer finished, but herdr-core is still not found"
                : "the installer finished, but herdr-core is still not found. It said: \(said)")
        }
        return .installed(found, endpoint: endpoint)
    }
}
