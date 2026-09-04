import Foundation
import Testing
@testable import BleatKit

@Suite("authorized_keys commands")
struct AuthorizedKeysTests {

    @Test("markers are namespaced and distinguish enrollment from device keys")
    func markerShape() throws {
        let enroll = try #require(AuthorizedKeys.enrollmentMarker(id: "abc123"))
        let device = try #require(AuthorizedKeys.deviceMarker(id: "abc123"))
        #expect(enroll.value.hasPrefix("bleat-enroll-"))
        #expect(device.value.hasPrefix("bleat-device-"))
        #expect(enroll != device)
    }

    @Test("generated markers are unique, so two pairings do not delete each other's keys")
    func markersAreUnique() {
        #expect(Set((0..<200).map { _ in AuthorizedKeys.enrollmentMarker() }).count == 200)
    }

    /// A marker is interpolated into a shell command *and* into a key comment.
    /// Anything that can carry a quote can break out of either one.
    @Test("a marker cannot carry shell metacharacters")
    func markerSanitised() throws {
        let marker = try #require(AuthorizedKeys.enrollmentMarker(id: "a'; rm -rf ~; echo '"))
        #expect(!marker.value.contains("'"))
        #expect(!marker.value.contains(";"))
        #expect(!marker.value.contains(" "))
        #expect(marker.value == "bleat-enroll-arm-rfecho")   // ~ is not in [A-Za-z0-9._-] either
    }

    /// The finding this type exists to prevent. `grep -v -F -- ''` matches
    /// *every* line, so a marker that sanitised away to nothing would replace
    /// the user's whole authorized_keys with an empty file — destroying keys
    /// Bleat never wrote. Verified in a shell before the fix: a file with two
    /// unrelated keys came back 0 bytes. Making the empty case unrepresentable
    /// is why `Marker` is a type and not a `String`.
    @Test("a marker with nothing usable in it cannot be constructed at all")
    func emptyMarkerIsUnrepresentable() {
        for hostile in ["", "   ", "'\"$;|&", "~~~", "\n\t"] {
            #expect(AuthorizedKeys.enrollmentMarker(id: hostile) == nil, "\(hostile.debugDescription)")
            #expect(AuthorizedKeys.deviceMarker(id: hostile) == nil, "\(hostile.debugDescription)")
        }
    }

    /// sshd's `StrictModes` is on by default and makes it **silently ignore**
    /// authorized_keys when the directory or file is too permissive.
    @Test("appending sets the permissions sshd silently requires")
    func appendSetsModes() {
        let command = AuthorizedKeys.appendCommand(line: "ssh-ed25519 AAAA bleat-device-01")
        #expect(command.contains("mkdir -p ~/.ssh"))
        #expect(command.contains("chmod 700 ~/.ssh"))
        #expect(command.contains("chmod 600 ~/.ssh/authorized_keys"))
    }

    /// A plain `>>` appends with no leading newline, and authorized_keys files
    /// written by hand often lack a trailing one. Without the guard the new key
    /// is glued onto the previous one, killing **both** — and sshd says nothing.
    @Test("appending guarantees the entry starts on its own line")
    func appendGuardsTrailingNewline() {
        let command = AuthorizedKeys.appendCommand(line: "ssh-ed25519 AAAA bleat-device-01")
        #expect(command.contains("tail -c1"))
        #expect(command.contains(#"printf '\n'"#))
    }

    @Test("the appended line is single-quoted and a quote cannot break out")
    func appendQuotes() {
        #expect(AuthorizedKeys.appendCommand(line: "key it's here").contains(#"'key it'\''s here'"#))
    }

