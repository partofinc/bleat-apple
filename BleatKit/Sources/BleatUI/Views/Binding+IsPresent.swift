import SwiftUI

extension Binding where Value == Bool {
    /// True while `value` is set; set to false, it clears `value`. For a
    /// presentation driven by an optional: `isPresented: Binding(isPresent: $chosen)`.
    init<Wrapped>(isPresent value: Binding<Wrapped?>) {
        self.init(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}
