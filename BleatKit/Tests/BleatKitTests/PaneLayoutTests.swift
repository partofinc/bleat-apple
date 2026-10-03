import Foundation
import Testing
@testable import BleatKit

@Suite("Reading a pane's real grid")
struct PaneLayoutTests {

    /// Straight off the host: `herdr pane layout --pane w5:p1`, captured
    /// 5 Sept 2026. The numbers matter — 142 columns is the pane whose crop
    /// started all of this.
    @Test("the fixture decodes to the grid the host reported")
    func decodesTheFixture() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: ["pane layout --pane w5:p1": try Fixture.data("pane-layout.json")]
        ))
        let layout = try await client.paneLayout(target: "w5:p1")

        #expect(layout.tabID == "w5:t1")
        #expect(layout.workspaceID == "w5")
        let rect = try #require(layout.rect(ofPane: "w5:p1"))
        #expect(rect.width == 142)
        #expect(rect.height == 47)
    }

    /// The tab's `area` is not the pane's size. On the dev Mac `x` was 26 —
    /// herdr was drawing a sidebar — so a client that rendered at `area.width`
    /// starting at column 0 would be wrong about both.
    @Test("the tab's area is kept distinct from the pane's rect")
    func areaIsNotTheRect() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: ["pane layout --pane w5:p1": try Fixture.data("pane-layout.json")]
        ))
        let layout = try await client.paneLayout(target: "w5:p1")
        #expect(layout.area?.x == 26)
        #expect(layout.rect(ofPane: "w5:p1")?.x == 26)
    }

    /// A pane the layout does not mention. Rendering at some *other* pane's
    /// width would wrap every line, so there is no fallback here — the caller
    /// has to decide, and it does.
    @Test("a pane that is not in the layout has no rect")
    func unknownPane() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: ["pane layout --pane w5:p1": try Fixture.data("pane-layout.json")]
        ))
        let layout = try await client.paneLayout(target: "w5:p1")
        #expect(layout.rect(ofPane: "w5:p2") == nil)
        #expect(layout.rect(ofPane: "w2:p1") == nil)
    }

    /// The app reads a pane's `rect` and nothing else, and `PaneModel` falls
    /// back to the phone's size when the host will not report a layout. A
    /// `DecodingError` on a field nothing uses would jump straight over that
    /// fallback and kill the pane instead of cropping it — and CLAUDE.md's rule
    /// for herdr JSON is that a missing field is never fatal.
    @Test("a reply missing everything the app does not read still decodes")
    func toleratesAThinnerShape() throws {
        let json = Data("""
        {"panes": [{"pane_id": "w5:p1", "rect": {"width": 142, "height": 47}}]}
        """.utf8)
        let layout = try JSONDecoder().decode(PaneLayout.self, from: json)

        #expect(layout.rect(ofPane: "w5:p1")?.width == 142)
        #expect(layout.area == nil)
        #expect(layout.tabID == nil)
        // Defaulted rather than required: only width and height decide what the
        // phone asks the host to draw.
        #expect(layout.rect(ofPane: "w5:p1")?.x == 0)
    }

    /// The one thing that is still required. Without a `panes` array there is
    /// no pane to size to, and the caller's fallback is the right answer —
    /// which it reaches by finding no rect, not by throwing.
    @Test("a reply with no panes at all yields no rect rather than an error")
    func toleratesNoPanes() throws {
        let layout = try JSONDecoder().decode(PaneLayout.self, from: Data("{}".utf8))
        #expect(layout.panes.isEmpty)
        #expect(layout.rect(ofPane: "w5:p1") == nil)
    }

    /// A split tab holds several panes and the right one has to be picked.
    ///
    /// **Captured live, 7 Sept 2026** — `herdr pane split w2:p1 --direction
    /// right` in an isolated probe workspace, then `pane layout --pane w2:p1`.
    /// This closes CLAUDE.md's longest-standing open question: until now the
    /// split case was *derived* from the single-pane fixture, with the sibling
    /// synthesised, because a split had never been observed.
    ///
    /// The numbers are the point. The tab's `area` is 54 columns and each pane
    /// is **27** — so a client that rendered a split pane at `area.width`, the
    /// obvious mistake, would wrap every single line at double the real width.
    /// Looking the pane up by id is what avoids it.
    @Test("in a split tab, the pane is found by id and gets half the area")
    func splitTab() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: ["pane layout --pane w2:p1": try Fixture.data("pane-layout-split.json")]
        ))
        let layout = try await client.paneLayout(target: "w2:p1")

        #expect(layout.tabID == "w2:t1")
        #expect(layout.panes.count == 2)
        #expect(layout.area?.width == 54)
        #expect(layout.rect(ofPane: "w2:p1")?.width == 27)
        #expect(layout.rect(ofPane: "w2:p2")?.width == 27)
        // Side by side, so the second starts where the first ends.
        #expect(layout.rect(ofPane: "w2:p1")?.x == 0)
        #expect(layout.rect(ofPane: "w2:p2")?.x == 27)
    }

    /// A real split reply carries a `splits` array — a field nothing in the app
    /// reads and that no fixture had ever contained. Herdr JSON's rule is that
    /// unknown keys are ignored rather than fatal, and this is the first
    /// capture that actually exercises it on `pane layout`.
    @Test("an unread field in a real reply is ignored, not fatal")
    func toleratesSplitsField() throws {
        let raw = String(data: try Fixture.data("pane-layout-split.json"), encoding: .utf8)
        #expect(raw?.contains("\"splits\"") == true)
        let layout = try JSONDecoder().decode(
            HerdrEnvelope<PaneLayoutResult>.self, from: try Fixture.data("pane-layout-split.json")
        ).result.layout
        #expect(layout.panes.count == 2)
    }
}
