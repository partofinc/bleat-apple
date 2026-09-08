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
/// - and the cwd it reports back is **canonical** — `/tmp` comes back
///   `/private/tmp` — so comparing the reply against what the user typed would
///   call a correctly-placed workspace misplaced.
///
/// So three checks, in the order that costs the user least: the shape refused
/// while they type (`WorkspaceDirectory`); the path **resolved by the host**
/// before anything is created, which answers both "is it there" and "what is it
/// really" (`DirectoryCheck`); and the reply compared against that resolved
/// form (`WorkspaceCreated.openedElsewhere`). The first two are what stop a
/// wrong workspace being made at all; the third only catches a race, and exists
/// because "created it, somewhere else" is not a thing the user should have to
/// notice for themselves.
///
/// A fourth check sits on the failure path, and it is the one that is easy to
/// skip: a create that *threw* is not proof that nothing happened. See
/// `settle(_:since:on:)`.
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
    /// Nothing was created, and this is why. Safe to try again.
    private(set) var failure: String?
    /// **The attempt is over and pressing again would make things worse.**
    /// Either a workspace was created somewhere other than where it was asked
    /// to go, or the connection dropped in the window where it may or may not
    /// have been created at all. Kept apart from `failure` because the remedy
    /// is opposite: something may exist on the host to deal with, so the button
    /// must not invite a second one.
    private(set) var warning: String?
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
        warning: String? = nil,
        isCreating: Bool = false,
        suggestions: [String] = []
    ) {
        self.connections = nil
        self.session = nil
        self.path = path
        self.label = label
        self.failure = failure
        self.warning = warning
        self.isCreating = isCreating
        self.suggestions = suggestions
    }
    #endif

    enum Outcome: Equatable {
        case created
        /// Something may now exist on the host that the user has to be told
        /// about — made in the wrong place, or made-or-not behind a dropped
        /// connection. The list still needs refreshing either way; the screen
        /// stays up, because it is the only thing that will say so.
        case warned
        /// Nothing was created. Safe to try again.
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

    /// False once the attempt has settled into something a retry would only
    /// make worse — see `warning`.
    var canCreate: Bool { directory != nil && !isCreating && warning == nil }

    /// A failure is about the attempt that produced it; left standing while the
    /// user edits the path it reads as a verdict on the new one.
    ///
    /// Deliberately does **not** clear `warning`: that one says something may
    /// exist on the host, which editing a text field does not undo.
    /// `reset()` is what ends that state, and only on a deliberate reopen.
    func clearFailure() { failure = nil }

    /// Back to an empty form.
    ///
    /// **Called when the sheet is opened, and the sheet outlives it.** The model
    /// is `@State` on the screen rather than on the sheet — deliberately, so an
    /// in-flight create survives a dismissal — which means every field lives
    /// until the screen is popped. Without this, one "landed elsewhere" left
    /// `warning` set forever: reopening showed a stale message about a
    /// workspace made minutes ago, `canCreate` stayed false and the button read
    /// "Done", and nothing on the screen could clear it. The path and label go
    /// too, or a reopened sheet comes up prefilled with the last one and armed,
    /// where one reflexive tap makes a second workspace at the same path.
    func reset() {
        path = ""
        label = ""
        failure = nil
        warning = nil
    }

    /// Directories the host is already using, from `pane list`.
    ///
    /// The phone has no file browser and typing an absolute path on one is
    /// miserable, but the host has already told us which directories its panes
    /// are in — so the list that matters is free. Best effort as far as the
    /// *user* is concerned: a failure leaves a field to type into, which is
    /// what it would have been anyway, and an error message about a convenience
    /// is worse than no convenience.
    ///
    /// **It is not best effort as far as the connection is concerned.** This is
    /// the first thing the sheet does, so a connection that has gone fatally
    /// bad — the phone changed network since it was raced — fails here first;
    /// swallowing that leaves it installed, and the user's Create then spends
    /// another failure discovering the same thing. `ConnectionStore.handle` is
    /// what drops it, and every other call site in the app calls it on the
    /// first failure.
    func loadSuggestions(for peer: PairedPeer) async {
        guard let connections else { return }
        do {
            let client = try await connections.client(for: peer, session: session)
            suggestions = Set(try await client.panes().compactMap(\.cwd)).sorted()
        } catch {
            await connections.handle(error)
        }
    }

    /// Resolves the directory on the host, creates, then checks where it landed.
    ///
    /// Three round trips, and each one answers something herdr will not tell us
    /// afterwards. The order matters: everything that can refuse the attempt
    /// happens before anything is made.
    func create(on peer: PairedPeer) async -> Outcome {
        guard let connections, let typed = directory, !isCreating else { return .failed }
        isCreating = true
        failure = nil
        defer { isCreating = false }

        do {
            // **Before anything is created**, and it settles two questions at
            // once. herdr accepts a path that is not there and quietly uses the
            // home directory instead; and the cwd it reports back is canonical,
            // so `/tmp` returns as `/private/tmp` and a phone comparing its own
            // string would call a correctly-placed workspace misplaced. Asking
            // the host to resolve it is the same resolution herdr does.
            //
            // Plain shell, so it leaves the session prefix alone — the
            // workspaces list on the screen behind depends on it.
            let shell = try await connections.shell(for: peer)
            let answer = try await shell.run(shell: DirectoryCheck.command(for: typed))
            guard let resolvedPath = DirectoryCheck.resolvedPath(inOutput: answer),
                  let resolved = WorkspaceDirectory(resolvedPath)
            else {
                // Names what the user typed rather than what the host resolved
                // — there is no resolved form, and echoing their own path back
                // is what lets them see the typo.
                failure = "There is no directory at \(typed.path) on this host."
                return .failed
            }

            let client = try await connections.client(for: peer, session: session)
            // **What the host has before the write**, for the same reason
            // `SessionStarter` reads `session list` first: afterwards it is the
            // only way to tell "it did not happen" from "the answer never came
            // back".
            let before = Set(try await client.workspaces().map(\.workspaceID))

            // The inner catch is where the nesting earns its place: everything
            // above is a read, so a failure there means nothing was created and
            // trying again is safe. Only this call can fail with a workspace on
            // the host.
            do {
                let created = try await client.createWorkspace(in: resolved, label: label)
                if let actual = created.openedElsewhere(than: resolved) {
                    warning = "Created \(created.workspace.label), but its pane opened in "
                        + "\(actual) rather than \(resolved.path)."
                    return .warned
                }
                return .created
            } catch {
                await connections.handle(error)
                return await settle(error, since: before, on: peer)
            }
        } catch {
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
            return .failed
        }
    }

    /// What to say when the create itself threw.
    ///
    /// **A failure is not proof that nothing happened.** If the connection
    /// drops between herdr running `workspace create` and the reply arriving,
    /// the command still ran — and reporting a plain failure invites the
    /// obvious response, which makes a second workspace on someone's Mac. Every
    /// other write in this app reads back rather than trusting a reply
    /// (`SessionStarter` polls `session list`, `bleat keys revoke` re-reads the
    /// file); this is that read.
    ///
    /// Three answers, and the third is why this is not a one-liner: the
    /// read-back can itself fail, and "I cannot tell" has to disarm rather than
    /// re-arm.
    private func settle(
        _ error: any Error,
        since before: Set<String>,
        on peer: PairedPeer
    ) async -> Outcome {
        let message = ErrorMessage.failure(of: error).message
        guard let connections,
              let client = try? await connections.client(for: peer, session: session),
              let now = try? await client.workspaces()
        else {
            warning = "\(message)\n\nThe workspace may or may not have been created — "
                + "pull the list down to see."
            return .warned
        }
        guard let landed = now.first(where: { !before.contains($0.workspaceID) }) else {
            // The host answered and has nothing new, so nothing was created and
            // trying again is safe.
            failure = message
            return .failed
        }
        warning = "\(message)\n\nThe workspace was created anyway, as \(landed.label)."
        return .warned
    }
}
