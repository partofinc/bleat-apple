import Foundation

/// herdr-core answered a call with an error: the host was reached and said no.
///
/// The hc counterpart of `HerdrError`. `kind` is the schema's stable
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

/// The connection to herdr-core stopped making sense, or stopped.
public enum HcProtocolError: Error, Sendable, Equatable {
    /// The stream ended before `hello` was answered.
    case noHello
    /// `hello` answered, but not with framed mode on.
    case notFramed
    /// The core speaks a protocol generation this build does not.
    case unsupportedGeneration(Int)
    /// The connection closed with calls or streams still open.
    case closed
}

extension HcProtocolError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noHello: "herdr-core did not answer the handshake"
        case .notFramed: "herdr-core would not switch to framed mode"
        case .unsupportedGeneration(let generation):
            "herdr-core speaks protocol generation \(generation), which this version of Bleat does not"
        case .closed: "the connection to herdr-core closed"
        }
    }
}
