import BleatKit
import SwiftUI

/// How much of something is used: an icon, the amount with its share in
/// brackets, and a bar under them.
struct HostUsageGauge: View {
    /// What is being measured, for VoiceOver — the icon says it to the eye.
    let name: String
    let symbol: String
    let usage: HostLoad.Usage
    /// `.memory` counts in powers of 1024, as RAM is sold; `.file` in powers
    /// of 1000, as disks are.
    let style: ByteCountFormatStyle.Style
    /// The share alone, without the amount — see `HostLoadBar.isCompact`.
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ProgressView(value: usage.fraction)
                .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(text)
    }

    /// `13.1 GB (82%)`.
    var text: String {
        let used = usage.used.formatted(.byteCount(style: style))
        let share = usage.fraction.formatted(.percent.precision(.fractionLength(0)))
        if isCompact { return share }
        return "\(used) (\(share))"
    }

    /// Says "nearly full" before anyone has read the number.
    private var tint: Color {
        switch usage.fraction {
        case 0.9...: .red
        case 0.75...: .orange
        default: .accentColor
        }
    }
}

#if DEBUG
#Preview("Gauges", traits: .sampleData) {
    VStack(spacing: 16) {
        HostUsageGauge(
            name: "Memory", symbol: "memorychip",
            usage: .init(used: 6_000_000_000, total: 17_179_869_184), style: .memory
        )
        HostUsageGauge(
            name: "Memory", symbol: "memorychip",
            usage: .init(used: 14_080_163_840, total: 17_179_869_184), style: .memory
        )
        HostUsageGauge(
            name: "Disk", symbol: "internaldrive",
            usage: .init(used: 470_000_000_000, total: 494_353_338_368), style: .file
        )
    }
    .font(.caption)
    .padding()
}
#endif
