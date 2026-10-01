import Foundation

/// A change to a host's record that started on the watch.
///
/// The phone's peer file is the only one that lasts: the watch's copy is
/// replaced whenever the phone sends a new one. So a fact the watch learns —
/// that it started a session, what the host said it is — has to be told to the
/// phone, or the next copy to arrive erases it.
public enum PeerNote: Sendable, Codable, Equatable {
    case createdSession(String)
    case startedSession(String)
    case forgotStartedSession(String)
    case forgotCreatedSession(String)
    case hostInfo(HostInfo)
}
