import BleatKit
import SwiftUI

/// What unpairing looks like while it works, and when it cannot.
///
/// The failure is the reason this is a sheet rather than an alert. An alert
/// gives a sentence and two buttons; what a user needs here is a command they
/// can read and copy, an explanation of what is still true if they do not run
/// it, and a way out that names what it leaves behind.
struct UnpairSheet: View {
    let model: UnpairModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .working(let peer):
                    working(peer)
                case .keyRemains(let peer, let reason, let advice):
                    remains(peer, reason: reason, advice: advice)
                case .hostRefusedKey(let peer, let advice):
                    refused(peer, advice: advice)
                case .idle, .confirming:
                    // Reachable for one frame as the sheet dismisses.
                    ProgressView()
                }
            }
            .navigationTitle("Unpair")
            .navigationBarTitleDisplayModeInline()
        }
        // The work must not be abandoned half-done: the key is either off the
        // host or it is not, and a swipe-away during the removal would leave
        // the user with no idea which.
        .interactiveDismissDisabled(model.isWorking)
    }

    private func working(_ peer: PairedPeer) -> some View {
        ContentUnavailableView {
            ProgressView()
        } description: {
            Text("Removing this device's key from \(peer.name).")
        }
    }

    /// The host was reached and would not accept this key.
    ///
    /// Both readings are stated, because only one of them is good news and the
    /// app cannot tell which it is. Saying "the key is still there" would be a
    /// guess, and probably the wrong one.
    private func refused(_ peer: PairedPeer, advice: RevocationAdvice) -> some View {
        List {
            Section {
                Label {
                    Text("\(peer.name) no longer accepts this device's key.")
                } icon: {
                    Image(systemName: "lock.slash")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Most likely the key has already been removed there, in which case there is "
                     + "nothing left to do. It could also still be in that Mac's authorized_keys "
                     + "with sshd refusing it for another reason — a permissions change on ~/.ssh, "
                     + "or an SSH configuration that no longer allows this login.")
            }

            Section("Check on \(peer.name)") {
                Text(advice.command)
                    .font(.footnote.monospaced())
                    .selectable()
                if let detail = advice.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Pasteboard.copy(advice.command)
                } label: {
                    Label("Copy command", systemImage: "doc.on.doc")
                }
            }

            Section {
                // Keeping it comes first. Forgetting is the right outcome when
                // the key really is gone, but "sshd refused us" has transient
                // readings too, and the destructive choice should not be the
                // one under the thumb.
                Button("Keep it listed") { model.cancel() }
                // Not "forget without removing the key": if the key has gone,
                // there is nothing being left behind to name.
                Button("Forget \(peer.name)", role: .destructive) {
                    model.forgetWithoutRevoking()
                }
            } footer: {
                Text("Check first if you can. Forgetting is right once the key is gone, "
                     + "and premature if it is not.")
            }
        }
    }

    private func remains(
        _ peer: PairedPeer,
        reason: String,
        advice: RevocationAdvice
    ) -> some View {
        List {
            Section {
                Label {
                    // Stated as what is still true, not as what failed. "Could
                    // not connect" invites a shrug; "this phone can still log
                    // in" is the fact the user has to act on.
                    Text("This device's key is still on \(peer.name), so this phone can still log in there.")
                } icon: {
                    Image(systemName: "key.slash")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(reason)
            }

            Section("Remove it on \(peer.name)") {
                Text(advice.command)
                    .font(.footnote.monospaced())
                    .selectable()
                if let detail = advice.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Pasteboard.copy(advice.command)
                } label: {
                    Label("Copy command", systemImage: "doc.on.doc")
                }
            }

            Section {
                Button {
                    Task { await model.unpair(peer) }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                Button("Keep paired") { model.cancel() }
            }

            Section {
                // Named for what it leaves behind rather than "Unpair anyway".
                // It is the honest label, and it is the third button on a
                // screen that has already shown the command that finishes the
                // job — which is the order that matters, since forgetting the
                // peer discards the marker the command names.
                Button("Forget without removing the key", role: .destructive) {
                    model.forgetWithoutRevoking()
                }
            } footer: {
                Text("Bleat will stop listing \(peer.name). The key stays on that Mac until you remove it.")
            }
        }
    }
}

private extension View {
    /// `.navigationBarTitleDisplayMode` is iOS-only and `BleatUI` builds for
    /// macOS too, so the branch lives here rather than in the middle of a body.
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if DEBUG
#Preview("Removing the key", traits: .sampleData) {
    UnpairSheet(model: UnpairModel(previewing: .working(.preview)))
}

/// The host could not be reached, so the key is still there and this phone can
/// still log in. Stated as what is true, not as what failed.
#Preview("Key remains", traits: .sampleData) {
    UnpairSheet(model: UnpairModel(previewing: .keyRemains(
        .preview,
        reason: "none of 3 addresses could be reached",
        advice: .revoke(deviceMarker: PairedPeer.preview.deviceMarker, deviceFingerprint: nil)
    )))
}

/// No marker on the record, so the advice falls back to `bleat keys list` plus
/// a fingerprint to match by eye.
#Preview("Key remains, no marker", traits: .sampleData) {
    UnpairSheet(model: UnpairModel(previewing: .keyRemains(
        .previewSparse,
        reason: "the host closed the connection",
        advice: .revoke(
            deviceMarker: nil,
            deviceFingerprint: "SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78"
        )
    )))
}

/// Reached and refused — the case where the advice inverts, because the
/// likeliest reading is that the key has already gone.
#Preview("Host refused the key", traits: .sampleData) {
    UnpairSheet(model: UnpairModel(previewing: .hostRefusedKey(
        .preview,
        advice: .check(deviceMarker: PairedPeer.preview.deviceMarker, deviceFingerprint: nil)
    )))
}
#endif
