import BleatKit
import SwiftUI

/// One terminal on the watch: its state, what it says it is doing, and the
/// bottom of its screen as text. Read through the phone; nothing is typed.
struct RelayedTerminalScreen: View {
    let title: String
    @State private var model: RelayedTerminalModel
    @Environment(\.scenePhase) private var scenePhase

    init(title: String, model: RelayedTerminalModel) {
        self.title = title
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            if let record = model.record {
                Section {
                    HcTerminalRow(terminal: record)
                }
            }
            switch model.phase {
            case .loading:
                ProgressView()
            case .ended:
                Text("This terminal has ended.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .live:
                Section("Screen") {
                    Text(model.lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(nil)
                }
            }
        }
        .navigationTitle(title)
        .task { await model.run() }
        // Only a raised watch is someone reading it (`HcSeen`).
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setInFront(phase == .active)
        }
    }
}

#if DEBUG
#Preview("Terminal", traits: .sampleData) {
    NavigationStack {
        RelayedTerminalScreen(title: "Backend", model: RelayedTerminalModel(address: "t58", call: { method, _ in
            switch method {
            case "terminal.get":
                .object(["address": .string("t58"), "state": .string("live"), "turn": .number(3),
                         "status": .object(["state": .string("blocked"), "app": .string("claude-code"),
                                            "msg": .string("Allow Bash: swift test?"), "reason": .string("permission")])])
            case "terminal.read":
                .object(["text": .string("Do you want to proceed?\n❯ 1. Yes\n  2. No")])
            default:
                .object([:])
            }
        }))
    }
}
#endif
