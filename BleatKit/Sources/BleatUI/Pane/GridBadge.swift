import SwiftUI

/// The size being rendered, and what it is a crop of.
///
/// The pane is asked for at this phone's width now, and `observe --cols` crops
/// rather than reflows — re-verified 6 Sept 2026 with a line of `A`x60 + `B`x60
/// + `C`x54 into a 174-column pane, which at `--cols 60` came back with the B's
/// and C's simply gone. So on any real pane this screen is showing part of one,
/// and silently cropping is precisely what this whole area of the app was
/// changed to stop doing.
///
/// Hence "53×20 of 142×47" rather than a bare size: the second number is the
/// only thing that tells the user something is missing, and how much.
struct GridBadge: View {
    let grid: TerminalGrid
    /// The pane's real grid, when the host would say. `nil` on a host that will
    /// not report a layout — then there is no honest claim to make about what
    /// is hidden, so the badge says only what it is showing.
    let paneGrid: TerminalGrid?

    var body: some View {
        Text(label)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(isCropped ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: .capsule)
            .padding(8)
            // The pane underneath scrolls, and a label is not worth catching a
            // drag that was meant for it.
            .allowsHitTesting(false)
            .accessibilityLabel(accessibilityLabel)
    }

    private var isCropped: Bool {
        guard let paneGrid else { return false }
        return grid.cols < paneGrid.cols || grid.rows < paneGrid.rows
    }

    private var label: String {
        guard isCropped, let paneGrid else { return "\(grid.cols)×\(grid.rows)" }
        return "\(grid.cols)×\(grid.rows) of \(paneGrid.cols)×\(paneGrid.rows)"
    }

    private var accessibilityLabel: String {
        guard isCropped, let paneGrid else {
            return "\(grid.cols) columns by \(grid.rows) rows, the whole pane"
        }
        return "Showing \(grid.cols) columns by \(grid.rows) rows "
            + "of a pane that is \(paneGrid.cols) by \(paneGrid.rows). "
            + "The rest is cut off; rotate for more."
    }
}
