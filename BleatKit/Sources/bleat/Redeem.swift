#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import Foundation

/// `bleat redeem <bleat://pair?d=…>` — the phone's side of pairing, run from a
/// terminal.
///
/// This exists to be run against a real `bleat pair`. The iOS scanner is a
/// camera and a view around exactly this call, so having it here means the part
/// that can lock a phone out of a host — install the device key, verify it,
/// only then delete the enrollment key — is exercised end to end long before
/// there is an app to run it in.
///
/// The key it installs goes in a file rather than the Keychain: this is a Mac
/// pairing to a Mac, and the console tool has kept its keys under `~/.bleat/`
/// since Phase 1. A phone uses `KeychainKeyStore` for the same job.
enum Redeem {
    static func run(code: String) async throws {
        let deviceKey = try FileKeyStore.standard().loadOrCreate()
        let client = PairingClient(peers: .standard(), deviceKey: deviceKey)

        print("Pairing…")
        // Same reason `bleat pair` flushes: piped, stdout is block-buffered and
        // this line would appear after the connection it announces.
        fflush(stdout)
        let peer = try await client.pair(withCode: code)

        print("Paired with \(peer.name) as \(peer.username).")
        print("  host key   \(peer.hostKeyFingerprint ?? peer.hostKey)")
        print("  herdr      \(peer.herdrPath ?? "not resolved")")
        print("  reached at \(peer.lastGoodEndpoint?.description ?? "—")")
        print("  endpoints  \(peer.endpoints.map(\.description).joined(separator: ", "))")
    }

    static func list(peers: PeerRegistry) throws {
        let all = try peers.all()
        guard !all.isEmpty else {
            print("No paired peers yet. Run `bleat pair` on the host and `bleat redeem <url>` here.")
            return
        }
        for peer in all {
            print("\(peer.name)  \(peer.username)@\(peer.lastGoodEndpoint?.description ?? peer.endpoints.first?.description ?? "?")")
            print("  \(peer.hostKeyFingerprint ?? peer.hostKey)")
            print("  herdr \(peer.herdrPath ?? "not resolved")  ·  \(peer.endpoints.map(\.description).joined(separator: ", "))")
        }
    }
}

/// The device key for the console tool, in a file.
///
/// Deliberately not `KeychainKeyStore`: that one is `ThisDeviceOnly` and asks
/// for Keychain access, which is the right answer on a phone and an unhelpful
/// prompt in a terminal. Mode 0600 under a 0700 directory, like every other
/// private key the tool keeps.
struct FileKeyStore {
    let url: URL

    static func standard(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bleat")
    ) -> FileKeyStore {
        FileKeyStore(url: directory.appendingPathComponent("device_key"))
    }

    func loadOrCreate() throws -> SSHKeyPair {
        if let data = try? Data(contentsOf: url) {
            return try SSHKeyPair(rawRepresentation: data)
        }
        let created = SSHKeyPair()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try created.rawRepresentation.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return created
    }
}

#endif
