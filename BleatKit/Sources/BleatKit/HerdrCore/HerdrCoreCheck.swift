import Foundation

/// Asks a paired host whether it has herdr-core: the gate every peer paired
/// under Bleat 1.x passes through before the hc screens use it.
///
/// **Over the same SSH path 1.x connects on**, `PeerConnection.open`: the same
/// endpoint race, host key pin and device key. Nothing about the peer record
/// changes, so a host paired for herdr is migrated rather than re-paired.
/// `open` rather than `connect` because `connect` resolves `herdr`, and a host
/// that has moved to herdr-core may no longer have it.
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
        let connection: PeerConnector.Connection
        do {
            connection = try await PeerConnection.open(to: peer, deviceKey: deviceKey, link: link)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unreachable(String(describing: error))
        }
        var outcome = await ask(connection.transport, endpoint: connection.endpoint)
        // A command cut short by cancellation can come back as anything — an
        // empty read looks like "no hc". Only an uncancelled answer counts.
        if Task.isCancelled { outcome = .cancelled }
        // On every path. A failed command does not close the channel and
        // neither does cancellation, so returning without this leaves an SSH
        // session open on the host.
        await connection.transport.disconnect()
        return outcome
    }

    /// The two questions, over a shell that is already connected.
    ///
    /// A `TransportError` part way is the connection going, not an answer —
    /// that host is unreachable for this check. Any other failure of the
    /// version command is the `hc` found not running as herdr-core, which is
    /// an answer: it is missing.
    static func ask(_ shell: any ShellRunner, endpoint: Endpoint) async -> Outcome {
        do {
            let located = try await shell.run(shell: HerdrCoreLookup.locate)
            guard let path = HerdrCoreLookup.path(inOutput: located) else {
                return .answered(.missing, endpoint: endpoint)
            }
            let printed: String
            do {
                printed = try await shell.run(shell: HerdrCoreLookup.version(at: path))
            } catch let error as TransportError {
                throw error
            } catch is CancellationError {
                // Not an answer about hc. Caught as "missing" once, which
                // would have been stored and shown as "Install herdr-core".
                return .cancelled
            } catch {
                return .answered(.missing, endpoint: endpoint)
            }
            guard let version = HerdrCoreLookup.version(inOutput: printed) else {
                return .answered(.missing, endpoint: endpoint)
            }
            return .answered(.installed(path: path, version: version), endpoint: endpoint)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unreachable(String(describing: error))
        }
    }
}
