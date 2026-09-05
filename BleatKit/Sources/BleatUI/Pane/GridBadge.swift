import SwiftUI

/// The size of the grid being rendered, in the corner of the pane.
///
/// Small, but it is the difference between "this app cuts my output off" and
/// "there is more over there". The terminal is now the pane's size rather than
/// the phone's, so on any real pane most of it is off-screen by design — and a
/// scroll indicator that appears only once you already know to drag is not an
/// affordance on its own.
///
/// It also has to say when it is *not* showing everything. A host that will not
/// report a layout leaves the stream sized to the phone, which crops, and
/// silently cropping is the thing this whole screen was changed to stop.
struct GridBadge: View {
    let grid: TerminalGrid
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
        isCropped ? "\(grid.cols)×\(grid.rows) cropped" : "\(grid.cols)×\(grid.rows)"
    }

    private var accessibilityLabel: String {
        isCropped
            ? "Showing \(grid.cols) by \(grid.rows) columns, cropped to this screen"
            : "\(grid.cols) by \(grid.rows) columns. Scroll to see the whole pane."
    }
}
