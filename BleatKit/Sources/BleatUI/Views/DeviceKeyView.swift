import BleatKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Shows the public half of the device key, to install on the host.
///
/// The private half is generated on device and never leaves it, so this screen
/// is the whole of the key exchange.
struct DeviceKeyView: View {
    @Environment(AppContext.self) private var context
    @Environment(\.dismiss) private var dismiss

    /// Resolved once in `.task`, never in `body`.
    ///
    /// Reading the key writes `HostStore.failure`, and `@Observable` notifies on
    /// every set with no equality check — so calling it from `body` invalidated
    /// `HostsView`, which re-evaluated this sheet, which read the key again.
    /// That spun, with a blocking Keychain call each pass.
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
                let resolved = context.hosts.deviceKey()
                key = resolved
                failure = context.hosts.failure
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

    /// BleatUI builds for macOS as well as iOS, so the pasteboard is the one
    /// place this target needs a platform branch — and it needs *both* arms,
    /// or the button silently does nothing on one of them.
    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
