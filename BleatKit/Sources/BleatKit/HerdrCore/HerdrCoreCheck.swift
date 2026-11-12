import Foundation

/// Asks a paired host whether it has herdr-core: the gate every peer paired
/// under Bleat 1.x passes through before the hc screens use it.
///
/// **Over the same SSH path 1.x connects on**, `PeerConnection.open`: the same
/// endpoint race, host key pin and device key. Nothing about the peer record
/// changes, so a host paired for herdr is migrated rather than re-paired.
///
/// One short connection per check, closed before returning. It is not the
/// browsing connection `ConnectionStore` holds, and must not be left open on
/// someone's Mac.
public enum HerdrCoreCheck {
    public enum Outcome: Sendable, Equatable {
        /// The host answered. `endpoint` is the address that won, worth
        /// recording as the peer's last good one.
        case answered(HerdrCore, endpoint: Endpoint)
        /// No answer: nothing was reachable, or the host key did not match.
        /// The message is the error's own description.
        case unreachable(String)
        /// The check was cancelled before the host answered. Says nothing
        /// about the host, so nothing may be recorded from it.
        case cancelled
    }

    /// Connects, asks, disconnects. Never throws: every way it can end is an
    /// outcome the host list shows.
    @concurrent
    public static func run(peer: PairedPeer, deviceKey: SSHKeyPair, link: LinkState) async -> Outcome {
        let visit = await PeerVisit.run(to: peer, deviceKey: deviceKey, link: link) { connection in
            await ask(connection.transport, endpoint: connection.endpoint)
        }
        switch visit {
        case .reached(let outcome):
            // A command cut short by cancellation can come back as anything —
            // an empty read looks like "no hc". Only an uncancelled answer
            // counts.
            return Task.isCancelled ? .cancelled : outcome
        case .unreachable(let message):
            return .unreachable(message)
        case .cancelled:
            return .cancelled
        }
    }

    /// The two questions, over a shell that is already connected.
    ///
    /// A `TransportError` part way is the connection going, not an answer —
    /// that host is unreachable for this check. Any other failure of the
    /// version command is the `hc` found not running as herdr-core, which is
    /// an answer: it is missing.
    static func ask(_ shell: any ShellRunner, endpoint: Endpoint) async -> Outcome {
        do {
            return .answered(try await find(over: shell), endpoint: endpoint)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unreachable(String(describing: error))
        }
    }

    /// Where herdr-core is on the host behind `shell`, or that it is not there.
    ///
    /// Also what `bleat terminals <host>` uses to find `hc` before it connects.
    ///
    /// - Throws: `TransportError` when the connection goes part way, and
    ///   `CancellationError`. Neither is an answer about hc.
    public static func find(over shell: any ShellRunner) async throws -> HerdrCore {
        // `PATH` first, so an hc the user put somewhere else wins.
        let onPath = HerdrCoreLookup.path(inOutput: try await shell.run(shell: HerdrCoreLookup.locate))
        if let onPath, let version = try await version(of: onPath, over: shell) {
            return .installed(path: onPath, version: version)
        }
        // The standard locations when `PATH` has no hc, **or has one that is
        // not herdr-core**: the installer leaves another `hc` alone and puts
        // herdr-core beside it under its own name.
        let candidates = HerdrCoreLookup.paths(inOutput: try await shell.run(shell: HerdrCoreLookup.standardLocations))
        for path in candidates where path != onPath {
            if let version = try await version(of: path, over: shell) {
                return .installed(path: path, version: version)
            }
        }
        return .missing
    }

    /// What `path --version` says, if it answers as herdr-core.
    ///
    /// - Throws: `TransportError` and `CancellationError` only. Any other
    ///   failure is the binary not running as herdr-core, which is an answer.
    private static func version(of path: String, over shell: any ShellRunner) async throws -> String? {
        let printed: String
        do {
            printed = try await shell.run(shell: HerdrCoreLookup.version(at: path))
        } catch let error as TransportError {
            throw error
        } catch is CancellationError {
            // Not an answer about hc. Caught as "missing" once, which
            // would have been stored and shown as "Install herdr-core".
            throw CancellationError()
        } catch {
            return nil
        }
        return HerdrCoreLookup.version(inOutput: printed)
    }
}
