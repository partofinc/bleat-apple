import Foundation
import Testing
@testable import BleatKit

@Suite("reading Bleat keys back off a host")
struct AuthorizedKeyEntryTests {

    /// Built the way the host builds them, not typed out: a line written by
    /// `enrollmentLine` and one written by `Enrollment` are the two shapes that
    /// actually reach this parser, and a hand-written approximation of either
    /// is a test that passes while the real thing does not parse.
    private func enrollmentLine(expiresAt: Date = Date().addingTimeInterval(300)) -> String {
        AuthorizedKeys.enrollmentLine(
            publicKeyLine: SSHKeyPair().authorizedKeyLine(comment: ""),
            marker: AuthorizedKeys.enrollmentMarker(),
            expiresAt: expiresAt
        )
    }

    private func deviceLine(_ marker: AuthorizedKeys.Marker = AuthorizedKeys.deviceMarker()) -> String {
        SSHKeyPair().authorizedKeyLine(comment: marker.value)
    }

    @Test("a device line parses to its marker and fingerprint")
    func deviceEntry() throws {
        let key = SSHKeyPair()
        let marker = AuthorizedKeys.deviceMarker()
        let entry = try #require(AuthorizedKeys.Entry.parse(line: key.authorizedKeyLine(comment: marker.value)))

        #expect(entry.marker == marker)
        #expect(entry.kind == .device)
        #expect(entry.fingerprint == key.fingerprint)
        // No `expiry-time` on a device key, and that is the point of showing it
        // separately: nothing removes one on its own.
        #expect(entry.expiresAt == nil)
        #expect(entry.hasExpired() == nil)
    }

    /// The enrollment line begins with `restrict,expiry-time="…"`, so the key
    /// is not the first field. Reading the fingerprint from field 0 gives nil
    /// and the row shows "unreadable key" for a perfectly ordinary line.
    @Test("an options prefix does not hide the key")
    func enrollmentEntryWithOptions() throws {
        let key = SSHKeyPair()
        let marker = AuthorizedKeys.enrollmentMarker()
        let deadline = Date().addingTimeInterval(360)
        let line = AuthorizedKeys.enrollmentLine(
            publicKeyLine: key.authorizedKeyLine(comment: ""),
            marker: marker,
            expiresAt: deadline
        )
        let entry = try #require(AuthorizedKeys.Entry.parse(line: line))

        #expect(entry.marker == marker)
        #expect(entry.kind == .enrollment)
        #expect(entry.fingerprint == key.fingerprint)
        // Whole seconds: the stamp sshd is given has no sub-second field.
        let expires = try #require(entry.expiresAt)
        #expect(abs(expires.timeIntervalSince(deadline)) < 1)
        #expect(entry.hasExpired() == false)
    }

