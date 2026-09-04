import Foundation

/// Which host a command runs against.
public enum HostSelection: Sendable, Equatable {
    /// Spawn `herdr` on this machine.
    case local
    /// Reach a saved host over SSH.
    case saved(HostEntry)
}

public enum HostArgumentError: Error, Sendable, Equatable {
    /// A leading argument looked like a host name but matches no saved host.
    ///
    /// This must be an error rather than a silent fallback to `.local`: a typo
    /// would otherwise run against the wrong machine and look like it worked.
    case unknownHost(String, known: [String])
    case missingTarget
    case unexpectedArguments([String])
}

/// Splits a command's positional arguments into a host and the rest.
///
/// The host argument is optional, which is what makes an unrecognized name
/// ambiguous — hence the explicit rules here rather than a `guard` at the call
/// site that falls through to local on any miss.
public enum HostArguments {

    /// - Parameters:
    ///   - positional: Arguments after the subcommand.
    ///   - expectsTarget: True for `attach`, which takes `[host] <target>`.
    ///   - hosts: Saved hosts.
    public static func resolve(
        positional: [String],
        expectsTarget: Bool,
        hosts: [HostEntry]
    ) throws -> (host: HostSelection, rest: [String]) {
        let names = hosts.map(\.name).sorted()
        func saved(_ name: String) -> HostEntry? { hosts.first { $0.name == name } }

        if expectsTarget {
            switch positional.count {
            case 0:
                throw HostArgumentError.missingTarget
            case 1:
                // A lone argument is the target — unless it names a host, in
                // which case the target is what is actually missing.
                if saved(positional[0]) != nil { throw HostArgumentError.missingTarget }
                return (.local, positional)
            case 2:
                guard let entry = saved(positional[0]) else {
                    throw HostArgumentError.unknownHost(positional[0], known: names)
                }
                return (.saved(entry), Array(positional.dropFirst()))
            default:
                throw HostArgumentError.unexpectedArguments(Array(positional.dropFirst(2)))
            }
        }

        switch positional.count {
        case 0:
            return (.local, [])
        case 1:
            guard let entry = saved(positional[0]) else {
                throw HostArgumentError.unknownHost(positional[0], known: names)
            }
            return (.saved(entry), [])
        default:
            throw HostArgumentError.unexpectedArguments(Array(positional.dropFirst(1)))
        }
    }
}
