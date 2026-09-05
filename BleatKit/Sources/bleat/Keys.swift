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
        // A concrete marker only when there is exactly one — with two phones
        // paired, naming either one is naming an arbitrary one, and the user
        // pastes it and revokes a device they meant to keep. Which key belongs
        // to which phone is a question only the fingerprints above can answer.
        if devices.count == 1 {
            print("  bleat keys revoke \(devices[0].marker.value)")
        } else {
            print("  bleat keys revoke <marker>")
            print("")
            print("Match a phone to its key by the fingerprint: it is the one Bleat shows")
            print("on that phone, and the one `ssh-keygen -lf` prints.")
        }
    }

    /// What is worth saying about one line, beyond its fingerprint.
    ///
    /// An expired enrollment key is the common case here and it is *not* a
    /// problem: sshd has already stopped accepting it, and the next `bleat
    /// pair` sweeps it. Saying so is the difference between a user ignoring a
    /// stale line and a user thinking their machine is open.
    static func note(for entry: AuthorizedKeys.Entry) -> String {
        guard entry.kind == .enrollment else { return "a paired phone — full shell access" }
        switch (entry.expiryStamp, entry.hasExpired()) {
        case (_, true?):
            return "expired \(relative(entry.expiresAt)) — sshd already refuses it"
        case (_, false?):
            return "a pairing in progress — expires \(relative(entry.expiresAt))"
        case (.some(let stamp), nil):
            // A deadline sshd *is* enforcing, in a form this build cannot read.
            // Collapsing it into the case below is precisely what
            // `Entry.expiryStamp` was added to prevent: it would say the key
            // works forever when it may already be dead.
            return "expires at \(stamp), which this build cannot read"
        case (nil, nil):
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
        // Both checks happen before anything is removed. Validating only the
        // *format* up front is not enough, and the first version of this did
        // exactly that: a marker that parses but is not on the machine was
        // caught inside the loop, so `revoke <good> <typo>` removed the first
        // key and then exited 1 — the partial application the up-front pass
        // exists to prevent.
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
        let doomed = try parsed.map { marker -> AuthorizedKeys.Entry in
            // Refused rather than run: `removeCommand` exits 0 when it matches
            // nothing, so revoking a marker that was never there would print a
            // confident "revoked" and change nothing. A user acting on a lost
            // phone deserves the opposite of that.
            guard let entry = present[marker] else {
                throw ToolFailure("no Bleat key with marker '\(marker.value)' in \(AuthorizedKeys.path).\n"
                    + "Run `bleat keys list` to see what is there.")
            }
            return entry
        }

        // The same marker twice would otherwise be revoked once and reported
        // twice, the second time over a file the command could not have
        // changed. `Marker` is `Hashable`, and order is kept so the report
        // follows the command line.
        var seen: Set<AuthorizedKeys.Marker> = []
        var revoked: [String] = []
        for entry in doomed where seen.insert(entry.marker).inserted {
            let marker = entry.marker
            do { _ = try Shell.output(AuthorizedKeys.removeCommand(marker: marker)) }
            catch { throw ToolFailure("could not edit \(AuthorizedKeys.path): \(error)") }

            // Asked again rather than assumed, and asked through the *locked*
            // listing rather than `containsCommand`, which is deliberately
            // unlocked for the host's ten-times-a-second poll. Every write-back
            // truncates before it writes, so an unlocked read landing in that
            // instant sees an empty file and answers "gone" — which here would
            // print a confident "Revoked" over a file that still holds the key.
            guard try !read().contains(where: { $0.marker == marker }) else {
                // Not "nothing was revoked": by here an earlier marker on the
                // same command line may already be gone, and that sentence
                // would be the last thing the user reads. The up-front pass
                // rules out a *missing* marker, not a removal that failed.
                throw ToolFailure("\(marker.value) is still in \(AuthorizedKeys.path); it was not revoked."
                    + (revoked.isEmpty ? "" : "\nAlready revoked: \(revoked.joined(separator: ", ")).")
                    + "\nRun `bleat keys list` to see what is there.")
            }

            revoked.append(marker.value)
            print("Revoked \(marker.value)  \(entry.fingerprint ?? "")")
            if entry.kind == .device {
                print("That phone can no longer connect. Pair it again to restore access.")
            }
            // Stdout is block-buffered when redirected while stderr is not, so
            // without this a failure on the *next* marker prints before the
            // success of this one — the same hazard `bleat pair` and
            // `bleat redeem` flush for.
            fflush(stdout)
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
