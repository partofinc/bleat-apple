import Foundation
import Testing
@testable import BleatKit

@Suite("authorized_keys commands")
struct AuthorizedKeysTests {

    @Test("markers are namespaced and distinguish enrollment from device keys")
    func markerShape() {
        #expect(AuthorizedKeys.enrollmentMarker(id: "abc123").hasPrefix("bleat-enroll-"))
        #expect(AuthorizedKeys.deviceMarker(id: "abc123").hasPrefix("bleat-device-"))
        #expect(AuthorizedKeys.enrollmentMarker(id: "abc123") != AuthorizedKeys.deviceMarker(id: "abc123"))
    }

    @Test("generated markers are unique, so two pairings do not delete each other's keys")
    func markersAreUnique() {
        let markers = Set((0..<200).map { _ in AuthorizedKeys.enrollmentMarker() })
        #expect(markers.count == 200)
    }

    /// A marker is interpolated into a shell command *and* into a key comment.
    /// Anything that can carry a quote can break out of either one.
    @Test("a marker cannot carry shell metacharacters")
    func markerSanitised() {
        let hostile = "a'; rm -rf ~; echo '"
        let marker = AuthorizedKeys.enrollmentMarker(id: hostile)
        #expect(!marker.contains("'"))
        #expect(!marker.contains(";"))
        #expect(!marker.contains(" "))
        #expect(!marker.contains("$"))
        #expect(marker == "bleat-enroll-arm-rfecho")   // ~ is not in [A-Za-z0-9._-] either
    }

    /// sshd's `StrictModes` is on by default and makes it **silently ignore**
    /// authorized_keys when the directory or file is too permissive. Without
    /// these chmods a first pairing on a fresh account writes a correct file
    /// that authenticates nothing, with no hint why.
    @Test("appending sets the permissions sshd silently requires")
    func appendSetsModes() {
        let command = AuthorizedKeys.appendCommand(line: "ssh-ed25519 AAAA bleat-device-01")
        #expect(command.contains("mkdir -p ~/.ssh"))
        #expect(command.contains("chmod 700 ~/.ssh"))
        #expect(command.contains("chmod 600 ~/.ssh/authorized_keys"))
        #expect(command.contains(">> ~/.ssh/authorized_keys"))
    }

    @Test("the appended line is single-quoted and a quote cannot break out")
    func appendQuotes() {
        let command = AuthorizedKeys.appendCommand(line: "key it's here")
        #expect(command.contains(#"'key it'\''s here'"#))
    }

    /// `mv` would carry mktemp's mode and owner onto the file; a mode sshd
    /// dislikes disables the whole file. Rewriting through `cat >` keeps the
    /// original inode and permissions.
    @Test("removal rewrites in place rather than moving a temp file over the file")
    func removePreservesFile() {
        let command = AuthorizedKeys.removeCommand(marker: "bleat-enroll-ab12")
        #expect(command.contains(#"cat "$t" > "$f""#))
        #expect(!command.contains("mv "))
        #expect(command.contains("grep -v -F --"))
    }

    /// `grep -v` exits 1 when it emits nothing, which happens whenever the file
    /// held only the marked line. Without the `|| true` the chain aborts and
    /// the enrollment key is left behind — exactly the key that must not
    /// outlive pairing.
    @Test("removal tolerates grep's empty-output exit code")
    func removeToleratesEmptyOutput() {
        #expect(AuthorizedKeys.removeCommand(marker: "m").contains("|| true"))
    }

    @Test("removal quotes the marker and matches it as a fixed string")
    func removeQuotesMarker() {
        let command = AuthorizedKeys.removeCommand(marker: "bleat-enroll-ab12")
        #expect(command.contains("'bleat-enroll-ab12'"))
        #expect(command.contains("-F"))   // never a regex: a marker is literal
    }

    @Test("a hostile marker is sanitised on the way into a removal command")
    func removeSanitises() {
        let command = AuthorizedKeys.removeCommand(marker: "x'; rm -rf ~; '")
        #expect(!command.contains("rm -rf ~"))
    }

    @Test("presence is reported on stdout, since the caller reads output not exit codes")
    func containsPrints() {
        let command = AuthorizedKeys.containsCommand(marker: "bleat-device-01")
        #expect(command.contains("echo yes"))
        #expect(command.contains("echo no"))
        #expect(command.contains("'bleat-device-01'"))
    }
}
