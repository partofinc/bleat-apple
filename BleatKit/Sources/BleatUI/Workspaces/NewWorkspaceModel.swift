import BleatKit
import Foundation
import Observation

/// Making a workspace in a session, from the phone.
///
/// A workspace is a directory plus a label, and herdr hands it a tab and a pane
/// running a shell — see `WorkspaceCreated`. Nothing is ended and no pane that
/// already exists is touched, so unlike stopping a session this needs no
/// ownership claim and no confirmation. What it does need is to be **right
/// about where it lands**, because herdr is not:
///
/// - `--cwd /no/such/dir` is accepted, reported as a success, and opens the
///   pane in the home directory instead. Measured.
/// - a relative path is resolved against the *server process's* working
///   directory, which from a phone is unknowable.
///
/// So three checks, in the order that costs the user least: the shape refused
/// while they type (`WorkspaceDirectory`), the existence asked of the host
/// before anything is created (`DirectoryCheck`), and the reply compared
/// against what was asked for (`WorkspaceCreated.openedElsewhere`). The first
/// two are what stop a wrong workspace being made at all; the third only
/// catches a race, and exists because "created it, somewhere else" is not a
/// thing the user should have to notice for themselves.
@Observable
@MainActor
final class NewWorkspaceModel {
    /// Bound to the field. Not `private(set)`: the text field owns it.
    var path = ""
    /// Also bound. Empty means "whatever herdr would call it", which is the
    /// basename — `labelPlaceholder` shows that rather than leaving the field
    /// blank and unexplained.
    var label = ""
    private(set) var isCreating = false
    /// Nothing was created, and this is why.
    private(set) var failure: String?
    /// Something *was* created, in the wrong place. Kept apart from `failure`
    /// because the remedy is opposite: there is now a workspace on the host to
    /// deal with rather than an attempt to repeat.
    private(set) var misplaced: String?
    /// Directories already in use on the host, so the common case is a tap.
    private(set) var suggestions: [String] = []

    private let connections: ConnectionStore?
    private let session: String?

    init(connections: ConnectionStore, session: String?) {
        self.connections = connections
        self.session = session
    }

    #if DEBUG
    /// Parked, for `#Preview`: nothing dials and nothing is created.
    init(
        previewing path: String,
        label: String = "",
        failure: String? = nil,
        misplaced: String? = nil,
        isCreating: Bool = false,
        suggestions: [String] = []
    ) {
        self.connections = nil
        self.session = nil
        self.path = path
        self.label = label
        self.failure = failure
        self.misplaced = misplaced
        self.isCreating = isCreating
        self.suggestions = suggestions
    }
    #endif

    enum Outcome: Equatable {
        case created
        /// Made, but not where it was asked to go. The list still needs
        /// refreshing; the screen still needs to say so.
        case createdElsewhere
        case failed
    }

    /// The directory as typed, if it is one at all.
    var directory: WorkspaceDirectory? { WorkspaceDirectory(path) }

    /// What is wrong with the path as typed, or nil.
    ///
    /// Nil while the field is empty as well as while it is valid: an empty
    /// field is the resting state, not an error to shout about.
    var pathProblem: String? {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty,
              let problem = WorkspaceDirectory.problem(with: path)
        else { return nil }
        return problem.message
    }

    /// herdr's own default for an omitted label, so the field is not silent
    /// about what leaving it blank will do.
    var labelPlaceholder: String { directory?.suggestedLabel ?? "Label" }

    /// False once something has been created, whether or not it landed where it
    /// was asked: the button has done its work, and tapping again would make a
    /// second workspace.
    var canCreate: Bool { directory != nil && !isCreating && misplaced == nil }

    func clearFailure() { failure = nil }

    /// Directories the host is already using, from `pane list`.
    ///
    /// The phone has no file browser and typing an absolute path on one is
    /// miserable, but the host has already told us which directories its panes
    /// are in — so the list that matters is free. Best effort: a failure leaves
    /// the field to be typed into, which is what it would have been anyway, and
    /// reporting it would be an error message about a convenience.
    func loadSuggestions(for peer: PairedPeer) async {
        guard let connections else { return }
        guard let client = try? await connections.client(for: peer, session: session),
              let panes = try? await client.panes()
        else { return }
        suggestions = Set(panes.compactMap(\.cwd)).sorted()
    }

    /// Checks the directory is there, creates, then checks where it landed.
    func create(on peer: PairedPeer) async -> Outcome {
        guard let connections, let directory, !isCreating else { return .failed }
        isCreating = true
        failure = nil
        defer { isCreating = false }

        do {
            // **Before anything is created.** herdr would accept a path that is
            // not there and quietly use the home directory instead, so without
            // this the only honest options are to report a success that is
            // wrong about where the workspace is, or to report the mistake
            // after having made one on someone else's Mac.
            //
            // Plain shell, so it leaves the session prefix alone — the
            // workspaces list on the screen behind depends on it.
            let shell = try await connections.shell(for: peer)
            let answer = try await shell.run(shell: DirectoryCheck.command(for: directory))
            guard DirectoryCheck.exists(inOutput: answer) else {
                failure = "There is no directory at \(directory.path) on this host."
                return .failed
            }

            let client = try await connections.client(for: peer, session: session)
            let created = try await client.createWorkspace(in: directory, label: label)

            if let actual = created.openedElsewhere(than: directory) {
                misplaced = "Created \(created.workspace.label), but its pane opened in "
                    + "\(actual) rather than \(directory.path)."
                return .createdElsewhere
            }
            return .created
        } catch {
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
            return .failed
        }
    }
}
