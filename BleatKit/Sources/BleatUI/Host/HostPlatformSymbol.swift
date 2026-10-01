import BleatKit
import SwiftUI

extension HostInfo.Platform {
    /// The mark shown beside a host.
    ///
    /// **SF Symbols has an Apple logo and no Raspberry Pi**, nor any mark for
    /// Linux. A Pi gets `berry`, a custom symbol in this package's catalog —
    /// a drawing of the fruit, and deliberately not the Raspberry Pi logo or
    /// anything close to it; see `Design/symbols.swift` for what their
    /// trademark rules allow. Other Linux hosts get a rack.
    var mark: Image {
        switch self {
        case .mac: Image(systemName: "apple.logo")
        case .raspberryPi: Image(Self.berry, bundle: .module)
        case .linux: Image(systemName: "server.rack")
        case .unknown: Image(systemName: "desktopcomputer")
        }
    }

    /// The custom symbol's name in `Resources/Symbols.xcassets`.
    static let berry = "berry"
}
