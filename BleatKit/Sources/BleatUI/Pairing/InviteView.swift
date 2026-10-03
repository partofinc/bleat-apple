#if !os(watchOS)
import BleatKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows a pairing code for another device, from this one.
///
/// What `bleat pair` draws in a terminal, drawn here: the code, the host key it
/// pins, and how long it lasts. Closing the sheet withdraws the code.
struct InviteView: View {
    @Environment(AppContext.self) private var context
    @Environment(\.dismiss) private var dismiss
    let peer: PairedPeer
    @State private var model = InviteModel()
    /// Set by a preview, which must not reach a host: the code is drawn from
    /// this instead of from a key installed over the network.
    private var previewing: InviteModel.Phase?
    /// Bumped to show a fresh code after one expired or failed; the `.task`
    /// is keyed on it.
    @State private var attempt = 0

    init(peer: PairedPeer) {
        self.peer = peer
    }

    #if DEBUG
    init(peer: PairedPeer, previewing phase: InviteModel.Phase) {
        self.peer = peer
        self.previewing = phase
    }
    #endif

    private var phase: InviteModel.Phase { previewing ?? model.phase }

    private var isShowingCode: Bool {
        if case .showing = phase { true } else { false }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pair another device")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    // Cancel while the code is up, because closing withdraws
                    // it; Done once there is nothing left to withdraw.
                    ToolbarItem(placement: .cancellationAction) {
                        if isShowingCode {
                            Button("Cancel", action: dismiss.callAsFunction)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if !isShowingCode {
                            Button("Done", action: dismiss.callAsFunction)
                        }
                    }
                }
        }
        .task(id: attempt) {
            guard previewing == nil else { return }
            await model.run(
                peer: peer,
                shell: { [context, peer] in try await context.connections.shell(for: peer) },
                handle: { [context] in await context.connections.handle($0) }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .opening:
            ProgressView("Making a one-time key on \(peer.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .showing(let invitation):
            code(invitation)
        case .redeemed:
            ContentUnavailableView {
                Label("Paired", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } description: {
                Text("The other device installed its own key and can log in to \(peer.name) as \(peer.username). The one-time key is gone.")
            }
        case .withdrawn:
            ended(
                "Code removed on \(peer.name)",
                because: "Something on the host removed the one-time key — `bleat pair` run there clears any it finds."
            )
        case .expired:
            ended(
                "Code expired",
                because: "Nobody scanned it in time, and the one-time key has been removed from \(peer.name)."
            )
        case .failed(let message):
            ended("Could not make a code", because: message)
        }
    }

    private func code(_ invitation: Invitation) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                if let link = try? invitation.link() {
                    QRCodeImage(text: link)
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Pairing code for \(peer.name)")

                    Text("On the other device, open Bleat, tap Pair a host, and scan this.")
                        .multilineTextAlignment(.center)

                    // Clamped: the phase is still `.showing` for up to a poll
                    // after the deadline, and a range whose start is past its
                    // end traps.
                    Text("Expires in \(Text(timerInterval: min(Date.now, invitation.deadline)...invitation.deadline, countsDown: true))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        Text("Host key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // The other device shows the same string once it has
                        // paired; comparing them is the check only a person
                        // can make.
                        Text(invitation.payload.hostKeyFingerprint ?? peer.hostKey)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.center)
                            .selectable()
                    }

                    VStack(spacing: 6) {
                        Button("Copy link", systemImage: "doc.on.doc") { Pasteboard.copy(link) }
                        // The link is the code: whoever holds it within the
                        // next few minutes can pair. Said where the button is.
                        Text("For `bleat redeem` on a computer. The link holds the one-time key, so send it only to yourself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding()
        }
    }

    private func ended(_ title: String, because reason: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "qrcode")
        } description: {
            Text(.init(reason))
        } actions: {
            Button("Show a new code") { attempt += 1 }
        }
    }
}

/// A QR code drawn module for module: no smoothing, and a white margin the
/// width of the spec's quiet zone so a camera finds it on a dark screen.
private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(16)
                .background(.white, in: .rect(cornerRadius: 12))
        }
    }

    /// Correction level M: a phone screen held up to another phone's camera
    /// catches glare that a terminal does not.
    private static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

#if DEBUG
#Preview("Code", traits: .sampleData) {
    InviteView(peer: .preview, previewing: .showing(.preview))
}

#Preview("Paired", traits: .sampleData) {
    InviteView(peer: .preview, previewing: .redeemed)
}

#Preview("Expired", traits: .sampleData) {
    InviteView(peer: .preview, previewing: .expired)
}
#endif
#endif
