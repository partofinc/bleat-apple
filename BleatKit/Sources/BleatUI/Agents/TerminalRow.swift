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
                if let directory = Self.directory(for: pane) {
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
    /// A login shell's title is its own directory — `robin@studio-mac:~/
    /// Developer/link-apple` in `Fixtures/pane-list.json` — so the path
    /// underneath would repeat the line above it for every idle shell. When
    /// something is running the title is that command instead, and then the
    /// directory is the thing that says which shell it is running in.
    ///
    /// **The comparison is between path *segments*, not a plain suffix**, and
    /// both halves of that were wrong in the first version. The title's last
    /// segment is taken after the final `/` **or `:`**, so `git log` run in
    /// `/var/log` no longer reads as the title repeating the directory. And a
    /// shell sitting in the home directory titles itself `user@host:~` against
    /// a `cwd` of `/Users/robin`, which matches nothing by name — that is the
    /// shape every session the phone starts has, since its one workspace is the
    /// SSH user's home, so `~` is taken as saying the same thing.
    ///
    /// Static and internal so `TerminalRowTests` can hold it to those cases. A
    /// rule this fiddly is not worth having if nothing checks it.
    static func directory(for pane: Pane) -> String? {
        guard let path = pane.foregroundCwd ?? pane.cwd, !path.isEmpty else { return nil }
        guard let titled = pane.displayTitle
            .split(whereSeparator: { $0 == "/" || $0 == ":" }).last
        else { return path }
        // A title of `~` describes the *shell's* own directory, so it only
        // speaks for the line below when nothing has moved: a foreground
        // process reporting somewhere else is exactly the case the path is
        // worth drawing for.
        if titled == "~" {
            guard let shell = pane.cwd, let foreground = pane.foregroundCwd,
                  shell != foreground
            else { return nil }
            return foreground
        }
        guard titled != path.split(separator: "/").last else { return nil }
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
