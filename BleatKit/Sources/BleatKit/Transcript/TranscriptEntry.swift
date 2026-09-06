import Foundation

/// One turn of an agent's own conversation.
///
/// **This does not come from herdr.** Herdr knows nothing an agent did not draw
/// on a terminal — `agent explain` reports its state as a regex against a region
/// of the rendered screen, with the matched characters as its evidence. What
/// herdr does hand over is a *pointer*: `agent_session.value`, which for Claude
/// Code is the agent's own session id, and that names a transcript the agent
/// writes for itself.
///
/// So this is the conversation as the agent recorded it, not as it was drawn:
/// no wrapping, no colour, no box-drawing, no cursor. The thing a 142-column
/// pane could never give a phone.
public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    /// The record's own uuid, which is stable across re-reads — so a list does
    /// not lose the reader's place when the tail is fetched again.
    public let id: String
    public let role: Role
    public let text: String
    public let timestamp: Date?
    /// A subagent's conversation rather than the one on screen.
    ///
    /// Kept rather than dropped here, because "was this the agent or something
    /// it spawned" is a question the reader should be able to answer, and a
    /// parser that silently discarded half the file would be the wrong place to
    /// decide that.
    public let isSidechain: Bool

    public init(
        id: String,
        role: Role,
        text: String,
        timestamp: Date? = nil,
        isSidechain: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isSidechain = isSidechain
    }
}
