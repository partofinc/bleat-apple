import BleatKit
import SwiftUI

/// Shows the public half of the device key, to install on the host.
///
/// The private half is generated on device and never leaves it, so this screen
/// is the whole of the key exchange.
struct DeviceKeyView: View {
    @Environment(AppContext.self) private var context
    @Environment(\.dismiss) private var dismiss

    /// Resolved once in `.task`, never in `body`.
    ///
    /// Reading the key used to write a shared `failure` property, and
    /// `@Observable` notifies on every set with no equality check — so calling
    /// it from `body` invalidated the list behind this sheet, which
    /// re-evaluated the sheet, which read the key again. That spun, with a
    /// blocking Keychain call each pass. The key no longer writes shared state,
    /// but a Keychain read still belongs off the body.
    @State private var key: SSHKeyPair?
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let key {
                    content(for: key)
                } else if loaded {
                    ContentUnavailableView(
                        "No key",
                        systemImage: "key.slash",
                        description: Text(failure ?? "The keychain is unavailable.")
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Device key")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !loaded else { return }
                do {
                    key = try context.peers.deviceKey()
                } catch {
                    failure = String(describing: error)
                }
                loaded = true
            }
        }
    }

    @ViewBuilder
    private func content(for key: SSHKeyPair) -> some View {
        let line = key.authorizedKeyLine()
        List {
            Section("Fingerprint") {
                // Matches `ssh-keygen -l` exactly, so it can be compared by eye
                // against what the host reports.
                Text(key.fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Section("Public key") {
                Text(line)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button {
                    Pasteboard.copy(line)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Section {
                Text("On the host:\n\necho '\(line)' >> ~/.ssh/authorized_keys")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

#if DEBUG
/// Reads the real Keychain, which on a simulator means it mints a preview-only
/// device key on first run. That is the honest preview: the fingerprint is the
/// thing being compared by eye against `bleat keys list`, and a fabricated one
/// would not be the same shape as a real one.
#Preview("Device key", traits: .sampleData) {
    DeviceKeyView()
}
#endif
