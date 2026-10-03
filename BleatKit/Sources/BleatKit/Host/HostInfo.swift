import Foundation

/// What a host is: the part of what it says about itself that does not change
/// between visits.
///
/// Kept on the peer record, so the host list can say what each machine is
/// without connecting to any of them. See `PairedPeer.hostInfo`.
///
/// **Every field is optional, and absence is an ordinary answer** — a Linux box
/// has no model name unless its firmware supplies one, and the herdr version is
/// missing until the phone has learned where herdr is.
public struct HostInfo: Sendable, Codable, Equatable {
    /// The kind of machine, as far as its own report says.
    public enum Platform: Sendable, Equatable {
        case mac
        /// Before `linux`: a Pi is a Linux host that says which board it is.
        case raspberryPi
        case linux
        case unknown
    }

    /// The operating system and its version: `macOS 27.0.1`,
    /// `Debian GNU/Linux 13 (trixie)`.
    public var system: String?
    /// The kernel and its release: `Darwin 27.0.0`, `Linux 6.18.50+rpt-rpi-2712`.
    public var kernel: String?
    /// `arm64`, `aarch64`, `x86_64` — as the host spells it.
    public var architecture: String?
    /// The machine: `MacBookAir10,1`, `Raspberry Pi Compute Module 5 Rev 1.0`.
    public var model: String?
    /// What the machine is sold as: `MacBook Air (M1, 2020)`. Only a Mac on
    /// Apple silicon says, through `ioreg`; an Intel Mac and a Linux box have
    /// only `model`.
    public var modelName: String?
    /// The herdr this phone's commands run, which is the client binary. A
    /// running server may be older until it is restarted.
    public var herdrVersion: String?

    public init(
        system: String? = nil,
        kernel: String? = nil,
        architecture: String? = nil,
        model: String? = nil,
        modelName: String? = nil,
        herdrVersion: String? = nil
    ) {
        self.system = system
        self.kernel = kernel
        self.architecture = architecture
        self.model = model
        self.modelName = modelName
        self.herdrVersion = herdrVersion
    }

    public var isEmpty: Bool { self == HostInfo() }

    /// From the kernel's name, and the model for a Pi. Not from `system`: that
    /// is a distribution's own free text.
    public var platform: Platform {
        if kernel?.hasPrefix("Darwin") == true { return .mac }
        if model?.localizedCaseInsensitiveContains("Raspberry Pi") == true { return .raspberryPi }
        if kernel?.hasPrefix("Linux") == true { return .linux }
        return .unknown
    }

    /// The machine in a few words, for a row: `MacBook Air (M1, 2020)`,
    /// `Raspberry Pi CM5`.
    ///
    /// The name it is sold as when the host gives one. Otherwise `model`,
    /// without a Pi's board revision and with "Compute Module" shortened to
    /// the CM that Raspberry Pi itself prints on the board.
    public var shortModel: String? {
        if let modelName, !modelName.isEmpty { return modelName }
        guard var model else { return nil }
        if let revision = model.range(of: #" Rev [0-9.]+$"#, options: .regularExpression) {
            model.removeSubrange(revision)
        }
        return model.replacingOccurrences(
            of: #"Compute Module ([0-9]+)"#, with: "CM$1", options: .regularExpression
        )
    }

    /// This, with whatever `newer` knows laid over it.
    ///
    /// **Field by field, and a missing field never erases a known one.** Each
    /// part of the probe fails alone, so a reply without a model is a tool that
    /// did not answer this time, not a host that has stopped being a MacBook.
    public func updated(with newer: HostInfo) -> HostInfo {
        HostInfo(
            system: newer.system ?? system,
            kernel: newer.kernel ?? kernel,
            architecture: newer.architecture ?? architecture,
            model: newer.model ?? model,
            modelName: newer.modelName ?? modelName,
            herdrVersion: newer.herdrVersion ?? herdrVersion
        )
    }
}
