import BleatKit
import SwiftUI

/// The agent's conversation, shaped like a chat.
///
/// The reading of a pane that is not the *screen*. The terminal is 142 columns
/// because that is the pty, wrapped by whatever drew it, with its structure in
/// escape sequences. This never went through a terminal: herdr does not have it
/// and cannot, since
/// everything herdr knows about an agent it read off the rendered buffer. What
/// herdr provides is the pointer, and the agent wrote the rest for itself.
///
/// Which is why this is the one view that reflows properly on a phone, and why
/// it is what an agent screen opens to.
///
/// **Read-only, and there is deliberately no composer.** Sending is
/// `agent prompt`, that is Phase 3, and writing to a running agent on someone's
/// Mac deserves its own deliberate step rather than arriving as a side effect
/// of a screen that is nicer to read.
struct PaneChatView: View {
    let phase: TranscriptModel.Phase
    let status: AgentStatus?
    /// What the load is doing. A bare spinner through four round trips and a
    /// couple of hundred kilobytes is indistinguishable from a hang.
    let step: String?
    let capturedAt: Date?
    let reload: () async -> Void
    /// Offered from the empty state. A pane with no transcript — a plain shell,
    /// an agent that keeps none — would otherwise land the user on a dead
    /// screen with the way out only in a toolbar icon.
    /// Nil where there is no terminal to show — the watch.
    let showTerminal: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Shown above the turns rather than instead of them.
                if case .stale(_, let message) = phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(entries) { entry in
                    ChatTurn(entry: entry)
                }
                if !entries.isEmpty { footer }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .selectable()
        }
        // The newest turn is the one they came for.
        .defaultScrollAnchor(.bottom)
        .refreshable { await reload() }
        .overlay { status_ }
    }

    private var entries: [TranscriptEntry] {
        switch phase {
        case .loaded(let entries), .stale(let entries, _): entries
        default: []
        }
    }

    @ViewBuilder
    private var status_: some View {
        switch phase {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                if let step {
                    Text(step)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .loaded, .stale:
            EmptyView()
        // Its own case, and worded as a fact rather than a failure: a plain
        // shell pane has no transcript and never will, so an error page with a
        // "Try again" button would invite the user to keep asking.
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("No conversation here", systemImage: "text.book.closed")
            } description: {
                Text(reason)
            } actions: {
                if let showTerminal {
                    Button("Show the terminal", action: showTerminal)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not read the conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await reload() } }
                if let showTerminal {
                    Button("Show the terminal", action: showTerminal)
                }
            }
        }
    }

    /// What the agent is doing, and how old this is.
    ///
    /// Both, because either alone misleads. "working" without an age suggests
    /// the view is live, and it is a snapshot — there is no stream behind it,
    /// only a long poll that re-reads when the agent settles.
    private var footer: some View {
        HStack(spacing: 6) {
            if status == .working {
                ProgressView().controlSize(.mini)
            }
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(status == .blocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var footerText: String {
        let age = capturedAt.map { "read \($0.formatted(date: .omitted, time: .shortened))" }
            ?? "snapshot"
        return switch status {
        case .working: "working — \(age), updates when it settles"
        case .blocked: "waiting for you at the Mac — \(age)"
        case .done: "done — \(age)"
        case .idle: "idle — \(age), pull to refresh"
        case .unknown, nil: "\(age) · pull to refresh"
        }
    }
}

/// One turn.
///
/// The two roles are told apart by a label and weight rather than by chat
/// bubbles: an agent's answer is often hundreds of words with code in it, and a
/// bubble that long stops being a bubble and becomes a bordered box that wastes
/// twenty points of a phone's width.
private struct ChatTurn: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.role == .user ? "You" : "Agent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.role == .user ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if entry.isSidechain {
                    // Not the agent on screen. Without saying so, a subagent's
                    // report reads as the agent contradicting itself.
                    Text("subagent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Spacer(minLength: 0)
                if let timestamp = entry.timestamp {
                    Text(timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // Proportional, not monospaced — the whole reason this view
            // exists. The terminal beside it has to stay monospaced because it
            // is showing a grid; this is prose that was never wrapped to
            // anything.
            Text(entry.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
#Preview("Conversation", traits: .sampleData) {
    NavigationStack {
        PaneChatView(
            phase: .loaded(TranscriptEntry.samples), status: .idle, step: nil,
            capturedAt: .now, reload: {}, showTerminal: {}
        )
    }
}

/// Working: a spinner in the footer and a line saying the view will update when
/// the agent settles. Both, because either alone misleads — there is no stream
/// behind this, only a long poll.
#Preview("Working", traits: .sampleData) {
    PaneChatView(
        phase: .loaded(TranscriptEntry.samples), status: .working, step: nil,
        capturedAt: .now, reload: {}, showTerminal: {}
    )
}

#Preview("Blocked", traits: .sampleData) {
    PaneChatView(
        phase: .loaded(TranscriptEntry.samples), status: .blocked, step: nil,
        capturedAt: .now, reload: {}, showTerminal: {}
    )
}

/// The step matters: four round trips and a couple of hundred kilobytes behind
/// a bare spinner is indistinguishable from a hang.
#Preview("Loading", traits: .sampleData) {
    PaneChatView(
        phase: .loading, status: nil, step: "reading the transcript…",
        capturedAt: nil, reload: {}, showTerminal: {}
    )
}

/// A plain shell pane has no transcript and never will, so this is worded as a
/// fact rather than as a failure — and offers the terminal instead of a retry.
#Preview("No conversation", traits: .sampleData) {
    PaneChatView(
        phase: .unavailable("This pane is a shell, not an agent, so there is no conversation to read."),
        status: nil, step: nil, capturedAt: nil, reload: {}, showTerminal: {}
    )
}

#Preview("Failed", traits: .sampleData) {
    PaneChatView(
        phase: .failed("the connection closed before this finished"),
        status: nil, step: nil, capturedAt: nil, reload: {}, showTerminal: {}
    )
}

/// A refresh that dropped over a chat that had already arrived. The turns stay.
#Preview("Stale", traits: .sampleData) {
    PaneChatView(
        phase: .stale(TranscriptEntry.samples, "the connection closed"),
        status: .idle, step: nil, capturedAt: .now.addingTimeInterval(-1_200),
        reload: {}, showTerminal: {}
    )
}
#endif
