/// Where a tab's panes sit, from `herdr pane layout --pane <ID>`.
///
/// This exists to answer one question: **how wide is the pane really?**
/// `terminal session observe --cols N` is a viewport onto the pane's existing
/// grid, not a resize — it crops when narrower and pads when wider — so a phone
/// that asks for its own 53 columns silently loses everything to the right of
/// them. Asking the host for the grid it actually has is what lets the app
/// render all of it. Measured 5 Sept 2026: a 142-column pane asked for 53
/// returns 53 columns cut mid-word.
///
/// **The layout belongs to a tab, not to a workspace.** Verified live: `wA` has
/// two panes and `pane layout` for either returns a single-pane layout, because
/// they are in different tabs (`wA:t1`, `wA:t4`). A split tab puts more than
/// one entry in `panes`, which is why the pane is looked up by id rather than
/// assumed to be the only one.
public struct PaneLayout: Decodable, Sendable, Equatable {
    /// A rectangle in terminal cells — not points. `width` is columns.
    public struct Rect: Decodable, Sendable, Equatable, Hashable {
        public let width: Int
        public let height: Int
        /// Where the rectangle sits, for reading rather than for rendering.
        /// Defaulted rather than required: only `width` and `height` decide
        /// what the phone asks the host to draw, and a missing coordinate is
        /// not a reason to lose the pane.
        public let x: Int
        public let y: Int

        public init(width: Int, height: Int, x: Int = 0, y: Int = 0) {
            self.width = width
            self.height = height
            self.x = x
            self.y = y
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decode(Int.self, forKey: .width)
            height = try container.decode(Int.self, forKey: .height)
            x = try container.decodeIfPresent(Int.self, forKey: .x) ?? 0
            y = try container.decodeIfPresent(Int.self, forKey: .y) ?? 0
        }

        enum CodingKeys: String, CodingKey {
            case width, height, x, y
        }
    }

    /// One pane's place in the tab.
    public struct Placement: Decodable, Sendable, Equatable {
        public let paneID: String
        public let rect: Rect
        public let focused: Bool?

        public init(paneID: String, rect: Rect, focused: Bool? = nil) {
            self.paneID = paneID
            self.rect = rect
            self.focused = focused
        }

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case rect
            case focused
        }
    }

    /// **Everything except `panes` is optional, deliberately.** The app reads
    /// only a pane's `rect`, and `PaneModel` falls back to the phone's size
    /// when the host will not report a layout — a fallback that a
    /// `DecodingError` on a field nothing uses would jump straight over,
    /// killing the pane instead of cropping it. CLAUDE.md's rule for herdr
    /// JSON is that a missing field is never fatal.
    public let tabID: String?
    public let workspaceID: String?
    /// The whole tab. `x` is non-zero when herdr is drawing a sidebar — it was
    /// 26 on the dev Mac — which is why this is not the pane's own size.
    public let area: Rect?
    public let panes: [Placement]

    public init(tabID: String? = nil, workspaceID: String? = nil, area: Rect? = nil, panes: [Placement]) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.area = area
        self.panes = panes
    }

    /// The grid this pane is rendered on, or nil when the layout does not
    /// mention it.
    ///
    /// Looked up by id rather than taking the first entry: a split tab holds
    /// several, and rendering at a sibling's width would wrap every line.
    public func rect(ofPane paneID: String) -> Rect? {
        panes.first { $0.paneID == paneID }?.rect
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        area = try container.decodeIfPresent(Rect.self, forKey: .area)
        panes = try container.decodeIfPresent([Placement].self, forKey: .panes) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case area
        case panes
    }
}
