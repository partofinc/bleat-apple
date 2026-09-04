import Foundation

/// The QR's text form: `bleat://pair?d=<base64url of a compact JSON object>`.
///
/// A URL rather than bare base64 so the system camera recognises it and can
/// hand it straight to the app — the user does not have to open Bleat first and
/// find a scanner. Keys are single letters because every byte is QR modules,
/// and modules are the difference between scanning at arm's length and having
/// to lean in.
extension PairingPayload {
    public static let urlScheme = "bleat"
    public static let urlHost = "pair"

    /// The string to put in the QR.
    public func urlString() throws -> String {
        "\(Self.urlScheme)://\(Self.urlHost)?d=\(Self.base64URLEncode(try PairingWire.encode(self)))"
    }

    /// Reads a scanned string back.
    ///
    /// The version is checked before anything else is interpreted. A newer
    /// payload may move the enrollment key or change what the host key covers,
    /// and half-understanding either is worse than telling the user to update —
    /// so an unknown version is named as such rather than reported as damage.
    public init(urlString: String) throws {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == Self.urlScheme,
              url.host?.lowercased() == Self.urlHost
        else { throw PairingError.notAPairingCode }

        guard let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "d" }),
            let encoded = item.value,
            let data = Self.base64URLDecode(encoded)
        else { throw PairingError.malformedPairingCode }

        guard let version = PairingWire.version(of: data) else {
            throw PairingError.malformedPairingCode
        }
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedVersion(version)
        }
        self = try PairingWire.decode(data)
    }

    // MARK: - base64url

    /// Standard base64 is not URL-safe: `+` and `/` are reserved, and `=`
    /// padding invites double-encoding on the way through a QR reader.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 2 { s += "==" } else if remainder == 3 { s += "=" } else if remainder != 0 { return nil }
        return Data(base64Encoded: s)
    }
}
