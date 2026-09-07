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

    /// `bleat unpair <name>` — the phone's side of *un*-pairing, run from a
    /// terminal, and here for exactly the reason `run` is.
    ///
    /// The app's unpair button is a confirmation sheet around this call. What
    /// it does is take away access, so the failure worth catching is the one
    /// where it *says* it did and did not — and that can only be seen against a
    /// real host. `bleat keys list` on the other side is the check.
    /// `link` defaults to `.localLink`, which tries every endpoint. The tool
    /// runs on a Mac at a keyboard with no way to ask about tunnels, and
    /// trying an address that cannot work costs a timeout in a race — where
    /// skipping the one that would have worked costs the revocation.
    static func unpair(name: String, peers: PeerRegistry, link: LinkState = .localLink) async throws {
        let all = try peers.all()
        // By name or by host key, since the host key is the identity and a name
        // can repeat. `bleat peers` prints both.
        guard let peer = all.first(where: { $0.name == name || $0.hostKey == name }) else {
            let known = all.map(\.name).joined(separator: ", ")
            throw ToolFailure("no paired peer '\(name)'."
                + (known.isEmpty ? " Nothing is paired." : " Paired: \(known)."))
        }

        let store = FileKeyStore.standard()
        guard let deviceKey = try store.load() else {
            throw ToolFailure("""
                no device key at \(store.url.path), so there is nothing to revoke with.
                Minting one would authenticate as a different device and be refused,                 which reads as if the host had already removed the key.
                On \(peer.name), run: bleat keys list — and revoke this machine's line by hand.
                """)
        }
        print("Removing this device's key from \(peer.name)…")
        fflush(stdout)

        // Connecting is inside the same handling as the removal, because it
        // fails in the same way as far as the user is concerned: the key is
        // still on the host and this did not take it off. Reporting a bare
        // connection error left them with no idea the record was still there
        // or what to run.
        let connection: PeerConnection.Connected
        do {
            connection = try await PeerConnection.connect(
                to: peer, deviceKey: deviceKey, link: link
            )
        } catch TransportError.authenticationFailed(let detail) {
            // Reached and refused, which is the opposite advice: the key has
            // most likely already been removed there.
            let advice = RevocationAdvice.check(
                deviceMarker: peer.deviceMarker, deviceFingerprint: deviceKey.fingerprint
            )
            throw ToolFailure("""
                \(peer.name) no longer accepts this device's key: \(detail)
                It has probably already been removed there.
                It could also still be in that Mac's authorized_keys with sshd ignoring
                the file, which is what a change to its permissions does.
                Check with: \(advice.command)\(advice.detail.map { "\n\($0)" } ?? "")
                \(peer.name) is still listed here.
                """)
        } catch {
            throw stillPaired(peer, deviceKey: deviceKey, because: error)
        }

        // The key this session authenticated with is the one being deleted.
        // sshd authorises at the handshake and does not re-read the file for a
        // live session, so the verification read still runs afterwards.
        do {
            try await Revocation.revokeDeviceKey(deviceKey, on: connection.transport)
        } catch {
            await connection.transport.disconnect()
            throw stillPaired(peer, deviceKey: deviceKey, because: error)
        }
        await connection.transport.disconnect()

        try peers.remove(hostKey: peer.hostKey)
        print("Unpaired \(peer.name). Its `bleat keys list` no longer shows this device.")
    }

    /// The key is still on the host and the record is still here.
    ///
    /// Deliberately does **not** drop the record: the peer is still paired and
    /// still works, and the record holds the marker that names the line to
    /// remove. Forgetting it here would throw away the one thing that makes
    /// the advice below specific.
    private static func stillPaired(
        _ peer: PairedPeer,
        deviceKey: SSHKeyPair,
        because error: any Error
    ) -> ToolFailure {
        let advice = RevocationAdvice.revoke(
            deviceMarker: peer.deviceMarker, deviceFingerprint: deviceKey.fingerprint
        )
        return ToolFailure("""
            \(error)
            This device's key is still on \(peer.name), and \(peer.name) is still listed here.
            On that machine, run: \(advice.command)\(advice.detail.map { "\n\($0)" } ?? "")
            """)
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
            print("  key on host \(peer.deviceMarker ?? "not recorded")")
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

    /// The stored key, or nil when there is none.
    ///
    /// Separate from `loadOrCreate` because minting one is right exactly once —
    /// when redeeming a pairing — and wrong everywhere else. `bleat unpair`
    /// with a missing key file would otherwise create a *different* key,
    /// authenticate with it, be refused, and report that the host "no longer
    /// accepts this device's key … it has probably already been removed
    /// there" — the opposite of the truth, since the real key is still
    /// authorised. It would have overwritten that key's identity on the way.
    func load() throws -> SSHKeyPair? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try SSHKeyPair(rawRepresentation: data)
    }

    func loadOrCreate() throws -> SSHKeyPair {
        if let existing = try load() { return existing }
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
