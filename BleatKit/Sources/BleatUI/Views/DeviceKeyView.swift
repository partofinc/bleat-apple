import BleatKit
import SwiftUI
/// Shows the public half of the device key, to install on the host.
///
/// The private half is generated on device and never leaves it, so this screen
/// is the whole of the key exchange.
struct DeviceKeyView: View {
    @Environment(AppContext.self) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let key = context.hosts.deviceKey() {
                    content(for: key)
                } else {
                    ContentUnavailableView(
                        "No key",
                        systemImage: "key.slash",
                        description: Text(context.hosts.failure ?? "The keychain is unavailable.")
                    )
                }
            }
            .navigationTitle("Device key")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
                    copy(line)
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

    /// BleatUI builds for macOS too (the package does), so the pasteboard is
    /// the one place this target needs a platform branch.
    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
