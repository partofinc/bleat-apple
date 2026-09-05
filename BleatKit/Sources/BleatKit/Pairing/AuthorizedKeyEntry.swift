import Foundation

extension AuthorizedKeys {
    /// One Bleat line read back off a host's `authorized_keys`.
    ///
    /// This is what makes revocation possible at all. Everything else in
    /// `AuthorizedKeys` writes; this reads, so a user can be shown what their
    /// machine still lets in and pick what to remove. Unpairing on a phone
    /// drops the phone's own record and cannot reach the host, so the file is
    /// the only place that knows.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let marker: Marker
        /// `SHA256:…` for the key on this line — the string the user can
        /// compare against what the phone shows, and against `ssh-keygen -lf`.
        ///
        /// Optional because a line can carry a Bleat marker and still not
        /// parse: an editor that wrapped it, a truncated write. Such a line is
        /// **still listed**, because a device key that authenticates and does
        /// not appear in the list is the exact failure this screen exists to
        /// prevent. What cannot be shown is the fingerprint, not the key.
        public let fingerprint: String?
        /// The `expiry-time` sshd will enforce, when the line carries one.
        ///
        /// Only enrollment keys are written with it, and a past deadline means
        /// sshd already refuses the key — the line is untidy rather than
        /// dangerous, and saying so is the difference between a user ignoring
        /// it and a user panicking about it.
        public let expiresAt: Date?
        /// The line as it appears in the file, so a caller can show it verbatim
        /// rather than a reconstruction that might differ.
        public let line: String

        public var id: String { marker.value }

        public var kind: Marker.Kind { marker.kind }

        /// Whether sshd will already refuse this key. Nil when there is no
        /// deadline on the line at all, which is every device key.
        public func hasExpired(asOf now: Date = Date()) -> Bool? {
            expiresAt.map { $0 <= now }
        }

        /// Reads one line. Nil when it carries no Bleat marker — which is every
        /// key the user installed themselves, and those are none of Bleat's
        /// business.
        ///
        /// The marker is taken from the **last** whitespace-separated field,
        /// which is where `enrollmentLine` and `Enrollment` both put it, and
        /// where `removeCommand`'s anchored pattern looks for it. Reading it
        /// from anywhere else would let this list and that deletion disagree
        /// about which line is which.
        public static func parse(line rawLine: String) -> Entry? {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let last = fields.last, let marker = Marker(text: String(last)) else { return nil }

            return Entry(
                marker: marker,
                fingerprint: fingerprint(ofFields: fields),
                expiresAt: expiry(inFields: fields),
                line: line
            )
        }

        /// Every Bleat line in `listCommand`'s output, in file order.
        public static func parse(output: String) -> [Entry] {
            output.split(separator: "\n").compactMap { parse(line: String($0)) }
        }

        /// The key's fingerprint, whether or not the line begins with options.
        ///
        /// An `authorized_keys` line is `[options] <algorithm> <base64>
        /// [comment]`, and options are optional — the enrollment line has
        /// `restrict,expiry-time="…"` in front while a device line has nothing.
        /// Both shapes are tried rather than guessed at from the field count,
        /// since a comment makes the two the same length.
        private static func fingerprint(ofFields fields: [Substring]) -> String? {
            for start in 0..<min(2, fields.count) {
                let candidate = fields[start...].joined(separator: " ")
                if let key = SSHPublicKeyLine(line: candidate) { return key.fingerprint }
            }
            return nil
        }

        /// Pulls the timestamp out of `expiry-time="20260905T…Z"`.
        ///
        /// Read from the options field only — the first one, before the
        /// algorithm — so a comment that happens to contain the text cannot
        /// invent a deadline that sshd is not enforcing.
        private static func expiry(inFields fields: [Substring]) -> Date? {
            guard let options = fields.first,
                  let range = options.range(of: #"expiry-time=""#)
            else { return nil }
            let rest = options[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return AuthorizedKeys.expiryDate(stamp: String(rest[..<end]))
        }
    }
}
