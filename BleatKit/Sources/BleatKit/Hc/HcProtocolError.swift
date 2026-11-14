import Foundation

/// The connection to herdr-core stopped making sense, or stopped.
public enum HcProtocolError: Error, Sendable, Equatable, Codable {
    /// The stream ended before `hello` was answered.
    case noHello
    /// `hello` answered, but not with framed mode on.
    case notFramed
    /// The core speaks a protocol generation this build does not.
    case unsupportedGeneration(Int)
    /// The core does not offer methods Bleat needs: an older herdr-core than
    /// Bleat supports. `version` is what `hello` said, when it said.
    case outdated(version: String?, missing: [String])
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
        case .outdated(let version, let missing):
            "herdr-core\(version.map { " \($0)" } ?? "") on this host is too old for Bleat: "
                + "it has no \(missing.joined(separator: ", ")). Update herdr-core on the host."
        case .closed: "the connection to herdr-core closed"
        }
    }
}