    /// The distinction `bleat keys list` reports. sshd already refuses an
    /// expired key, so such a line is untidy rather than dangerous — telling
    /// the user otherwise sends them chasing a key that cannot be used.
    @Test("an expired enrollment key knows it is expired")
    func expiredEnrollment() throws {
        let entry = try #require(
            AuthorizedKeys.Entry.parse(line: enrollmentLine(expiresAt: Date().addingTimeInterval(-3600)))
        )
        #expect(entry.hasExpired() == true)
    }

    /// Keys the user installed themselves are none of Bleat's business, and a
    /// listing that swept them up would invite revoking one.
    @Test("a key without a Bleat marker is not an entry")
    func foreignKeysAreIgnored() {
        for line in [
            SSHKeyPair().authorizedKeyLine(comment: "ravil@rawillk.air"),
            SSHKeyPair().authorizedKeyLine(comment: ""),
            "# a comment",
            "",
            "   ",
        ] {
            #expect(AuthorizedKeys.Entry.parse(line: line) == nil, "\(line.prefix(40))")
        }
    }

    /// A line whose marker reads but whose key does not — wrapped by an editor,
    /// truncated by a failed write. It is still listed: a key that
    /// authenticates and does not appear in the list is exactly the failure
    /// this screen exists to prevent, and only the fingerprint is lost.
    @Test("a damaged key still lists, without a fingerprint")
    func unreadableKeyStillLists() throws {
        let marker = AuthorizedKeys.deviceMarker()
        let entry = try #require(AuthorizedKeys.Entry.parse(line: "ssh-ed25519 not-base64!! \(marker.value)"))
        #expect(entry.marker == marker)
        #expect(entry.fingerprint == nil)
    }

    /// The marker is taken from the last field, which is where `removeCommand`'s
    /// anchored pattern looks for it — its pattern is `$`-anchored, so a marker
    /// anywhere else names a line that deletion would not match. Listing such a
    /// line would offer the user a revoke that silently does nothing.
    ///
    /// Written out by hand rather than through `authorizedKeyLine`, which
    /// cannot produce this: `SSHKeyPair.sanitize` turns a space in a comment
    /// into a dash. The file can still hold it — anything may edit it.
    @Test("a marker in the middle of a comment is not the marker")
    func markerIsTheLastField() {
        let key = SSHKeyPair().authorizedKeyLine(comment: AuthorizedKeys.deviceMarker().value)
        #expect(AuthorizedKeys.Entry.parse(line: "\(key) ravil") == nil)
    }

    /// Options may contain a **quoted space**, which splits into two fields and
    /// pushes the key past any fixed window. Such a line listed as "the key
    /// could not be read" while the key sat perfectly readable one field on.
    @Test("options containing a quoted space do not hide the key")
    func quotedSpaceInOptions() throws {
        let key = SSHKeyPair()
        let marker = AuthorizedKeys.deviceMarker()
        let line = #"command="echo hi",restrict,expiry-time="20991231235959Z" "#
            + "\(key.authorizedKeyLine(comment: "")) \(marker.value)"
        let entry = try #require(AuthorizedKeys.Entry.parse(line: line))

        #expect(entry.fingerprint == key.fingerprint)
        #expect(entry.hasExpired() == false, "the deadline is in 2099")
    }

    /// sshd accepts `YYYYMMDD` and `YYYYMMDDHHMM` as well as the full form this
    /// tool writes, with or without a `Z`. Reading only the written form
    /// reported a deadline sshd is enforcing as no deadline at all — wrong in
    /// the alarming direction.
    @Test("the shorter expiry forms sshd accepts are read, not ignored")
    func shortExpiryForms() throws {
        let key = SSHKeyPair().authorizedKeyLine(comment: "")
        let marker = AuthorizedKeys.deviceMarker()
        for stamp in ["20991231", "209912312359", "20991231235959", "20991231235959Z"] {
            let entry = try #require(
                AuthorizedKeys.Entry.parse(line: #"expiry-time="\#(stamp)" \#(key) \#(marker.value)"#),
                "\(stamp)"
            )
            #expect(entry.expiryStamp == stamp)
            #expect(entry.hasExpired() == false, "\(stamp)")
        }
    }

    /// "No deadline" and "a deadline this build cannot read" must stay
    /// different answers: sshd is enforcing the second one, and reporting it as
    /// the first tells the user a key will work forever when it will not.
    @Test("an unreadable stamp is not the same as no stamp")
    func unreadableStampIsNotAbsent() throws {
        let key = SSHKeyPair().authorizedKeyLine(comment: "")
        let marker = AuthorizedKeys.enrollmentMarker()
        let entry = try #require(
            AuthorizedKeys.Entry.parse(line: #"expiry-time="next tuesday" \#(key) \#(marker.value)"#)
        )
        #expect(entry.expiryStamp == "next tuesday")
        #expect(entry.expiresAt == nil)

        let none = try #require(AuthorizedKeys.Entry.parse(line: "\(key) \(marker.value)"))
        #expect(none.expiryStamp == nil)
    }

    @Test("every Bleat line in a file comes back, in order")
    func parsesWholeFile() throws {
        let first = AuthorizedKeys.deviceMarker()
        let second = AuthorizedKeys.deviceMarker()
        let output = [
            SSHKeyPair().authorizedKeyLine(comment: "ravil@rawillk.air"),
            deviceLine(first),
            enrollmentLine(),
            deviceLine(second),
        ].joined(separator: "\n") + "\n"

        let entries = AuthorizedKeys.Entry.parse(output: output)
        #expect(entries.map(\.marker.kind) == [.device, .enrollment, .device])
        #expect(entries.first?.marker == first)
        #expect(entries.last?.marker == second)
    }
}
