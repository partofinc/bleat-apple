import BleatKit
import SwiftUI

/// Terminals grouped by Herdr.app's spaces, most urgent space first.
///
/// The space is the first half of the `where` label (`"nuvio-health / Agent"`).
/// A host Herdr.app never touched — a Pi, the demo host — has no such label,
/// and its terminals are one section with no header.
struct TerminalsList: View {
    let terminals: [HcTerminal]

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.terminals) { terminal in
                        HcTerminalRow(terminal: terminal)
                    }
                } header: {
                    if !section.title.isEmpty { Text(section.title) }
                }
            }
        }
    }

    private struct Group {
        let title: String
        let terminals: [HcTerminal]
    }

    /// `terminals` arrives sorted by attention, and grouping keeps that order
    /// inside each space; spaces are ordered by their most urgent terminal,
    /// then by name.
    private var sections: [Group] {
        let grouped = Dictionary(grouping: terminals) { $0.location?.space ?? "" }
        return grouped
            .map { Group(title: $0.key, terminals: $0.value) }
            .sorted { lhs, rhs in
                let left = lhs.terminals.first?.attention ?? .max
                let right = rhs.terminals.first?.attention ?? .max
                return left == right ? lhs.title < rhs.title : left < right
            }
    }
}

#if DEBUG
#Preview("Spaces", traits: .sampleData) {
    NavigationStack {
        TerminalsList(terminals: HcTerminal.samples.sortedByAttention())
            .navigationTitle("kestrel.air")
    }
}

#Preview("A Pi, no spaces", traits: .sampleData) {
    NavigationStack {
        TerminalsList(terminals: HcTerminal.samplesWithoutSpaces)
            .navigationTitle("adam")
    }
}
#endif
