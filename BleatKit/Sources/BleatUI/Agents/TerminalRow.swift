import BleatKit
import SwiftUI

/// One pane with no agent in it — a plain shell on the host.
///
/// Deliberately quieter than `AgentRow`: an agent row leads with a state that
/// may need a person, and a shell is never waiting on one.
struct TerminalRow: View {
    let pane: Pane

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(pane.displayTitle)
                    .lineLimit(1)
                    // A shell titles itself with where it is, so the front of
                    // that string is `user@host:` and the end is the part that
                    // says which shell this is.
                    .truncationMode(.head)
                if let directory {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } icon: {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.displayTitle), terminal")
    }

    /// Where the pane is working, shown **only when the title does not already
    /// say it**.
    ///
    /// A login shell's title is its own directory — `ravil@rawillkair:~/
    /// Developer/link-apple` in `Fixtures/pane-list.json` — so the path
    /// underneath would repeat the line above it for every idle shell. When
    /// something is running the title is that command instead, and then the
    /// directory is the thing that says which shell it is running in.
    private var directory: String? {
        guard let path = pane.foregroundCwd ?? pane.cwd, !path.isEmpty else { return nil }
        guard let leaf = path.split(separator: "/").last,
              !pane.displayTitle.hasSuffix(leaf) else { return nil }
        return path
    }
}

#if DEBUG
/// The two shapes a shell takes: titled with its own directory, which is every
/// idle shell, and titled with a running command, which is when the path below
/// earns its place.
#Preview("Terminals", traits: .sampleData) {
    List {
        ForEach(Pane.samples) { pane in
            TerminalRow(pane: pane)
        }
    }
}

#Preview("Narrow", traits: .sampleData) {
    List {
        ForEach(Pane.samples) { pane in
            TerminalRow(pane: pane)
        }
    }
    .frame(width: 260)
}
#endif
