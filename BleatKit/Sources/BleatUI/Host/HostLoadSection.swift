import BleatKit
import SwiftUI

/// The host's load as the first row of a list, on a screen with no room for
/// a bar — a watch.
///
/// **A row rather than `HostLoadBarModifier`'s bar because a bar does not
/// scroll.** Fixed to the bottom of a watch it was a third of the screen for
/// as long as the screen was up, over a list showing two rows. In the list it
/// is what the screen opens on and gone with the first turn of the crown.
///
/// **The row is held while the first reading is on its way**, which a bar has
/// no need of: a bar arriving late moves nothing, and a row arriving late
/// pushes the list down a second after it was drawn — under a finger that was
/// already on its way to a session. The read starts in the same turn the
/// list's rows land, so the two are drawn together.
///
/// Draws and nothing else, like the bar: the screen asks for the reading.
struct HostLoadSection: View {
    @Environment(AppContext.self) private var context
    let peer: PairedPeer

    var body: some View {
        if !WatchLayout.isHere {
            // The phone has the bar.
        } else if let load = context.hostLoad.load(for: peer) {
            Section {
                HostLoadBar(load: load, isCompact: true)
            }
        } else if context.hostLoad.isAwaitingFirstReading(for: peer) {
            Section {
                HostLoadBar(load: Self.placeholder, isCompact: true)
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The shape of a reading, for the row's height: one line and two gauges.
    private static let placeholder = HostLoad(
        cpuUsage: 0.5, memory: .init(used: 1, total: 2), disk: .init(used: 1, total: 2)
    )
}

// No `#Preview`: `HostLoadBar`'s "Compact" is this row in a list.
