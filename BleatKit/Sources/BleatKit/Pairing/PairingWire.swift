import Foundation

/// The binary form a pairing QR carries.
///
/// JSON was the obvious first choice and the wrong one for this medium: keys,
/// quotes, braces and commas are perhaps forty characters of pure structure,
/// and base64 then inflates the whole thing by a third. In a QR every byte is
/// modules and modules are terminal rows the user may not have. Both ends of
/// this format ship together, so there is nothing to negotiate and no reason to
/// pay for self-description.
///
/// Layout, all integers big-endian:
///
/// ```
/// 0      version
/// 1      flags (reserved, must be 0)
/// 2..33  enrollment seed, 32 bytes
/// 34     host key kind: 0 = bare ed25519 key, 1 = full wire blob
/// 35..   host key: 32 bytes for kind 0, else 2-byte length then the blob
/// ...    username: 1-byte length, then UTF-8
/// ...    name:     1-byte length, then UTF-8
/// ...    endpoints: 1-byte count, then each 1-byte length and UTF-8
/// ```
enum PairingWire {
    static let seedLength = 32
    static let ed25519KeyLength = 32

    enum HostKeyKind: UInt8 { case ed25519 = 0, blob = 1 }

    static func encode(_ payload: PairingPayload) throws -> Data {
        var out = Data()
        out.append(UInt8(clamping: payload.version))
        out.append(0)                                   // flags
        guard payload.enrollmentSeed.count == seedLength else {
            throw PairingError.malformedPairingCode
        }
        out.append(payload.enrollmentSeed)

        guard let key = SSHPublicKeyLine(line: payload.hostKey) else {
            throw PairingError.malformedPairingCode
        }
        if let raw = key.ed25519RawKey {
            out.append(HostKeyKind.ed25519.rawValue)
            out.append(raw)
        } else {
            out.append(HostKeyKind.blob.rawValue)
            let length = key.blob.count
            guard length <= 0xFFFF else { throw PairingError.malformedPairingCode }
            out.append(UInt8(length >> 8)); out.append(UInt8(length & 0xFF))
            out.append(key.blob)
        }

        try appendString(payload.username, to: &out)
        try appendString(payload.name, to: &out)

        guard payload.endpoints.count <= 0xFF else { throw PairingError.malformedPairingCode }
        out.append(UInt8(payload.endpoints.count))
        for endpoint in payload.endpoints {
            try appendString(endpoint.description, to: &out)
        }
        return out
    }

    static func decode(_ data: Data) throws -> PairingPayload {
        var reader = Reader(data)
        let version = try reader.byte()
        guard version == UInt8(PairingPayload.currentVersion) else {
            throw PairingError.unsupportedVersion(Int(version))
        }
        _ = try reader.byte()                            // flags, ignored
        let seed = try reader.bytes(seedLength)

        let kindByte = try reader.byte()
        guard let kind = HostKeyKind(rawValue: kindByte) else {
            throw PairingError.malformedPairingCode
        }
        let hostKey: SSHPublicKeyLine
        switch kind {
        case .ed25519:
            guard let key = SSHPublicKeyLine.ed25519(rawKey: try reader.bytes(ed25519KeyLength)) else {
                throw PairingError.malformedPairingCode
            }
            hostKey = key
        case .blob:
            let length = (Int(try reader.byte()) << 8) | Int(try reader.byte())
            guard let key = SSHPublicKeyLine(blob: try reader.bytes(length)) else {
                throw PairingError.malformedPairingCode
            }
            hostKey = key
        }

        let username = try reader.string()
        let name = try reader.string()

        let count = Int(try reader.byte())
        var endpoints: [Endpoint] = []
        endpoints.reserveCapacity(count)
        for _ in 0..<count {
            guard let endpoint = Endpoint(string: try reader.string()) else {
                throw PairingError.malformedPairingCode
            }
            endpoints.append(endpoint)
        }
        guard !endpoints.isEmpty else { throw PairingError.malformedPairingCode }
        // Trailing bytes mean this is not the payload it claims to be; a
        // partial read that happened to line up is worse than a refusal.
        guard reader.isAtEnd else { throw PairingError.malformedPairingCode }

        return PairingPayload(
            version: Int(version), name: name, username: username,
            endpoints: endpoints, enrollmentSeed: seed, hostKey: hostKey.openSSHForm
        )
    }

    /// Reads the version without decoding anything else, so a payload from a
    /// newer tool can say so rather than fail as damaged.
    static func version(of data: Data) -> Int? {
        data.first.map(Int.init)
    }

    static func appendString(_ value: String, to out: inout Data) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 0xFF else { throw PairingError.malformedPairingCode }
        out.append(UInt8(bytes.count))
        out.append(bytes)
    }

    struct Reader {
        private let data: Data
        private var index: Int
        init(_ data: Data) { self.data = data; self.index = data.startIndex }
        var isAtEnd: Bool { index >= data.endIndex }

        mutating func byte() throws -> UInt8 {
            guard index < data.endIndex else { throw PairingError.malformedPairingCode }
            defer { index += 1 }
            return data[index]
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, index + count <= data.endIndex else {
                throw PairingError.malformedPairingCode
            }
            defer { index += count }
            return data[index..<(index + count)]
        }

        mutating func string() throws -> String {
            let length = Int(try byte())
            guard let text = String(data: try bytes(length), encoding: .utf8) else {
                throw PairingError.malformedPairingCode
            }
            return text
        }
    }
}
