import Foundation

/// The QR's text form: `bleat://pair?d=<base64url of a compact JSON object>`.
///
/// A URL rather than bare base64 so the system camera recognises it and can
/// hand it straight to the app — the user does not have to open Bleat first and
/// find a scanner. Keys are single letters because every byte is QR modules,
/// and modules are the difference between scanning at arm's length and having
/// to lean in.
extension PairingPayload {
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case name = "n"
        case username = "u"
        case endpoints = "e"
        case enrollmentSeed = "k"
        case hostKeyFingerprint = "h"
        case herdrPath = "p"
    }

    public static let urlScheme = "bleat"
    public static let urlHost = "pair"

    /// The string to put in the QR.
    public func urlString() throws -> String {
        let json = try JSONEncoder().encode(self)
        return "\(Self.urlScheme)://\(Self.urlHost)?d=\(Self.base64URLEncode(json))"
    }

    /// Reads a scanned string back.
    ///
    /// Rejects an unknown `version` outright instead of decoding what it
    /// recognises: a future payload may move the enrollment key or change what
    /// the fingerprint covers, and half-understanding either one is worse than
    /// telling the user to update.
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

        // The version is checked here, off a minimal probe, rather than after
        // a full decode. A v2 code may rename or move any other field — the
        // enrollment key included — and decoding first would fail on the
        // missing field and report `malformedPairingCode`, telling the user to
        // scan again forever instead of to update the app.
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw PairingError.malformedPairingCode
        }
        guard probe.version == Self.currentVersion else {
            throw PairingError.unsupportedVersion(probe.version)
        }

        do {
            self = try JSONDecoder().decode(PairingPayload.self, from: data)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.malformedPairingCode
        }
    }

    /// Reads nothing but `v`, so an otherwise unrecognisable payload can still
    /// say which format it claims to be.
    private struct VersionProbe: Decodable {
        let version: Int
        enum CodingKeys: String, CodingKey { case version = "v" }
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
        // Restore the padding base64URLEncode stripped.
        let remainder = s.count % 4
        if remainder == 2 { s += "==" } else if remainder == 3 { s += "=" } else if remainder != 0 { return nil }
        return Data(base64Encoded: s)
    }
}

extension PairingPayload: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let endpointStrings = try c.decode([String].self, forKey: .endpoints)
        // The wire format always writes an explicit port (`description` emits
        // one), so the default here is never reached for a well-formed payload.
        let endpoints = endpointStrings.compactMap { Endpoint(string: $0) }
        guard endpoints.count == endpointStrings.count, !endpoints.isEmpty else {
            throw PairingError.malformedPairingCode
        }
        guard let seed = Self.base64URLDecode(try c.decode(String.self, forKey: .enrollmentSeed)),
              seed.count == 32
        else { throw PairingError.malformedPairingCode }

        self.init(
            version: try c.decode(Int.self, forKey: .version),
            name: try c.decode(String.self, forKey: .name),
            username: try c.decode(String.self, forKey: .username),
            endpoints: endpoints,
            enrollmentSeed: seed,
            hostKeyFingerprint: try c.decode(String.self, forKey: .hostKeyFingerprint),
            herdrPath: try c.decode(String.self, forKey: .herdrPath)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(username, forKey: .username)
        try c.encode(endpoints.map(\.description), forKey: .endpoints)
        try c.encode(Self.base64URLEncode(enrollmentSeed), forKey: .enrollmentSeed)
        try c.encode(hostKeyFingerprint, forKey: .hostKeyFingerprint)
        try c.encode(herdrPath, forKey: .herdrPath)
    }
}
