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
        #expect(layout.area.x == 26)
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

    /// A split tab holds several panes and the right one has to be picked.
    ///
    /// **Derived from the captured fixture rather than captured**, and that is
    /// a real gap: no split has ever been observed live. `wA` has two panes but
    /// they are in different tabs (`wA:t1`, `wA:t4`), and a split could not be
    /// made to capture — `herdr session attach` refuses from inside a herdr
    /// pane ("nested herdr is disabled by default"), and creating one in the
    /// live `work` session is out of bounds. So the shape here is the host's;
    /// only the second entry is synthesised.
    @Test("in a split tab, the pane is found by id rather than by position")
    func splitTab() throws {
        let real = try JSONDecoder().decode(
            HerdrEnvelope<PaneLayoutResult>.self, from: try Fixture.data("pane-layout.json")
        ).result.layout
        let sibling = PaneLayout.Placement(
            paneID: "w5:p2",
            rect: PaneLayout.Rect(width: 70, height: 47, x: 98, y: 1)
        )
        let split = PaneLayout(
            tabID: real.tabID,
            workspaceID: real.workspaceID,
            area: real.area,
            // The target second, so taking `panes.first` cannot pass.
            panes: [sibling] + real.panes
        )

        #expect(split.rect(ofPane: "w5:p1")?.width == 142)
        #expect(split.rect(ofPane: "w5:p2")?.width == 70)
    }
}
