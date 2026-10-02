/// Whether this is a watch, for what follows from the size of its screen.
///
/// A phone can afford a bar under a list and a message laid over one. A watch
/// shows three rows at a time, so both go *into* the list there: anything
/// fixed to an edge is a third of the screen that never scrolls away, and
/// anything laid over the list cannot be scrolled at all.
///
/// A value rather than `#if` at each use, so both layouts can be drawn — and
/// rendered by a test — on either platform.
enum WatchLayout {
    static var isHere: Bool {
        #if os(watchOS)
        true
        #else
        false
        #endif
    }
}
