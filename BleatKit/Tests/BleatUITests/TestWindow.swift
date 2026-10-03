#if canImport(UIKit)
import UIKit

/// A window for laying a view out for real.
///
/// **On the test process's scene when it has one, and by frame when it does
/// not — which, today, is always.** `UIWindow(frame:)` is deprecated in iOS 26
/// in favour of `init(windowScene:)`, but these tests run hostless: `xctest`
/// connects no scene (tried 3 Oct 2026 — `connectedScenes` is empty), so a
/// scene-based window cannot be made at all. The frame-based one still lays
/// out, takes traits and becomes key, which is everything these tests need.
///
/// Called through `FrameWindow` so the one deliberate use is here rather than
/// a deprecation warning at every test that needs a window.
@MainActor
enum TestWindow {
    static func make(frame: CGRect) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        if let scene {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        return (UIWindow.self as any FrameWindow.Type).init(frame: frame) as! UIWindow
    }
}

private protocol FrameWindow { init(frame: CGRect) }
extension UIWindow: FrameWindow {}
#endif
