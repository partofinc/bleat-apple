import Foundation

/// A space in Herdr.app, as its layout document on a core says
/// (`Fixtures/hc-doc-herdr-app.json`).
///
/// Herdr.app keeps each machine's spaces in a core document named
/// `herdr-app` (`doc.get`), `{spaces: [{id, name, folder, tabs: [{id, name,
/// root}]}]}`, and shows a terminal only if it is labeled `herdr.space=<id>`.
/// A labeled terminal it is not showing yet it takes in on its next listing:
/// into that space, in a new tab unless `herdr.tab` names one (herdr-app
/// `src/window.rs`, `reconcile` and `adopt`; read 13 Nov 2026). Bleat only
/// reads the document; writing it is Herdr.app's.
public struct HerdrSpace: Sendable, Equatable, Identifiable {
    /// `sp…`, the value of the `herdr.space` label.
    public let id: String
    /// The name someone gave it; empty: Herdr.app names it after its folder.
    public let name: String
    /// Absolute, on the core's machine.
    public let folder: String

    public init(id: String, name: String, folder: String) {
        self.id = id
        self.name = name
        self.folder = folder
    }

    /// The document `doc.get` reads.
    public static let documentName = "herdr-app"

    /// What it is called, Herdr.app's way: its name, else its folder's last
    /// component (`~` for home).
    public func displayName(home: String?) -> String {
        if !name.isEmpty { return name }
        let folder = folder.droppingTrailingSlash
        if let home, folder == home.droppingTrailingSlash { return "~" }
        return folder.split(separator: "/").last.map(String.init) ?? folder
    }

    /// The spaces in `doc.get`'s reply, in Herdr.app's order. A core no
    /// Herdr.app has written to (a Pi, the demo host) has none; a space that
    /// does not read is left out rather than failing the list.
    public static func list(inReply reply: HcJSON) -> [HerdrSpace] {
        guard case .array(let spaces)? = reply["value"]?["spaces"] else { return [] }
        return spaces.compactMap { space in
            guard let id = space["id"]?.string, !id.isEmpty else { return nil }
            return HerdrSpace(id: id, name: space["name"]?.string ?? "", folder: space["folder"]?.string ?? "")
        }
    }

    /// The space a terminal in `directory` belongs in: the one whose folder
    /// holds it most closely. None when no space's folder holds it.
    ///
    /// Compared as written, so `directory` should be the host's own spelling
    /// (`HostDirectory.physical`): on a Mac a typed `~/developer` exists but
    /// would match no `Developer` folder.
    public static func matching(_ directory: String, in spaces: [HerdrSpace]) -> HerdrSpace? {
        spaces
            .filter { !$0.folder.isEmpty && Self.folder($0.folder, holds: directory) }
            .max { $0.folder.count < $1.folder.count }
    }

    private static func folder(_ folder: String, holds directory: String) -> Bool {
        let folder = folder.droppingTrailingSlash
        return directory == folder || directory.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
}
