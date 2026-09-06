import BleatKit
import SwiftUI

/// The agent's conversation, as the agent recorded it.
///
/// The third reading of one pane, and the only one that is not derived from the
/// terminal at all. The other two are the *screen* — 142 columns wide because
/// that is the pty, wrapped by the program that drew it, with its structure in
/// escape sequences. This is prose that was never drawn, so it reflows the way
/// text is supposed to, and a phone is a perfectly good place to read it.
///
/// It is a snapshot, like the reader, and for a harder reason: there is no
/// stream here either. Nothing watches the file.
struct PaneTranscriptView: View {
    let phase: TranscriptModel.Phase
    let capturedAt: Date?
    let reload: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(entries) { entry in
                    TranscriptTurn(entry: entry)
                }
                if !entries.isEmpty { footer }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .textSelection(.enabled)
        }
        // The newest turn is the one they came for.
        .defaultScrollAnchor(.bottom)
        .refreshable { await reload() }
        .overlay { status }
    }

    private var entries: [TranscriptEntry] {
        if case .loaded(let entries) = phase { return entries }
        return []
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle, .loading:
            ProgressView()
        case .loaded:
            EmptyView()
        // Its own case, and worded as a fact rather than a failure: a plain
        // shell pane has no transcript and never will, and an error page with
        // a "Try again" button would invite the user to keep asking.
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("No transcript", systemImage: "text.book.closed")
            } description: {
                Text(reason)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not read the transcript", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await reload() } }
            }
        }
    }

    private var footer: some View {
        Text(capturedAt.map {
            "Snapshot taken \($0.formatted(date: .omitted, time: .standard)) · pull to refresh"
        } ?? "Snapshot · pull to refresh")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }
}

/// One turn.
///
/// The two roles are told apart by weight and a label rather than by chat
/// bubbles: an agent's answer is often hundreds of words with code in it, and a
/// bubble that long stops being a bubble and starts being a bordered box that
/// wastes twenty points of a phone's width.
private struct TranscriptTurn: View {
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
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // Proportional, not monospaced — the whole reason this view exists.
            // The reader has to stay monospaced because it is showing a grid;
            // this is prose and was never wrapped to anything.
            Text(entry.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
