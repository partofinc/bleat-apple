import BleatKit
import SwiftUI

/// Terminals grouped by Herdr.app's spaces, most urgent space first.
///
/// The space is the first half of the `where` label (`"nuvio-health / Agent"`).
/// A host Herdr.app never touched — a Pi, the demo host — has no such label,
/// and its terminals are one section with no header.
struct TerminalsList: View {
    /// The host's key, which a row's route carries.
    let hostKey: String
    let terminals: [HcTerminal]

    var body: some View {
        List {
            TerminalSections(hostKey: hostKey, terminals: terminals)
        }
    }
}

#if DEBUG
#Preview("Spaces", traits: .sampleData) {
    NavigationStack {
        TerminalsList(hostKey: PairedPeer.preview.hostKey, terminals: HcTerminal.samples.sortedByAttention())
            .navigationTitle("kestrel.air")
    }
}

#Preview("A Pi, no spaces", traits: .sampleData) {
    NavigationStack {
        TerminalsList(hostKey: PairedPeer.preview.hostKey, terminals: HcTerminal.samplesWithoutSpaces)
            .navigationTitle("adam")
    }
}
#endif
