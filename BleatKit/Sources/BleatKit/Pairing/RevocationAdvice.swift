import Foundation

/// What to tell a user who has to remove this device's key by hand.
///
/// In `BleatKit` rather than in the app for the same reason `Agent.displayTitle`
/// is: it names a command surface, `bleat keys revoke <marker>`, that is
/// defined here. A phone that printed a syntax the tool no longer accepts would
/// be worse than printing nothing — the user would run it, see it fail, and
/// have no reason to think the key was still there.
public struct RevocationAdvice: Sendable, Equatable {
    /// The command to run on the host. Short enough to retype from a photo.
    public let command: String
    /// How to find the right key, when the command cannot name it.
    public let detail: String?

    private init(command: String, detail: String?) {
        self.command = command
        self.detail = detail
    }

    /// "Remove this device's key" — for a host the phone could not reach, so
    /// the key is presumed still there.
    ///
    /// - Parameters:
    ///   - deviceMarker: `PairedPeer.deviceMarker`, if the record has one.
    ///   - deviceFingerprint: This device's key fingerprint, which is the same
    ///     on every host it is paired to and always available from the
    ///     Keychain.
    public static func revoke(
        deviceMarker: String?,
        deviceFingerprint: String?
    ) -> RevocationAdvice {
        // Validated, not trusted. The marker comes off a JSON file on the
        // device and is interpolated into a command the user will paste into a
        // shell — and `Marker(text:)` is the same check `bleat keys revoke`
        // applies, so anything that would be refused there is not offered here.
        // The listing route still works, so there is a real fallback.
        if let marker = deviceMarker.flatMap(AuthorizedKeys.Marker.init(text:)) {
            return RevocationAdvice(command: "bleat keys revoke \(marker.value)", detail: nil)
        }
        return RevocationAdvice(command: "bleat keys list", detail: findIt(deviceFingerprint))
    }

    /// "Check whether the key is still there" — for a host that **refused**
    /// this key.
    ///
    /// A different question, and `bleat keys revoke` is the wrong command to
    /// offer for it: the likeliest reading is that the key has already been
    /// removed, in which case revoking by marker fails with "no Bleat key with
    /// that marker" and reads like something went wrong. The other reading is
    /// that the key is still in the file and sshd is ignoring it — a
    /// `StrictModes` permissions drift does exactly that — and only looking can
    /// tell the two apart.
    public static func check(
        deviceMarker: String?,
        deviceFingerprint: String?
    ) -> RevocationAdvice {
        let marker = deviceMarker.flatMap(AuthorizedKeys.Marker.init(text:))
        return RevocationAdvice(
            command: "bleat keys list",
            detail: marker.map { "If \($0.value) is not listed, the key is already gone." }
                ?? findIt(deviceFingerprint)
        )
    }

    /// How to pick this device's key out of a listing without a marker: a
    /// record paired before the marker was stored, or one that has been edited.
    /// `bleat keys list` prints a fingerprint byte-identical to the one this
    /// device shows, so matching them by eye is a check the user can perform.
    private static func findIt(_ fingerprint: String?) -> String {
        fingerprint.map { "Then revoke the key with fingerprint \($0)." }
            ?? "Then revoke the key matching the one under \u{201C}This device\u{2019}s key\u{201D}."
    }
}
