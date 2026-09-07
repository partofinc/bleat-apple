import BleatKit
import SwiftUI

/// The size of the grid being rendered, in the corner of the pane.
///
/// The whole pane is on screen now — the font is fitted to it rather than the
/// columns cut — so this is mostly saying how big the thing you are looking at
/// is, and why the type is that small.
///
/// It still has to say when it is *not* showing everything. A host that will not
/// report a layout leaves the stream sized to the phone, and `observe --cols`
/// crops rather than reflows, so that case really does hide output.
struct GridBadge: View {
    let grid: TerminalGrid
    /// True when this is the phone's guess rather than the pane's real grid,
    /// because the host would not report a layout. That is the only case left
    /// where something is actually hidden: normally the whole pane is on
    /// screen, small, and the badge is just telling you how big it is.
    let isCropped: Bool

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

    private var label: String {
        let size = "\(grid.cols)×\(grid.rows)"
        return isCropped ? "\(size) cropped" : size
    }

    private var accessibilityLabel: String {
        isCropped
            ? "\(grid.cols) columns by \(grid.rows) rows, cropped to this screen "
                + "because the host did not report the pane's size"
            : "\(grid.cols) columns by \(grid.rows) rows."
    }
}

#if DEBUG
/// Both readings. The plain one says how big the thing on screen is; the orange
/// one says output is actually being hidden, which happens only when the host
/// would not report a layout and `observe --cols` fell back to cropping.
#Preview("Grid badge", traits: .sampleData) {
    VStack(alignment: .trailing, spacing: 12) {
        GridBadge(grid: TerminalGrid(cols: 142, rows: 47), isCropped: false)
        GridBadge(grid: TerminalGrid(cols: 53, rows: 40), isCropped: true)
    }
    .padding()
    .background(.black)
}
#endif
