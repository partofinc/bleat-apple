/// The name of a Herdr session, checked against what herdr will actually
/// accept.
///
/// **Validated, never sanitised** — the same rule as `Marker(text:)`, and for
/// the same reason. Repairing `my session` into `mysession` hands the user a
/// session under a name they did not choose and cannot predict; refusing a typo
/// costs one correction.
///
/// The rules are herdr 0.9.0's own, read off its refusals rather than guessed
/// (8 Sept 2026, against the live host):
///
/// ```
/// $ HERDR_SESSION='a/b' herdr server
/// error: session name may only contain ASCII letters, numbers, '.', '_' and '-'
/// $ HERDR_SESSION='..' herdr server
/// error: session name cannot be . or ..
/// ```
///
/// Checking here rather than letting the host refuse is not politeness: the
/// launch is detached, so its exit status is the *shell's* and herdr's
/// complaint goes to a log the phone would have to fetch to discover that
/// nothing happened. A name that cannot work should never leave the phone.
public struct SessionName: Sendable, Hashable {
    /// Why a string is not a usable session name.
    public enum Problem: Sendable, Hashable {
        case empty
        /// Anything outside `A-Za-z0-9._-`, which is herdr's own set.
        case illegalCharacters
        /// `.` or `..`, which herdr refuses because they name its own session
        /// directory's parent.
        case reserved
        /// **herdr accepts this one, and that is the problem.** Measured: a
        /// session named `-x` starts perfectly well, and then neither
        /// `herdr session stop -- -x` nor `herdr session delete -- -x` can
        /// address it — both answer with their usage line, because the name is
        /// parsed as a flag. Its directory had to be removed by hand and its
        /// server killed by pid.
        ///
        /// So the phone must not create one. Bleat would be leaving a session
        /// running on someone's Mac that the Mac's own CLI cannot stop, which
        /// is the opposite of a remote control.
        case leadingDash

        /// Fit to show under a text field.
        public var message: String {
            switch self {
            case .empty: "Give the session a name."
            case .illegalCharacters: "Letters, numbers, dots, underscores and dashes only."
            case .reserved: "That name is reserved."
            case .leadingDash: "A name cannot start with a dash — herdr could not stop it again."
            }
        }
    }

    public let text: String

    public init?(_ text: String) {
        guard Self.problem(with: text) == nil else { return nil }
        self.text = text
    }

    /// What is wrong with `text`, or nil if nothing is.
    ///
    /// Separate from the initialiser so a field can say *why* while the user is
    /// still typing, rather than only refusing to proceed.
    public static func problem(with text: String) -> Problem? {
        if text.isEmpty { return .empty }
        if text == "." || text == ".." { return .reserved }
        if text.hasPrefix("-") { return .leadingDash }
        let allowed = text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
        return allowed ? nil : .illegalCharacters
    }
}
