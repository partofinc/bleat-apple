import Foundation

/// A named layout saved on a Mac with `herdr-layout`: Herdr.app's spaces,
/// tabs and panes, and the Claude sessions to resume in them.
///
/// **`herdr-layout` is Ravil's own script, not part of Herdr** (decided 15 Nov
/// 2026, Phase C). Bleat reads what `herdr-layout list --json` prints and
/// nothing else: the saved files under `~/.config/herdr-app/saved-layouts`
/// are the script's business. A host without the script has no layouts, and
/// the app shows none. See `docs/app-screens.md`, "Layouts".
///
/// From `Fixtures/herdr-layout-list.json`, captured 15 Nov 2026 with the
/// layout and space names replaced (the repository is public).
public struct HerdrLayout: Sendable, Equatable, Identifiable, Decodable {
    public let name: String
    public let savedAt: Date?
    /// How many of its spaces are open in Herdr.app now; 0 when closed.
    public let openSpaces: Int
    /// Its spaces' labels, in order.
    public let spaces: [String]
    public let panes: Int
    /// Claude panes, resumed on restore.
    public let claude: Int

    public var id: String { name }

    /// Whether `name` is one the script accepts: a letter or digit, then up
    /// to 63 letters, digits, spaces, `.`, `_` or `-` (its `NAME_RE`). Checked
    /// here so the rename field can say so before anything is sent; the
    /// script checks again.
    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._ -]{0,63}/) != nil
    }
    /// Open as soon as any of its spaces is. **A partly open layout is not
    /// offered Restore, kept from review**: the script refuses it, since
    /// opening it again would run its Claude sessions twice; and `update`
    /// keeps the saved copy of every space that is not open, so Save Now
    /// loses none.
    public var isOpen: Bool { openSpaces > 0 }

    public init(name: String, savedAt: Date? = nil, openSpaces: Int = 0, spaces: [String] = [], panes: Int = 0, claude: Int = 0) {
        self.name = name
        self.savedAt = savedAt
        self.openSpaces = openSpaces
        self.spaces = spaces
        self.panes = panes
        self.claude = claude
    }

    private enum CodingKeys: String, CodingKey {
        case name, open, spaces, panes, claude
        case savedAt = "saved_at"
    }

    /// Lenient past the name: a count that is missing reads as none.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        savedAt = (try? values.decode(Double.self, forKey: .savedAt)).map { Date(timeIntervalSince1970: $0) }
        openSpaces = (try? values.decode(Int.self, forKey: .open)) ?? 0
        spaces = ((try? values.decode([String?].self, forKey: .spaces)) ?? []).compactMap { $0 }
        panes = (try? values.decode(Int.self, forKey: .panes)) ?? 0
        claude = (try? values.decode(Int.self, forKey: .claude)) ?? 0
    }

    /// The layouts in `herdr-layout list --json` output, newest first as the
    /// script sorts them.
    ///
    /// The JSON is the last line that starts with `[`, so a login shell's
    /// banner before it does no harm. **One line, kept from review**: the
    /// script prints it with `json.dumps` and this project owns both sides,
    /// and a login shell's banner comes before a command's output, not after.
    /// A record that does not read is skipped, not fatal to the list.
    ///
    /// - Throws: `DecodingError` when there is no list at all.
    public static func list(inOutput output: String) throws -> [HerdrLayout] {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("[") }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "herdr-layout printed no list"))
        }
        let records = try JSONDecoder().decode([HcJSON].self, from: Data(line.utf8))
        return records.compactMap { try? $0.decode(HerdrLayout.self) }
    }
}
