import BleatKit
import Observation

/// Saved hosts and the device key, as the UI sees them.
///
/// Wraps the file-backed `HostRegistry` and the Keychain rather than
/// re-implementing either: the console tool and the app agree on the format,
/// so a host added on the Mac is the same record the phone reads.
@Observable
public final class HostStore {
    public private(set) var hosts: [HostEntry] = []
    /// Set when loading or saving failed, for the view to surface. Nothing here
    /// throws into a view body.
    public private(set) var failure: String?

    private let registry: HostRegistry
    private let keys: KeychainKeyStore

    public init(
        registry: HostRegistry = .standard(),
        keys: KeychainKeyStore = KeychainKeyStore()
    ) {
        self.registry = registry
        self.keys = keys
    }

    public func reload() {
        do {
            hosts = try registry.all()
            failure = nil
        } catch {
            hosts = []
            failure = String(describing: error)
        }
    }

    public func add(_ entry: HostEntry) {
        do {
            try registry.save(entry)
            reload()
        } catch {
            failure = String(describing: error)
        }
    }

    public func remove(_ entry: HostEntry) {
        do {
            _ = try registry.remove(named: entry.name)
            reload()
        } catch {
            failure = String(describing: error)
        }
    }

    // MARK: - Device key

    /// The device's key, created on first read.
    ///
    /// Returns nil only if the Keychain itself failed, which is worth showing
    /// rather than retrying silently — without a key nothing can connect.
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
