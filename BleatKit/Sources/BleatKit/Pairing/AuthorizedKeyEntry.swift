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
        /// The `expiry-time` sshd will enforce, when the line carries one and
        /// the stamp can be read.
        ///
        /// Only enrollment keys are written with it, and a past deadline means
        /// sshd already refuses the key — the line is untidy rather than
        /// dangerous, and saying so is the difference between a user ignoring
        /// it and a user panicking about it.
        public let expiresAt: Date?
        /// The raw `expiry-time` value, whether or not it parsed.
        ///
        /// Kept separately so "there is no deadline" and "there is a deadline
        /// this build cannot read" stay different answers. Collapsing them
        /// reports a key sshd is actively expiring as one that will work
        /// forever — wrong in the alarming direction.
        public let expiryStamp: String?
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
            // Splitting on whitespace is also what tolerates a trailing space
            // or a `\r` from a Windows-edited file — both of which hide a line
            // from a `$`-anchored grep, which is why `AuthorizedKeys.lineEnd`
            // exists. The two have to agree, or this lists a key that cannot
            // then be revoked.
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let last = fields.last, let marker = Marker(text: String(last)) else { return nil }

            // Options come before the key, so the key has to be found before
            // either can be read.
            let keyIndex = indexOfKey(in: fields)
            let stamp = keyIndex.flatMap { expiryStamp(inOptions: fields[..<$0]) }
            return Entry(
                marker: marker,
                fingerprint: keyIndex.flatMap { fingerprint(ofFields: fields, at: $0) },
                expiresAt: stamp.flatMap(AuthorizedKeys.expiryDate(stamp:)),
                expiryStamp: stamp,
                line: line
            )
        }

        /// Every Bleat line in `listCommand`'s output, in file order.
        public static func parse(output: String) -> [Entry] {
            output.split(separator: "\n").compactMap { parse(line: String($0)) }
        }

        /// Where the `<algorithm> <base64>` pair starts.
        ///
        /// An `authorized_keys` line is `[options] <algorithm> <base64>
        /// [comment]`, and options are optional — the enrollment line has
        /// `restrict,expiry-time="…"` in front while a device line has
        /// nothing. Scanned for rather than guessed at from the field count,
        /// which a comment makes ambiguous, and scanned to the end rather than
        /// only across the first two fields: options may contain a **quoted
        /// space** (`command="echo hi",restrict`), which splits into two
        /// fields and pushes the key past any fixed window. Such a line listed
        /// as "the key could not be read" while the key sat perfectly readable
        /// one field further along.
        ///
        /// Lines are a handful of fields, so scanning them all costs nothing.
        private static func indexOfKey(in fields: [Substring]) -> Int? {
            guard fields.count >= 2 else { return nil }
            for start in 0...(fields.count - 2) where SSHPublicKeyLine(
                line: "\(fields[start]) \(fields[start + 1])"
            ) != nil {
                return start
            }
            return nil
        }

        private static func fingerprint(ofFields fields: [Substring], at index: Int) -> String? {
            SSHPublicKeyLine(line: "\(fields[index]) \(fields[index + 1])")?.fingerprint
        }

        /// Pulls the timestamp out of `expiry-time="20260905123456Z"`.
        ///
        /// Read from the options only — everything before the algorithm — so a
        /// comment that happens to contain the text cannot invent a deadline
        /// sshd is not enforcing. The fields are rejoined because a quoted
        /// value may have been split across them.
        private static func expiryStamp(inOptions options: ArraySlice<Substring>) -> String? {
            let text = options.joined(separator: " ")
            guard let range = text.range(of: #"expiry-time=""#) else { return nil }
            let rest = text[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
    }
}
