import BleatKit
import SwiftUI

/// Adds an address for a host that detection cannot find.
///
/// The backstop under the other two ways a peer learns where it answers. Pairing
/// enumerates what the host can see about itself, and a refresh asks it again on
/// every connection — but neither can produce an address the host does not know
/// it has. A zero-trust overlay is the motivating case: it routes the *client*
/// to a resource by a private DNS name held entirely on the client's side, so
/// there is nothing on the host to discover and no amount of asking will find
/// it.
///
/// It also covers what has no discovery story at all — a port forward, a jump
/// address, or a Mac that has moved somewhere the phone cannot reach until it is
/// told where to look.
struct AddEndpointView: View {
    @Environment(AppContext.self) private var context
    @Environment(\.dismiss) private var dismiss
    let peer: PairedPeer

    @State private var text = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("host, host:port, or [v6]:port", text: $text)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(add)
                        // Or the red row keeps naming the address the user has
                        // just finished editing away from.
                        .onChange(of: text) { failure = nil }
                        // Both are UIKit-only, and both matter here rather than
                        // being polish: an autocapitalised first letter makes
                        // an address that will not resolve, and the prose
                        // keyboard buries the `.` and `:` this field is almost
                        // entirely made of. `BleatUI` carries platform branches
                        // where `BleatKit` may not — `PairingView` has the same
                        // one for the navigation title.
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } footer: {
                    // Naming the default is not pedantry: every stored endpoint
                    // for this peer is on one port, and an address typed
                    // without one silently inheriting 22 on a host running sshd
                    // elsewhere produces an entry that looks right in the list
                    // and refuses every connection.
                    Text("Port \(defaultPort) unless you give one. Bleat still checks the host key, so an address that reaches the wrong machine is refused rather than trusted.")
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add an address")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(parsed == nil)
                }
            }
            .onAppear { focused = true }
        }
    }

    /// The port the peer's other addresses use, not 22.
    ///
    /// `Endpoint(string:)` defaults to 22, which is right for a bare parse and
    /// wrong here: a host reached on 2222 whose new address was stored on 22
    /// gains an entry that will never connect, next to ones that do.
    private var defaultPort: Int {
        peer.lastGoodEndpoint?.port ?? peer.endpoints.first?.port ?? Endpoint.defaultPort
    }

    /// Parsed on every keystroke rather than on submit, so "Add" is disabled
    /// until there is something to add — which is a quieter way to say "that is
    /// not an address" than an error after the fact.
    ///
    /// **`Endpoint(string:)` alone is not enough**, because it is a parser and
    /// not a validator: anything without a colon becomes a hostname verbatim,
    /// so `ravil@mac.internal` — a very natural paste — `ssh mac.local` and
    /// `mac.local/foo` would all enable the button and be stored. And an
    /// address added here is permanently sticky, since detection can never
    /// report it: it would be dialled in every race from then on, costing a
    /// connect timeout each time and inflating the count in the message that
    /// explains the failure. `Endpoint.isPlausibleHost` is the second half.
    private var parsed: Endpoint? {
        guard let endpoint = Endpoint(string: text, defaultPort: defaultPort),
              Endpoint.isPlausibleHost(endpoint.host)
        else { return nil }
        return endpoint
    }

    private func add() {
        guard let endpoint = parsed else { return }
        // `Endpoint` lower-cases its host, so this catches `RawillkAir.local`
        // against a stored `rawillkair.local` — which DNS treats as one machine
        // and `Hashable` would not.
        guard !peer.endpoints.contains(endpoint) else {
            failure = "\(endpoint) is already on the list."
            return
        }
        guard context.peers.addEndpoint(endpoint, to: peer) else {
            failure = "Could not save that address."
            return
        }
        dismiss()
    }
}

#if DEBUG
/// On `.sampleData`, so "Add" writes to a throwaway registry in the temporary
/// directory. The previous version of this preview built a plain `PeerStore()`,
/// which is the **real** one — `applicationSupport()` — so tapping Add in the
/// canvas edited the device's own peer list.
#Preview("Add an address", traits: .sampleData) {
    AddEndpointView(peer: .preview)
}

/// The peer whose sshd is on 2222: the footer has to name *that* port, not 22.
/// An address typed without one and silently stored on 22 looks right in the
/// list and refuses every connection.
#Preview("Non-default port", traits: .sampleData) {
    AddEndpointView(peer: .previewOverlayOnly)
}
#endif
