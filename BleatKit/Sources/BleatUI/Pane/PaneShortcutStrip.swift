#if canImport(UIKit) && !os(watchOS)
import BleatKit
import SwiftUI

/// The keys a phone's keyboard does not have, as a row that scrolls sideways.
///
/// It is also what sits above the keyboard while typing straight into the
/// pane, which is where Tab and Ctrl-C are wanted most: a shell's completion
/// is the reason to type there at all.
struct PaneShortcutStrip: View {
    let model: PaneModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(PaneShortcut.all) { shortcut in
                    Button {
                        Task { await model.send(shortcut.keys, spacedBy: PaneShortcut.pause) }
                    } label: {
                        Text(shortcut.label)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minWidth: 44, maxHeight: .infinity)
                            .background(.fill.tertiary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(shortcut.endsTheProgram ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .accessibilityLabel(shortcut.name)
                }
            }
        }
        .scrollIndicators(.hidden)
        .clipShape(.capsule)
        // A key pressed with no stream is dropped by `PaneModel.send` anyway,
        // and a dead tap that looks live is worse than a greyed one.
        .disabled(model.phase != .live)
    }
}

#if DEBUG
#Preview("Shortcuts", traits: .sampleData) {
    PaneShortcutStrip(model: PaneModel(previewing: .live))
        .frame(height: 38)
        .padding()
}
#endif
#endif
