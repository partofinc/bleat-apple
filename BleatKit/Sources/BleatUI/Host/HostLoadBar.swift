import BleatKit
import SwiftUI

/// How busy the host is, at a glance: the processor on one line, memory and
/// disk as gauges under it.
///
/// Icons and values rather than labelled rows, because it rides along under
/// three screens whose lists are what the user came for. Each part is drawn
/// only if the host said it — a Mac has no temperature.
///
/// **On a watch it keeps the icons and drops the words**: the busy share
/// without the load average beside it, and each gauge's percentage without the
/// amount. It is also not a bar there but a row in the screen's list — see
/// `HostLoadSection` — so the compact form draws no glass and no margins of
/// its own; the row brings both.
struct HostLoadBar: View {
    let load: HostLoad
    /// `pi@adam`, heading the bar: which machine the numbers are about, and
    /// as whom this phone is on it. Not in the compact form, where the
    /// screen's own title already says.
    var login: String?
    /// `Raspberry Pi CM5`, trailing the login in secondary.
    var machine: String?
    /// Whether to leave out everything but one number per icon, and the bar's
    /// own chrome. Follows the platform; a parameter so both forms can be
    /// laid out anywhere.
    var isCompact = WatchLayout.isHere

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 8) {
            if !isCompact, let login {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: login)
                        .fontWeight(.semibold)
                        // The login is what says whose numbers these are;
                        // the machine gives way first.
                        .layoutPriority(1)
                    if let machine {
                        Spacer(minLength: 8)
                        Text(machine)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
            if cpuText != nil || temperatureText != nil {
                HStack(spacing: 4) {
                    if let cpuText = isCompact ? compactCPUText : cpuText {
                        Image(systemName: "cpu")
                            .foregroundStyle(.secondary)
                            // The text beside it says "Processor".
                            .accessibilityHidden(true)
                        Text(cpuText)
                            .accessibilityLabel("Processor")
                            .accessibilityValue(cpuText)
                    }
                    Spacer(minLength: isCompact ? 4 : 12)
                    if let temperatureText {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(temperatureText)
                            .accessibilityLabel("Temperature")
                            .accessibilityValue(temperatureText)
                    }
                }
                .lineLimit(1)
            }
            if load.memory != nil || load.disk != nil {
                HStack(alignment: .top, spacing: isCompact ? 10 : 16) {
                    if let memory = load.memory {
                        HostUsageGauge(
                            name: "Memory", symbol: "memorychip", usage: memory, style: .memory,
                            isCompact: isCompact
                        )
                    }
                    if let disk = load.disk {
                        HostUsageGauge(
                            name: "Disk", symbol: "internaldrive", usage: disk, style: .file,
                            isCompact: isCompact
                        )
                    }
                }
            }
        }
        .font(isCompact ? .caption2 : .caption)
        .monospacedDigit()
        .modifier(Chrome(isBar: !isCompact))
    }

    /// What makes it a bar: glass, and room around it. A row has its list's.
    private struct Chrome: ViewModifier {
        let isBar: Bool

        func body(content: Content) -> some View {
            if isBar {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(in: .rect(cornerRadius: 20))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            } else {
                content
            }
        }
    }

    /// One number for the processor: how busy it is, or the load average where
    /// the host did not say.
    var compactCPUText: String? {
        if let busy = load.cpuUsage {
            return busy.formatted(.percent.precision(.fractionLength(0)))
        }
        return load.loadAverage?.formatted(.number.precision(.fractionLength(2)))
    }

    /// `34% · load 2.61` — how much of the processor was busy over the last
    /// second, then the one-minute load average. Either may be missing.
    var cpuText: String? {
        let busy = load.cpuUsage?.formatted(.percent.precision(.fractionLength(0)))
        let average = load.loadAverage.map {
            "load \($0.formatted(.number.precision(.fractionLength(2))))"
        }
        let parts = [busy, average].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// In the phone's own unit: the host reports Celsius.
    var temperatureText: String? {
        load.temperature.map {
            Measurement(value: $0, unit: UnitTemperature.celsius).formatted(
                .measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0)))
            )
        }
    }
}

#if DEBUG
#Preview("Mac", traits: .sampleData) {
    List { Text("Sessions") }
        .safeAreaBar(edge: .bottom) {
            HostLoadBar(load: .sampleMac, login: "ravil@rawillk.air", machine: HostInfo.sampleMac.shortModel)
        }
}

/// The one with a temperature.
#Preview("Linux", traits: .sampleData) {
    List { Text("Sessions") }
        .safeAreaBar(edge: .bottom) {
            HostLoadBar(load: .sampleLinux, login: "pi@adam", machine: HostInfo.sampleLinux.shortModel)
        }
}

/// The watch's form, at about a watch's width: a row above the screen's own.
#Preview("Compact", traits: .sampleData) {
    List {
        Section { HostLoadBar(load: .sampleLinux, isCompact: true) }
        Section("Sessions") { Text("work") }
    }
    .frame(width: 190)
}

/// A host that answered half the probe gets half the bar.
#Preview("Partial", traits: .sampleData) {
    List { Text("Sessions") }
        .safeAreaBar(edge: .bottom) { HostLoadBar(load: HostLoad(loadAverage: 0.4)) }
}
#endif
