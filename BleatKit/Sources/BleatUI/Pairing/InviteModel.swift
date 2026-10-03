import BleatKit
import Foundation
import Observation

/// Pairing another device from this one: `bleat pair`, without the terminal.
///
/// This device is already trusted by the host, so it installs the single-use
/// key itself over its own connection and shows the code the host's tool
/// would have. The other device scans it with the ordinary pairing sheet.
///
/// **The key is withdrawn whenever this screen stops watching it** — the
/// sheet closed, the code expired, the task cancelled — and sshd's
/// `expiry-time` covers every way this device can stop without saying so.
@Observable
final class InviteModel {
    enum Phase: Equatable {
        /// Installing the key.
        case opening
        /// The code is up and nobody has used it.
        case showing(Invitation)
        /// Another device swapped its own key in.
        case redeemed
        /// Something on the host removed the key: `bleat pair`'s sweep, or
        /// `bleat keys revoke`.
        case withdrawn
        /// Nobody scanned it in time. The key is gone.
        case expired
        /// The key could not be installed. Nothing was left behind.
        case failed(String)
    }

    private(set) var phase: Phase = .opening

    /// How often the host is asked whether the code has been used. Its own
    /// tool asks ten times a second, locally; this is an exec channel over
    /// whatever network the phone is on.
    static let pollInterval: Duration = .seconds(1)

    /// A shell on the host, through the app's one connection. A closure so a
    /// test can stand in for the host.
    typealias Shell = @MainActor () async throws -> any ShellRunner

    /// Opens a code and watches it until it is used, removed, expired, or this
    /// task is cancelled. Run from the screen's `.task`, whose cancellation is
    /// the screen going away.
    ///
    /// - Parameters:
    ///   - shell: Asked afresh for every command, so a connection dropped
    ///     while the code is up is re-dialled rather than polled dead.
    ///   - handle: Told about every failure, as every screen tells
    ///     `ConnectionStore.handle`, so a dead connection is dropped.
    ///   - now, pollInterval: The clock and the tick, for a test.
    func run(
        peer: PairedPeer,
        shell: @escaping Shell,
        handle: @escaping @MainActor (any Error) async -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        pollInterval: Duration = InviteModel.pollInterval
    ) async {
        phase = .opening
        let invitation: Invitation
        do {
            invitation = try await Invitation.open(for: peer, on: shell(), now: now())
        } catch {
            await handle(error)
            phase = .failed(ErrorMessage.of(error))
            return
        }
        phase = .showing(invitation)

        while now() < invitation.deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // The screen went away with the code still up.
                Self.withdrawLater(invitation, shell: shell)
                return
            }
            do {
                switch try await invitation.state(on: shell()) {
                case .waiting:
                    continue
                case .redeemed:
                    phase = .redeemed
                    return
                case .withdrawn:
                    phase = .withdrawn
                    return
                }
            } catch is CancellationError {
                Self.withdrawLater(invitation, shell: shell)
                return
            } catch where Task.isCancelled {
                // Cancelled mid-command, which a transport may report as
                // anything at all.
                Self.withdrawLater(invitation, shell: shell)
                return
            } catch {
                // A dropped connection is not the end of the code: the key is
                // still on the host, and the next tick re-dials. Only the
                // deadline ends the wait.
                await handle(error)
            }
        }
        try? await invitation.withdraw(on: shell())
        phase = .expired
    }

    /// Removes the key from a task of its own, because the one that was
    /// watching it has been cancelled — and a command started from a cancelled
    /// task may not run at all. Best effort: if the host cannot be reached,
    /// sshd's deadline is what removes it.
    private static func withdrawLater(_ invitation: Invitation, shell: @escaping Shell) {
        Task { @MainActor in
            try? await invitation.withdraw(on: shell())
        }
    }
}
