import Foundation
import Testing
@testable import BleatUI

/// The coast after a flick, which is arithmetic and nothing else — so it is
/// tested as arithmetic, with the time handed in rather than waited for.
@Suite("Scroll momentum")
struct ScrollMomentumTests {

    /// Runs a coast to its end at a fixed tick and returns the notches sent.
    private func coast(
        velocity: Double,
        step: Double = 17,
        carrying travel: Double = 0,
        tick: Duration = .milliseconds(16)
    ) -> Int {
        var momentum = ScrollMomentum(velocity: velocity, step: step, carrying: travel)
        var total = 0
        // Bounded, so a coast that never stops fails rather than hangs.
        for _ in 0..<10_000 where !momentum.isFinished {
            total += momentum.advance(by: tick)
        }
        #expect(momentum.isFinished, "the coast never came to rest")
        return total
    }

    /// The distance a decaying speed covers between `v` and the floor, which
    /// is what a scroll view coasts.
    private func distance(from velocity: Double) -> Double {
        (abs(velocity) - ScrollMomentum.rest) / 1000 / -log(ScrollMomentum.decay)
    }

    @Test("a flick coasts as far as a scroll view would")
    func coastsTheExpectedDistance() {
        let notches = coast(velocity: 1000)
        #expect(notches == Int(distance(from: 1000) / 17))
        #expect(notches > 20, "a flick this fast barely moved")
    }

    /// **The sign is the direction, and getting it backwards scrolls the wrong
    /// way after every flick.** Positive is the finger moving down, which is
    /// earlier output.
    @Test("a flick the other way coasts the other way")
    func keepsItsDirection() {
        #expect(coast(velocity: -1000) == -coast(velocity: 1000))
        #expect(coast(velocity: -1000) < 0)
    }

    /// A phone that drops frames must not coast further or shorter for it.
    @Test("the distance does not depend on the tick")
    func isFrameRateIndependent() {
        let smooth = coast(velocity: 1200, tick: .milliseconds(8))
        let dropped = coast(velocity: 1200, tick: .milliseconds(50))
        #expect(abs(smooth - dropped) <= 1)
    }

    /// A finger lifted slowly ends the drag where it is.
    @Test("a slow lift does not coast")
    func slowLiftIsFinished() {
        var momentum = ScrollMomentum(velocity: ScrollMomentum.rest - 1, step: 17)
        #expect(momentum.isFinished)
        #expect(momentum.advance(by: .seconds(1)) == 0)
    }

    /// Every notch is a record the host repaints for.
    @Test("a violent flick is held to the fastest rate")
    func isClamped() {
        let momentum = ScrollMomentum(velocity: 1_000_000, step: 17)
        #expect(momentum.velocity == 17 * ScrollMomentum.fastest)
        let other = ScrollMomentum(velocity: -1_000_000, step: 17)
        #expect(other.velocity == -17 * ScrollMomentum.fastest)
    }

    /// A task suspended for a while must not deliver the gap as one burst.
    @Test("a long gap counts as a short one")
    func longGapIsCapped() {
        var stalled = ScrollMomentum(velocity: 2000, step: 17)
        var prompt = ScrollMomentum(velocity: 2000, step: 17)
        #expect(
            stalled.advance(by: .seconds(5))
                == prompt.advance(by: ScrollMomentum.longestTick)
        )
    }

    /// What the drag had left, short of a notch, is not thrown away.
    @Test("leftover travel counts toward the first notch")
    func carriesTravel() {
        var fresh = ScrollMomentum(velocity: 500, step: 17)
        var carrying = ScrollMomentum(velocity: 500, step: 17, carrying: 16)
        #expect(fresh.advance(by: .milliseconds(4)) == 0)
        #expect(carrying.advance(by: .milliseconds(4)) == 1)
    }

    /// No grid yet, or a nonsense one, must not divide by nothing.
    @Test("a zero step does not trap")
    func zeroStep() {
        var momentum = ScrollMomentum(velocity: 100, step: 0)
        _ = momentum.advance(by: .milliseconds(16))
    }
}
