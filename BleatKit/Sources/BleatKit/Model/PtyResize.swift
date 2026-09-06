/// Resizes the pty behind a pane, so a phone can be sent output already
/// wrapped to its own width.
///
/// **This is the only thing that actually reflows a pane.** `observe --cols`
/// crops rather than reflows, and no stream client can change a pane's grid —
/// both measured 6 Sept 2026. But the program inside the pane wraps its output
/// to *its pty*, and a pty can be resized from outside: `stty` on the tty sends
/// `SIGWINCH` and the program redraws at the new width. Verified end to end — a
/// pane's pty set to 40 columns and observed at 40 came back genuinely wrapped,
/// with a continuation line rather than a cut one.
///
/// **It is a write, and the only one Bleat does to a running program.** It
/// changes the width for whoever is at the Mac too, until they attach and their
/// own client sets it back. That is why it is only used to make a pane *fit* —
/// never to widen one that already does — and why it is never fatal: every
/// failure falls back to reading the pane at whatever size it already has.
public enum PtyResize {
    /// The size to set a pane's pty to, or `nil` when it should be left alone.
    ///
    /// **The pty must never be wider than herdr's own pane buffer.** herdr
    /// renders the pane at its layout rect and the program writes into that
    /// buffer, so a pty wider than the rect makes the program emit lines herdr
    /// then wraps — and the result is not a crop but genuine corruption:
    /// characters landing in the wrong columns, one-letter fragments down the
    /// far edge. Seen on device, in landscape, when a phone that could show 100
    /// columns asked a 54-column pane for 100.
    ///
    /// Narrower is safe, and is the whole point: the program wraps its own
    /// output to the phone's width, and `observe` at that width loses nothing
    /// because there is nothing beyond it. So the rule is one-directional —
    /// shrink to fit, never grow.
    ///
    /// One column of the rect belongs to herdr, measured rather than assumed: a
    /// 54-column rect is a 53-column pty.
    /// - Returns: `nil` when the pane already fits, which is when it must not be
    ///   touched — a session that is already phone-shaped, or a phone in
    ///   landscape looking at a narrow pane.
    public static func target(viewport: TerminalGrid, pane: TerminalGrid) -> TerminalGrid? {
        guard viewport.isUsable, pane.isUsable else { return nil }
        guard viewport.cols < pane.cols || viewport.rows < pane.rows else { return nil }
        let fit = TerminalGrid(
            cols: min(viewport.cols, pane.cols - 1),
            rows: min(viewport.rows, pane.rows)
        )
        return fit.isUsable ? fit : nil
    }

    /// - Parameters:
    ///   - pid: From `pane process-info`. Interpolated into a command the host
    ///     will run, so it is checked rather than trusted — it arrives as JSON
    ///     from the host, and the posture everywhere else in this package is to
    ///     refuse anything that is not obviously the shape expected.
    /// - Returns: `nil` when the pid is not a plausible process id.
    public static func command(pid: Int, cols: Int, rows: Int) -> String? {
        guard pid > 0, pid < 4_194_304, cols > 0, rows > 0,
              cols < 10_000, rows < 10_000
        else { return nil }
        // `ps` gives the tty as a name like `ttys013`; `??` means the process
        // has none, which is not an error worth failing over — a pane whose
        // program has no controlling terminal simply cannot be resized.
        //
        // `|| true` for the same reason: this is best effort. The stream opens
        // either way, and a pane that could not be resized is read at the size
        // it already had rather than not read at all.
        return """
            t=$(ps -o tty= -p \(pid) 2>/dev/null | tr -d ' '); \
            if [ -n "$t" ] && [ "$t" != "??" ]; then \
            stty -f "/dev/$t" rows \(rows) cols \(cols) 2>/dev/null; \
            fi; true
            """
    }
}
