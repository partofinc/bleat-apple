import SwiftUI

extension View {
    /// Lets the text be selected and copied, where the platform has such a
    /// thing. The watch does not — `textSelection` is unavailable there — and
    /// this is the one place that says so.
    func selectable() -> some View {
        #if os(watchOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}
