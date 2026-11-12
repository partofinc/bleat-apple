import Foundation

/// Why a terminal could not be attached before anything was asked of hc.
enum HcPaneFailure: Error, CustomStringConvertible {
    case notChecked
    case noRoute

    var description: String {
        switch self {
        case .notChecked: "this host has not been checked for herdr-core"
        case .noRoute: "herdr-core is not reachable this way yet"
        }
    }
}
