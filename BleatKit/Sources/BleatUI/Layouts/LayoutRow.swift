#if os(iOS)
import BleatKit
import SwiftUI

/// One layout: its name, whether it is open, its spaces and what is in them.
struct LayoutRow: View {
    let layout: HerdrLayout
    /// What it is doing, while an action runs on it.
    let progress: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(layout.name).font(.headline)
                    if layout.isOpen {
                        Text("Open")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                if !layout.spaces.isEmpty {
                    Text(layout.spaces.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                details
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let progress {
                ProgressView()
                    .accessibilityLabel(progress)
            }
        }
        .contentShape(.rect)
        .foregroundStyle(.primary)
    }

    private var details: Text {
        let panes = layout.panes == 1 ? "1 pane" : "\(layout.panes) panes"
        let counts = layout.claude > 0 ? "\(panes) · \(layout.claude) Claude" : panes
        guard let progress else {
            guard let savedAt = layout.savedAt else { return Text(counts) }
            return Text("\(counts) · saved \(savedAt, format: .relative(presentation: .named))")
        }
        return Text(progress)
    }
}
#endif
