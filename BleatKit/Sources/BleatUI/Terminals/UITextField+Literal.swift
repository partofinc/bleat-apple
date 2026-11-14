#if canImport(UIKit) && !os(watchOS)
import UIKit

extension UITextField {
    /// Leaves what is typed as typed: no smart dashes, smart quotes or smart
    /// spacing, no capital at the start. Shared by `LiteralTextField` and
    /// `PaneLineField`, so a trait added later is added to both.
    func typesLiterally() {
        autocapitalizationType = .none
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
    }
}
#endif
