import SwiftUI

/// A pane's output as reflowed text — the experiment beside the terminal.
///
/// **This is a snapshot, and the screen has to say so.** `pane read` is a
/// one-shot: `observe`'s only options are `--cols` and `--rows`, so there is no
/// plain-text stream to subscribe to. Next to a terminal that updates live, a
/// page of text that quietly stopped being true is the kind of wrong that costs
/// someone a decision, hence the footer and the timestamp.
///
/// **What it gives up, measured on the 142-column pane in `Fixtures/`:** colour,
/// which in an agent pane is diff markers and state; box-drawn tables, which
/// come apart the moment a 142-column border is wrapped to a phone's width; and
/// paragraph shape, because an agent TUI hard-wraps its own prose to the pane
/// and those breaks survive into the text, so re-wrapping them here lands ragged.
/// What it buys is that nothing is off-screen sideways.
struct PaneReaderView: View {
    let lines: Loadable<[String]>
    let capturedAt: Date?
    let reload: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if case .stale(_, let message) = lines {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.bottom, 8)
                }
                ForEach(Array((lines.value ?? []).enumerated()), id: \.offset) { _, line in
                    // A blank line still needs to occupy a row: it is the
                    // paragraph break, and an empty `Text` collapses to nothing.
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.value != nil {
                    footer
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            // Monospaced *and* wrapping is the deliberate middle. A proportional
            // font would read better as prose and destroy the indentation an
            // agent uses structurally — the `⎿` tool results, the diff gutters.
            .textSelection(.enabled)
        }
        // The newest output is at the end, and it is what the pane was opened
        // to see. Opening at the top of a 400-line snapshot shows history.
        .defaultScrollAnchor(.bottom)
        .refreshable { await reload() }
        .overlay {
            if lines.value == nil, let message = lines.failureMessage {
                ContentUnavailableView {
                    Label("Could not read the pane", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await reload() } }
                }
            } else if case .loading = lines {
                ProgressView()
            } else if lines.value?.isEmpty == true {
                ContentUnavailableView {
                    Label("Nothing to read", systemImage: "text.alignleft")
                } description: {
                    Text("This pane has printed nothing yet.")
                }
                // Otherwise it covers the scroll view and swallows the pull
                // that would re-read — which is exactly the gesture someone
                // makes at an empty pane they just started something in.
                .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        Text(footerText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    private var footerText: String {
        guard let capturedAt else { return "Snapshot · pull to refresh" }
        let time = capturedAt.formatted(date: .omitted, time: .standard)
        return "Snapshot taken \(time) · pull to refresh"
    }
}
