#if canImport(UIKit)
import SwiftUI
import UIKit

/// Puts `PaneKeyBar` above the system keyboard.
///
/// The arrows, `esc` and Enter are needed *most* while typing — they are how an
/// agent's dialog is navigated and how a line is submitted — so leaving them in
/// the safe area, where the keyboard would bury them, would take them away at
/// the one moment they matter. `PaneSurface` drops its own copy while this one
/// is up, or there would be two.
///
/// It is the same SwiftUI view either way rather than a UIKit re-implementation:
/// two bars would drift, and the keys are the part that must not.
final class KeyBarAccessoryView: UIView {
    private let host: UIHostingController<PaneKeyBar>

    init(model: PaneModel) {
        host = UIHostingController(rootView: PaneKeyBar(model: model))
        super.init(frame: .zero)
        // The bar draws its own glass; a background here would sit behind it as
        // an opaque band the width of the screen.
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // **Required for a self-sizing accessory.** Without it UIKit takes the
        // view's frame height, which is zero here, and the bar never appears.
        // With it, `intrinsicContentSize` below is consulted instead — which is
        // what lets the caps grow with Dynamic Type rather than being clipped
        // by a hard-coded height.
        autoresizingMask = .flexibleHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            // `bounds.width` is zero until UIKit has laid this out once, and
            // SwiftUI needs *some* width to measure against; a phone's is a
            // safe floor, and the real one supersedes it on the next pass.
            height: host.sizeThatFits(
                in: CGSize(
                    width: bounds.width > 0 ? bounds.width : 320,
                    height: .greatestFiniteMagnitude
                )
            ).height
        )
    }

    /// Dynamic Type can change while the keyboard is up.
    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}
#endif
