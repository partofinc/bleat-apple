import Foundation

/// Any JSON value, kept as it came.
///
/// hc's events say "set these keys of the record to these values"
/// (`remote.rs`'s `apply`, in herdr-core), so the honest way to follow them is
/// to keep each terminal as the record the host sent and set keys on it, then
/// read the typed `HcTerminal` back out. A typed model alone would have to know
/// every key an event can carry, and drop the ones it did not.
public enum HcJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HcJSON])
    case object([String: HcJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HcJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: HcJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> HcJSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    /// The number as an `Int`, or nil when it is not a whole number that fits.
    ///
    /// **Never `Int(number)`.** That traps on `1e20` or `NaN`, and these
    /// numbers come from the host: a core sending something odd must produce
    /// an error, not crash the app.
    public var int: Int? {
        number.flatMap { Int(exactly: $0) }
    }

    /// The number as a channel id, or nil when it is not one.
    public var uint32: UInt32? {
        number.flatMap { UInt32(exactly: $0) }
    }

    /// Reads a typed value back out, through the same decoder the host's
    /// replies go through.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
