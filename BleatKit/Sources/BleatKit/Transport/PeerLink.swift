import Foundation

/// A live connection to a paired peer, as the app holds it: a shell on the
/// host, and a way to let go of it.
///
/// `SSHTransport` on the phone; `RelayTransport` on the watch, which asks the
/// phone to run things on its behalf.
public protocol PeerLink: ShellRunner {
    func disconnect() async
}
