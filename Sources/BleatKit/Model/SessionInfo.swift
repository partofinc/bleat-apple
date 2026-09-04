/// A named Herdr session, from `herdr session list --json`.
///
/// Note this is a *client-side* command: unlike the socket-API commands it
/// requires `--json` and its payload has no `{"id","result"}` envelope.
public struct SessionInfo: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let running: Bool
    public let isDefault: Bool
    public let sessionDir: String?
    public let socketPath: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case running
        case isDefault = "default"
        case sessionDir = "session_dir"
        case socketPath = "socket_path"
    }
}
