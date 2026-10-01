import Foundation

/// What a flick keeps doing after the finger lifts: the same wheel notches a
/// drag sends, at a speed that decays the way a scroll view's does.
///
/// **There is still no buffer under it.** A scroll view coasts over content it
/// already holds; this coasts over nothing, and every notch is a request the
/// host answers with a repaint — see `PaneModel.scroll`. What it buys is that a
/// flick carries on, which is what a swipe does in a desktop terminal attached
/// to herdr: the trackpad goes on sending wheel events while it decelerates.
///
/// A value type with no clock of its own, so the arithmetic can be tested
/// without waiting for it. `PaneScrollGesture` supplies the time.
struct ScrollMomentum {
    /// Points per second, signed like a drag's translation: positive is the
    /// finger moving down, which brings earlier output into view.
    private(set) var velocity: Double
    /// Distance coasted that has not yet added up to a notch.
    private var travel: Double
    /// Points per notch.
    private let step: Double

    /// The fraction of its speed a flick keeps each millisecond —
    /// `UIScrollView.DecelerationRate.normal`, so this coasts as far as every
    /// other list on the phone does.
    static let decay = 0.998
    /// Below this, in points per second, it has stopped. Without a floor the
    /// last few notches arrive seconds apart, long after anyone is watching.
    static let rest = 60.0
    /// The most notches a second, however hard the flick. Each one is a record
    /// the host repaints for, and a queue of them that outlives the gesture
    /// would go on scrolling a pane after the user has stopped.
    static let fastest = 150.0
    /// The longest gap one `advance` will account for. A task that was
    /// suspended for a second must not deliver that second as a single burst.
    static let longestTick = Duration.milliseconds(100)

    /// - Parameters:
    ///   - velocity: the drag's velocity as the finger lifted.
    ///   - step: points per notch; the drag's own step, so the content moves
    ///     as far per point coasting as it did under the finger.
    ///   - travel: what the drag had left over, short of a notch.
    init(velocity: Double, step: Double, carrying travel: Double = 0) {
        let step = max(step, 1)
        let limit = step * Self.fastest
        self.step = step
        self.velocity = min(max(velocity, -limit), limit)
        self.travel = travel
    }

    /// Whether there is anything left to send. True from the start for a
    /// finger that was lifted slowly, which is how a drag ends without a coast.
    var isFinished: Bool { abs(velocity) < Self.rest }

    /// Moves time on and returns the notches that fell due: positive for
    /// earlier output, negative for later.
    ///
    /// Integrated exactly rather than stepped, so the distance covered does not
    /// depend on how often this is called — a phone that drops frames coasts
    /// as far as one that does not.
    mutating func advance(by elapsed: Duration) -> Int {
        guard !isFinished else { return 0 }
        let milliseconds = max(0, min(elapsed, Self.longestTick) / .milliseconds(1))
        let kept = pow(Self.decay, milliseconds)
        travel += velocity / 1000 * (kept - 1) / log(Self.decay)
        velocity *= kept
        let notches = (travel / step).rounded(.towardZero)
        travel -= notches * step
        return Int(notches)
    }
}