    /// `mv` would carry mktemp's mode and owner onto the file, and a mode sshd
    /// dislikes disables the whole file.
    @Test("removal rewrites in place rather than moving a temp file over the file")
    func removePreservesFile() throws {
        let command = AuthorizedKeys.removeCommand(marker: try #require(AuthorizedKeys.deviceMarker(id: "ab12")))
        #expect(command.contains(#"cat "$t" > "$f""#))
        #expect(!command.contains("mv "))
    }

    /// `grep -v` exits 1 when it emits nothing, which happens whenever the file
    /// held only the marked line. Without `|| true` the chain aborts and the
    /// enrollment key is left behind — exactly the key that must not outlive
    /// pairing.
    @Test("removal tolerates grep's empty-output exit code")
    func removeToleratesEmptyOutput() throws {
        #expect(AuthorizedKeys.removeCommand(marker: AuthorizedKeys.enrollmentMarker()).contains("|| true"))
    }

    /// Markers share a prefix namespace and take a caller-supplied id, so an
    /// unanchored substring match would let `bleat-device-01` also strip
    /// `bleat-device-012` — another device's key.
    @Test("the match is anchored, so one marker cannot strip another's key")
    func removeIsAnchored() throws {
        let command = AuthorizedKeys.removeCommand(marker: try #require(AuthorizedKeys.deviceMarker(id: "01")))
        #expect(command.contains("bleat-device-01$"))
        #expect(command.contains("[[:space:]]"))
        #expect(command.contains("grep -v -E"))
    }

    /// `.` is the one regex metacharacter that survives sanitising, and
    /// unescaped it would match any character.
    @Test("a dot in a marker is escaped rather than left as a wildcard")
    func dotIsEscaped() throws {
        let command = AuthorizedKeys.removeCommand(marker: try #require(AuthorizedKeys.deviceMarker(id: "a.b")))
        #expect(command.contains(#"a\.b"#))
    }

    @Test("presence uses the same anchored pattern as removal, so the two agree")
    func containsMatchesRemoval() throws {
        let marker = try #require(AuthorizedKeys.deviceMarker(id: "ab12"))
        #expect(AuthorizedKeys.containsCommand(marker: marker).contains("bleat-device-ab12$"))
        #expect(AuthorizedKeys.containsCommand(marker: marker).contains("echo yes"))
        #expect(AuthorizedKeys.containsCommand(marker: marker).contains("echo no"))
    }
}

@Suite("Enrollment keys")
struct EnrollmentKeyTests {

    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJ2uB32vlf"

    /// `expiry-time` is the only layer that works when the tool cannot run at
    /// all — `SIGKILL`, a panic, a power cut. sshd enforces it, so an abandoned
    /// enrollment key stops authenticating whatever happens to Bleat. Verified
    /// against a real sshd: accepted before the moment, `Permission denied`
    /// after it.
    @Test("an enrollment line carries a host-enforced deadline")
    func carriesExpiry() throws {
        let marker = try #require(AuthorizedKeys.enrollmentMarker(id: "ab12"))
        let line = AuthorizedKeys.enrollmentLine(
            publicKeyLine: key, marker: marker,
            expiresAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        #expect(line.hasPrefix("restrict,expiry-time=\""))
        #expect(line.contains(key))
        #expect(line.hasSuffix(" bleat-enroll-ab12"))   // marker last: removal anchors on it
    }

    /// `restrict` disables forwarding, X11 and PTY but leaves exec channels
    /// working, which is all pairing needs — verified against a real sshd.
    @Test("the key is restricted, not merely marked")
    func isRestricted() throws {
        let marker = try #require(AuthorizedKeys.enrollmentMarker(id: "ab12"))
        #expect(AuthorizedKeys.enrollmentLine(publicKeyLine: key, marker: marker, expiresAt: .now)
            .contains("restrict,"))
    }

    /// UTC with a `Z` suffix, which sshd accepts. A local-time deadline would
    /// shift under DST — an hour of unintended life, or an hour less.
    @Test("the deadline is stamped in UTC, not local time")
    func stampIsUTC() {
        // 2026-09-04T19:51:35Z
        let stamp = AuthorizedKeys.expiryStamp(Date(timeIntervalSince1970: 1_788_551_495))
        #expect(stamp == "20260904195135Z")
        #expect(stamp.hasSuffix("Z"))
    }

    /// In-process cleanup cannot be complete, so a run killed with `SIGKILL`
    /// leaves its key behind. The next run clears whatever it finds.
    @Test("the sweep matches any enrollment marker, not one particular key")
    func sweepMatchesAny() {
        let command = AuthorizedKeys.sweepEnrollmentsCommand()
        #expect(command.contains("bleat-enroll-[A-Za-z0-9._-]+$"))
        #expect(command.contains("|| true"))
        #expect(command.contains(#"cat "$t" > "$f""#))
    }

    /// A sweep that also took device keys would log the user's phone out every
    /// time they paired another one.
    @Test("the sweep cannot match a device key")
    func sweepSparesDeviceKeys() {
        #expect(!AuthorizedKeys.sweepEnrollmentsCommand().contains("bleat-device"))
        #expect(AuthorizedKeys.sweepEnrollmentsCommand().contains("-enroll-"))
    }

    /// A host with a phone already paired has a device key from the start, so
    /// "a device key exists" is true before the new phone does anything —
    /// which would turn any disappearance of the enrollment line into a false
    /// success. Redemption is judged on a *new* marker appearing.
    @Test("device markers can be listed, so redemption compares before and after")
    func listsDeviceMarkers() {
        let command = AuthorizedKeys.listDeviceMarkersCommand()
        #expect(command.contains("bleat-device-[A-Za-z0-9._-]+$"))
        #expect(command.contains("grep -o -E"))
        #expect(!command.contains("-enroll-"))
        #expect(command.contains("|| true"))   // no matches is normal, not failure
    }

    /// An absent file is the normal state on a fresh account; the sweep must
    /// not fail there.
    @Test("the sweep tolerates a missing authorized_keys")
    func sweepToleratesMissingFile() {
        #expect(AuthorizedKeys.sweepEnrollmentsCommand().contains(#"if [ -f "$f" ]"#))
    }
}

@Suite("authorized_keys locking")
struct AuthorizedKeysLockTests {

    /// Removal is a read-modify-write while the phone concurrently appends. If
    /// the append lands between the read and the write-back it is lost — the
    /// phone reports success and can never connect. That window is the one
    /// `expiryGrace` deliberately keeps alive, so it is not hypothetical.
    @Test("every mutating command takes the lock")
    func mutatorsAreLocked() throws {
        let marker = try #require(AuthorizedKeys.deviceMarker(id: "ab12"))
        for command in [
            AuthorizedKeys.appendCommand(line: "ssh-ed25519 AAAA x"),
            AuthorizedKeys.removeCommand(marker: marker),
            AuthorizedKeys.sweepEnrollmentsCommand(),
        ] {
            #expect(command.contains("mkdir ~/.ssh/.bleat-lock"), "\(command.prefix(40))")
            #expect(command.contains("rmdir ~/.ssh/.bleat-lock"))
        }
    }

    /// Reads do not lock. A torn read can only make the enrollment marker look
    /// absent, and redemption also requires a *new* device marker, which a torn
    /// read cannot invent — so the worst case is one wasted poll.
    @Test("read-only commands do not take the lock")
    func readsAreUnlocked() throws {
        let marker = try #require(AuthorizedKeys.deviceMarker(id: "ab12"))
        #expect(!AuthorizedKeys.containsCommand(marker: marker).contains(".bleat-lock"))
        #expect(!AuthorizedKeys.listDeviceMarkersCommand().contains(".bleat-lock"))
    }

    /// The distinction that made the difference. Breaking the lock after N
    /// failed attempts looks equivalent to breaking a stale one and is not:
    /// under contention every waiter reaches N and tears the lock away from a
    /// live holder. Measured with 200 concurrent appends against 200 removals,
    /// the attempt-count version kept 16 of 200 keys and lost the user's own;
    /// judging by age kept all 200.
    @Test("staleness is judged by the lock's age, never by how long we waited")
    func stalenessIsByAge() {
        let command = AuthorizedKeys.sweepEnrollmentsCommand()
        #expect(command.contains("-mmin +1"))
        #expect(!command.contains("-ge 100"))
    }

    /// A failed `mkdir` means contention only if the lock is really there.
    /// When it is not, the directory is unwritable and retrying can never
    /// succeed — without this the tool spun forever on an `~/.ssh` at mode
    /// 500, which is exactly the failure a user most needs told about.
    @Test("an unwritable ~/.ssh fails fast instead of spinning")
    func unwritableFailsFast() {
        let command = AuthorizedKeys.appendCommand(line: "ssh-ed25519 AAAA x")
        #expect(command.contains("if [ ! -d ~/.ssh/.bleat-lock ]"))
        #expect(command.contains("exit 75"))
        #expect(command.contains("is ~/.ssh writable?"))
    }

    /// The wrapper runs the command and then removes the lock, so an `exit`
    /// inside would strand it for a minute.
    @Test("locked commands use a conditional rather than an early exit")
    func noEarlyExitInsideTheLock() throws {
        let marker = try #require(AuthorizedKeys.deviceMarker(id: "ab12"))
        for command in [AuthorizedKeys.removeCommand(marker: marker), AuthorizedKeys.sweepEnrollmentsCommand()] {
            #expect(command.contains(#"if [ -f "$f" ]"#))
            #expect(!command.contains("|| exit 0"))
        }
    }
}
