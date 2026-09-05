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

    /// `Marker(text:)` is the one place a marker comes from outside this
    /// module — a line read off a host, or a string a user typed to revoke.
    @Test("a whole marker reads back with its kind")
    func markerRoundTrips() throws {
        let device = AuthorizedKeys.deviceMarker()
        let read = try #require(AuthorizedKeys.Marker(text: device.value))
        #expect(read == device)
        #expect(read.kind == .device)
        #expect(AuthorizedKeys.Marker(text: AuthorizedKeys.enrollmentMarker().value)?.kind == .enrollment)
    }

    /// The asymmetry with the id-taking initialiser, which sanitises. Here the
    /// string names the line `removeCommand` will delete, so quietly turning
    /// `bleat-device-ab/12` into `bleat-device-ab12` could delete a *different*
    /// phone's key. A typo must be refused, not repaired.
    @Test("a typed marker is validated, never sanitised into a different one")
    func markerTextIsValidated() {
        for rejected in [
            "bleat-device-ab/12",       // would sanitise to an existing marker
            "bleat-device-ab 12",
            "bleat-device-",
            "bleat-device",
            "bleat-agent-ab12",         // not a kind
            "device-ab12",              // not namespaced
            "xbleat-device-ab12",
            "bleat-device-ab'; rm -rf ~; echo '",
            "",
        ] {
            #expect(AuthorizedKeys.Marker(text: rejected) == nil, "\(rejected.debugDescription)")
        }
    }

    /// The id may itself contain `-`, since `randomHex` could be replaced and
    /// `sanitizeMarker` allows it. Splitting on every `-` would truncate such a
    /// marker and delete nothing — or, worse, match by prefix.
    @Test("an id containing a dash survives the round trip whole")
    func markerKeepsDashesInTheID() throws {
        let marker = try #require(AuthorizedKeys.deviceMarker(id: "ab-12-cd"))
        #expect(marker.value == "bleat-device-ab-12-cd")
        #expect(AuthorizedKeys.Marker(text: marker.value) == marker)
    }

    /// The command behind `bleat keys list`. Locked for the same reason the
    /// phone's verification reads are: every write-back truncates before it
    /// writes, and an unlocked read landing there reports an empty file — which
    /// here reads as "no keys on this machine".
    @Test("listing every Bleat key takes the lock and tolerates a missing file")
    func listCommandShape() {
        let command = AuthorizedKeys.listCommand()
        #expect(command.contains("mkdir ~/.ssh/.bleat-lock"))
        #expect(command.contains("bleat-(enroll|device)-"))
        #expect(command.contains("|| true"), "grep exits 1 on no match, which is a normal answer")
        #expect(command.contains("2>/dev/null"), "a host with no authorized_keys is not an error")
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
        #expect(command.contains("bleat-device-01[[:space:]]*$"))
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
        #expect(AuthorizedKeys.containsCommand(marker: marker).contains("bleat-device-ab12[[:space:]]*$"))
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
        #expect(command.contains("bleat-enroll-[A-Za-z0-9._-]+[[:space:]]*$"))
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
        #expect(command.contains("bleat-device-[A-Za-z0-9._-]+[[:space:]]*$"))
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

@Suite("Removing a key by the key itself")
struct KeyPatternTests {

    private let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhKfcrGJN9TJkeFBij/SoJie+EkZFSkE0zVCLVZbsnj"

    /// The phone never learns the enrollment marker — it is minted on the host
    /// and the QR does not carry it — so the line is found by the key, which
    /// the phone does have.
    @Test("the blob is matched as a whole field, not as a substring")
    func delimited() throws {
        let pattern = try #require(AuthorizedKeys.keyPattern(publicKeyLine: line))
        #expect(pattern.hasPrefix("'[[:space:]]"))
        #expect(pattern.hasSuffix("([[:space:]]|$)'"))
    }

    /// base64's alphabet includes `+`, which is an ERE metacharacter. Unescaped
    /// it would turn the preceding character into "one or more", so the pattern
    /// would match keys that are not this one — and `grep -v` would delete them.
    @Test("base64's + is escaped, so the pattern cannot become a wildcard")
    func escapesPlus() throws {
        let pattern = try #require(AuthorizedKeys.keyPattern(publicKeyLine: line))
        #expect(pattern.contains(#"Jie\+EkZ"#))
        #expect(!pattern.contains("Jie+EkZ"))
    }

    /// A pattern built from something unparsable is how an `authorized_keys`
    /// gets truncated: `grep -v` with an over-broad pattern removes everything
    /// it matches, and the user's own keys are in the same file.
    @Test("an unparsable line yields no command at all")
    func refusesGarbage() {
        #expect(AuthorizedKeys.removeKeyCommand(publicKeyLine: "") == nil)
        #expect(AuthorizedKeys.removeKeyCommand(publicKeyLine: "not-a-key") == nil)
        #expect(AuthorizedKeys.containsKeyCommand(publicKeyLine: "ssh-ed25519 %%%") == nil)
    }

    /// The two ends write the same key differently: the host puts
    /// `restrict,expiry-time=…` in front and a marker behind, and the phone has
    /// neither. Matching the blob rather than the line is what lets the phone
    /// delete a line it could not have reconstructed.
    @Test("options and comments do not change the pattern")
    func ignoresOptionsAndComments() throws {
        let bare = try #require(AuthorizedKeys.keyPattern(publicKeyLine: line))
        let decorated = try #require(AuthorizedKeys.keyPattern(
            publicKeyLine: line + " bleat-enroll-0123456789abcdef"
        ))
        #expect(bare == decorated)
    }
}

