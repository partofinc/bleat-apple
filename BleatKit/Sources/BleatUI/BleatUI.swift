import BleatKit
import SwiftUI

/// SwiftUI shared between app targets.
///
/// `BleatKit` stays free of SwiftUI so the transport and domain layers can be
/// linked by things that have no UI at all — the console tool today, an
/// extension or widget later. Views belong here instead.
///
/// Ordering deliberately does **not** live here: `sortedByAttention()` is in
/// `BleatKit` so the console tool and the views cannot disagree about it.
