import BleatKit
import Observation

/// The paired hosts, as the UI sees them, plus the key this device pairs with.
///
/// Wraps `PeerRegistry` (the file) and `KeychainKeyStore` (the key) rather than
/// re-implementing either, so the phone and the console tool agree on the
/// format of a peer record. The naming pair is the same one `HostRegistry` and
/// the old `HostStore` used: registry is the file, store is the observable.
///
/// It replaces the manual host list. That list existed because there was no way
/// to acquire a host except by typing one in; pairing is the way now, and the
/// product promise is zero host setup beyond Herdr.
@Observable
public final class PeerStore {
    public private(set) var peers: [PairedPeer] = []
    /// Set when loading or saving failed, for a view to surface. Nothing here
    /// throws into a view body.
    public private(set) var failure: String?

    private let registry: PeerRegistry
    private let keys: KeychainKeyStore

    public init(
        registry: PeerRegistry = .standard(),
        keys: KeychainKeyStore = KeychainKeyStore()
    ) {
        self.registry = registry
        self.keys = keys
    }

    public func reload() {
        do {
            peers = try registry.all()
            failure = nil
        } catch {
            // Deliberately not `peers = []`: an unreadable file is a reason to
            // say so, not a reason to tell the user their hosts are gone.
            failure = String(describing: error)
        }
    }

    public func remove(_ peer: PairedPeer) {
        do {
            try registry.remove(hostKey: peer.hostKey)
            reload()
        } catch {
            failure = String(describing: error)
        }
    }

    /// Pairs with a scanned code and records what came back.
    ///
    /// `PairingClient.pair` is `nonisolated async`, so the SSH work runs off the
    /// main actor; only the reload afterwards is back here.
    ///
    /// - Throws: `PairingError`, which every case of describes itself well
    ///   enough to show the user directly.
    public func pair(withCode code: String) async throws -> PairedPeer {
        guard let deviceKey = deviceKey() else {
            throw PairingError.enrollmentIncomplete(
                failure ?? "this device has no key to offer"
            )
        }
        let client = PairingClient(peers: registry, deviceKey: deviceKey)
        let peer = try await client.pair(withCode: code)
        reload()
        return peer
    }

    // MARK: - Device key

    /// The device's key, created on first read.
    ///
    /// Returns nil only if the Keychain itself failed, which is worth showing
    /// rather than retrying silently — without a key nothing can pair.
    public func deviceKey() -> SSHKeyPair? {
        do {
            let pair = try keys.loadOrCreate()
            failure = nil
            return pair
        } catch {
            failure = String(describing: error)
            return nil
        }
    }
}
