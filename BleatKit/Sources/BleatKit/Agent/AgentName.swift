/// The name `herdr agent start` records an agent under.
///
/// **Validated, never sanitised** — the `Marker(text:)`, `SessionName` and
/// `WorkspaceDirectory` rule.
///
/// Unlike `WorkspaceDirectory`, every rule here is herdr's own, and it states
/// them itself. Read off its refusal (herdr 0.9.0, 9 Sept 2026; word for word
/// the same on 0.9.3, 30 Sept 2026):
///
/// ```
/// $ herdr agent start 'my agent' --kind claude --pane w1:p2
/// error: agent name must start with a lowercase letter and contain only
///        lowercase letters, digits, '-' or '_' (1-32 characters)
/// ```
///
/// Checking here is not politeness — herdr refuses this **instantly**, so
/// unlike a session launch nothing is lost by letting it through. What is
/// gained is that the user finds out while they are still typing rather than
/// after a tap, and in the same place as every other name in this app.
public struct AgentName: Sendable, Hashable {
    /// Why a string is not a usable agent name.
    public enum Problem: Sendable, Hashable {
        case empty
        /// Anything outside `a-z0-9_-`, which is herdr's own set. Capitals
        /// included, which is the one most likely to surprise: `Reviewer` is
        /// refused.
        case illegalCharacters
        /// herdr requires the *first* character to be a lowercase letter, so a
        /// name may not begin with a digit, a dash or an underscore.
        case badFirstCharacter
        /// More than 32 characters.
        case tooLong

        /// Fit to show under a text field.
        public var message: String {
            switch self {
            case .empty: "Give the agent a name."
            case .illegalCharacters: "Lowercase letters, numbers, dashes and underscores only."
            case .badFirstCharacter: "A name has to start with a lowercase letter."
            case .tooLong: "A name can be at most 32 characters."
            }
        }
    }

    /// herdr's own limit, from the same message.
    public static let maxLength = 32

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
        if text.count > maxLength { return .tooLong }
        let allowed = text.allSatisfy {
            $0.isASCII && (($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" || $0 == "_")
        }
        guard allowed else { return .illegalCharacters }
        // Checked after the character set, so `Reviewer` is reported as the
        // capital it is rather than as a bad first character — the user can see
        // the capital, and being told to start with a lowercase letter about a
        // name that *does* start with a letter reads as a contradiction.
        guard let first = text.first, first.isLetter else { return .badFirstCharacter }
        return nil
    }
}
