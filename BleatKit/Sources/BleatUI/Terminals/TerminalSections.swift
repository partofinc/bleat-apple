import BleatKit
import SwiftUI

/// A host's terminals as list sections, one per Herdr.app space, most urgent
/// space first; each row opens the terminal.
///
/// Sections rather than a list, so the phone's list and the watch's — which
/// has the host's load and its own status rows above — group alike.
///
/// The space is the first half of the `where` label (`"nuvio-health / Agent"`).
/// A host Herdr.app never touched — a Pi, the demo host — has no such label,
/// and its terminals are one section, headed `untitled` if given.
struct TerminalSections: View {
    /// The host's key, which a row's route carries.
    let hostKey: String
    let terminals: [HcTerminal]
    /// The header for terminals in no space: none on the phone, "Terminals"
    /// on the watch, where every section is named.
    var untitled: String?

    var body: some View {
        ForEach(sections, id: \.title) { section in
            Section {
                ForEach(section.terminals) { terminal in
                    NavigationLink(value: NavigationRouter.Route.terminal(
                        peer: hostKey, address: terminal.address, title: terminal.displayName
                    )) {
                        HcTerminalRow(terminal: terminal)
                    }
                }
            } header: {
                if let title = section.title.isEmpty ? untitled : section.title { Text(title) }
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
