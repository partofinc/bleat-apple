#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Copying text, in the one place this target needs a platform branch.
///
/// `BleatUI` builds for macOS as well as iOS and the pasteboard is the only
/// API here that differs, so the branch is written once. It needs **both**
/// arms: a missing `#elseif` is not a compile error, it is a Copy button that
/// silently does nothing on one platform.
enum Pasteboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
