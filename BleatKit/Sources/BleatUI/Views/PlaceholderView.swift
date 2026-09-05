import SwiftUI

/// Stands in for a screen that lands in a later PR.
///
/// Explicit rather than an empty `Text("")`, so a route that is wired but not
/// yet built is obvious when tapping through the app.
struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "rectangle.dashed")
        } description: {
            Text("\(detail)\nNot built yet.")
        }
        .navigationTitle(title)
    }
}
