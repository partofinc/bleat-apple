import Foundation

/// herdr-core answered a call with an error: the host was reached and said no.
///
/// `kind` is the schema's stable
/// `data.kind`, which is what to branch on; `message` is written for a person.
public struct HcError: Error, Sendable, Equatable, Decodable {
    public let code: Int
    public let message: String
    public let kind: String?
    /// The method that was called, filled in by `HcClient`.
    public var method: String?

    private enum CodingKeys: String, CodingKey { case code, message, data }
    private enum DataKeys: String, CodingKey { case kind }

    public init(code: Int, message: String, kind: String? = nil, method: String? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
        self.method = method
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        kind = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            .decodeIfPresent(String.self, forKey: .kind)
        method = nil
    }
}

extension HcError: CustomStringConvertible {
    public var description: String { message }
}
