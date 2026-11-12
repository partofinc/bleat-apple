import BleatKit
import SwiftUI

/// One herdr-core terminal in a host's list. Laid out like `AgentRow`.
struct HcTerminalRow: View {
    let terminal: HcTerminal

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(terminal.displayName)
                    .lineLimit(1)
                if let detail = terminal.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: terminal.symbolName)
                .foregroundStyle(terminal.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(terminal.displayName), \(terminal.stateLabel)")
        .accessibilityValue(terminal.detail ?? "")
    }
}

#if DEBUG
#Preview("Every state", traits: .sampleData) {
    List {
        ForEach(HcTerminal.samples) { terminal in
            HcTerminalRow(terminal: terminal)
        }
    }
}
#endif
