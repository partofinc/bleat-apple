#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import Foundation

/// `bleat keys` — what this machine still lets in, and how to take it back.
///
/// The other half of pairing, and the half that had nowhere to live. A phone
/// that unpairs drops its own record; it cannot reach the host, and often
/// cannot connect at all by then — a phone that was lost, sold or wiped
/// certainly cannot. So the `bleat-device-…` line stays in
/// `~/.ssh/authorized_keys`, granting a full shell, with nothing on either
/// machine that shows it or removes it.
///
/// Deliberately local-only. Every other command in this tool takes an optional
/// host and reaches it over SSH; this one edits the file that decides who may
/// reach it, and doing that over a channel the file itself authorises is a
/// footgun — revoke the wrong line and the command that would fix it is the one
/// that no longer connects. Run it at the machine, or over a session you did
/// not open with a Bleat key.
enum Keys {
    static func run(options: Options) throws {
        guard let subcommand = options.positional.first else {
            throw ToolFailure("keys needs a subcommand: list, or revoke <marker>")
        }
        let rest = Array(options.positional.dropFirst())

        switch subcommand {
        case "list":
            guard rest.isEmpty else {
                throw ToolFailure("unexpected argument(s): \(rest.joined(separator: " "))")
            }
            try list()
        case "revoke":
            guard !rest.isEmpty else {
                throw ToolFailure("revoke needs a marker, e.g. bleat-device-1a2b3c4d5e6f7a8b\nRun `bleat keys list` to see them.")
            }
            try revoke(rest)
        default:
            throw ToolFailure("unknown keys subcommand '\(subcommand)': expected list or revoke")
        }
    }

    // MARK: - list

    static func list() throws {
        let entries = try read()
        guard !entries.isEmpty else {
            print("No Bleat keys in \(AuthorizedKeys.path).")
            print("Nothing this tool installed is still on this machine.")
            return
        }

        // A block per key rather than a row per key. The three things worth
        // knowing are each long — a 30-character marker, a 50-character
        // fingerprint, a sentence — and on one line they total about 130
        // columns, which wraps on a default terminal and makes the columns
        // meaningless. The fingerprint also earns its own line: comparing it
        // against what the phone shows is the check no software here can do
        // for the user.
        print("Bleat keys in \(AuthorizedKeys.path):\n")
        for entry in entries {
            let kind = entry.kind == .device ? "device" : "enroll"
            print("  \(kind)  \(entry.marker.value)")
            print("          \(entry.fingerprint ?? "the key on this line could not be read")")
            print("          \(note(for: entry))")
            print("")
        }

        // The count is what the user is deciding about, so it is stated rather
        // than left to be counted off the rows.
        let devices = entries.filter { $0.kind == .device }
        if devices.isEmpty {
            print("No paired device can log in with a Bleat key.")
            return
        }
        let count = "\(devices.count) paired device\(devices.count == 1 ? "" : "s")"
        print("\(count) can log in as \(NSUserName()) with a full shell — the same")
        print("access your own key gives.")
        print("")
        print("Unpairing on the phone does not remove that key, and a phone that is")
        print("lost, sold or wiped keeps it. Only this removes it:")
        print("")
        print("  bleat keys revoke \(devices[0].marker.value)")
    }

    /// What is worth saying about one line, beyond its fingerprint.
    ///
    /// An expired enrollment key is the common case here and it is *not* a
    /// problem: sshd has already stopped accepting it, and the next `bleat
    /// pair` sweeps it. Saying so is the difference between a user ignoring a
    /// stale line and a user thinking their machine is open.
    static func note(for entry: AuthorizedKeys.Entry) -> String {
        switch (entry.kind, entry.hasExpired()) {
        case (.device, _):
            return "a paired phone — full shell access"
        case (.enrollment, true?):
            return "expired \(relative(entry.expiresAt)) — sshd already refuses it"
        case (.enrollment, false?):
            return "a pairing in progress — expires \(relative(entry.expiresAt))"
        case (.enrollment, nil):
            // No `expiry-time` at all. Every enrollment line this tool writes
            // carries one, so a line without it was hand-edited or written by
            // something else, and it will never stop working on its own.
            return "no expiry — revoke it"
        }
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "at an unreadable time" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - revoke

    static func revoke(_ markers: [String]) throws {
        // Every marker is validated before anything is removed, so a typo in
        // the second argument does not leave the first key already gone and the
        // user unsure what happened.
        let parsed = try markers.map { text -> AuthorizedKeys.Marker in
            guard let marker = AuthorizedKeys.Marker(text: text) else {
                throw ToolFailure("not a Bleat marker: '\(text)'\n"
                    + "Expected bleat-device-… or bleat-enroll-…, as printed by `bleat keys list`.")
            }
            return marker
        }

        let present = Dictionary(
            try read().map { ($0.marker, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for marker in parsed {
            // Refused rather than run: `removeCommand` exits 0 when it matches
            // nothing, so revoking a marker that was never there would print a
            // confident "revoked" and change nothing. A user acting on a lost
            // phone deserves the opposite of that.
            guard let entry = present[marker] else {
                throw ToolFailure("no Bleat key with marker '\(marker.value)' in \(AuthorizedKeys.path).\n"
                    + "Run `bleat keys list` to see what is there.")
            }

            do { _ = try Shell.output(AuthorizedKeys.removeCommand(marker: marker)) }
            catch { throw ToolFailure("could not edit \(AuthorizedKeys.path): \(error)") }

            // Asked again rather than assumed. The removal is a
            // read-modify-write behind a lock, and the ways it fails quietly —
            // a full disk, a read-only home — all exit 0 through the `|| true`
            // that makes "matched nothing" a normal outcome.
            let stillThere = try Shell.output(AuthorizedKeys.containsCommand(marker: marker))
                .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
            guard !stillThere else {
                throw ToolFailure("\(marker.value) is still in \(AuthorizedKeys.path). Nothing was revoked.")
            }

            print("Revoked \(marker.value)  \(entry.fingerprint ?? "")")
            if entry.kind == .device {
                print("That phone can no longer connect. Pair it again to restore access.")
            }
        }
    }

    // MARK: - Reading

    /// Reads through the same locked command the phone's side uses, so a
    /// revocation and a pairing in flight cannot interleave into a lost update.
    static func read() throws -> [AuthorizedKeys.Entry] {
        do { return AuthorizedKeys.Entry.parse(output: try Shell.output(AuthorizedKeys.listCommand())) }
        catch { throw ToolFailure("could not read \(AuthorizedKeys.path): \(error)") }
    }
}
#endif
