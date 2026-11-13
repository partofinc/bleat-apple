import Foundation

/// A template on the host, from `templates.list` (`Fixtures/hc-templates.json`).
///
/// The user's own files under `~/.config/herdr-core/templates`: a role with a
/// command and a body the core sends as the first message.
public struct HcTemplate: Sendable, Equatable, Identifiable, Decodable {
    public let name: String
    public let description: String
    public let command: String
    /// Set when the file cannot be used.
    public let error: String?

    public var id: String { name }

    public init(name: String, description: String, command: String, error: String? = nil) {
        self.name = name
        self.description = description
        self.command = command
        self.error = error
    }

    /// The usable templates in `templates.list`'s reply, by name. One that
    /// does not read, or that the core says cannot be used, is left out
    /// rather than failing the list.
    public static func list(inReply reply: HcJSON) -> [HcTemplate] {
        guard case .array(let items)? = reply["templates"] else { return [] }
        return items
            .compactMap { try? $0.decode(HcTemplate.self) }
            .filter { $0.error == nil }
            .sorted { $0.name < $1.name }
    }
}
