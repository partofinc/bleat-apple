import BleatKit
import Darwin
import Foundation

/// The Phase 1 renderer: hand the host's ANSI straight to a real terminal.
/// If it looks right here, SwiftTerm will render it in Phase 2.
enum Attach {
    /// Ctrl-] — the detach key, same as telnet.
    static let detachByte: UInt8 = 0x1D

    static func run(
        client: HerdrClient,
        target: String,
        cols: Int,
        rows: Int,
        takeover: Bool
    ) async throws {
        // Prefer the real window size over the defaults.
        let size = terminalSize() ?? (cols: cols, rows: rows)

        let stream = takeover
            ? try await client.attach(to: target, cols: size.cols, rows: size.rows, takeover: true)
            : try await client.observe(target, cols: size.cols, rows: size.rows)

        let restore = enableRawMode()
        defer { restore?() }

        FileHandle.standardError.write(Data(
            "\u{1B}[2m-- attached to \(target) (\(size.cols)x\(size.rows))\(takeover ? " [takeover]" : " [read-only]"); Ctrl-] to detach --\u{1B}[0m\r\n".utf8
        ))

        // Always read stdin, even read-only: raw mode clears ISIG so Ctrl-C
        // raises no signal, and without a reader there would be no way out of
        // the default attach short of killing the process from another shell.
        // Keystrokes are only forwarded when we own input.
        let input = forwardInput(to: stream, forwardKeys: takeover)
        let resize = watchForResize(stream: stream)

        do {
            for try await record in stream.records {
                guard case .frame(let frame) = record, let bytes = frame.data else { continue }
                // Untouched: the cursor position lives inside these escapes.
                FileHandle.standardOutput.write(bytes)
            }
        } catch {
            input.cancel()
            resize.cancel()
            await stream.close()
            throw error
        }

        input.cancel()
        resize.cancel()
        await stream.close()
    }

    /// Reads stdin on a background thread, watching for the detach key.
    ///
    /// - Parameter forwardKeys: Relay keystrokes as `terminal.input`. False for
    ///   a read-only attach, where Ctrl-] must still work but nothing else may
    ///   reach the pane. Bytes, not text: arrows and control keys have no text
    ///   spelling.
    private static func forwardInput(
        to stream: any HerdrStream,
        forwardKeys: Bool
    ) -> Task<Void, Never> {
        Task.detached {
            let handle = FileHandle.standardInput
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let index = chunk.firstIndex(of: detachByte) {
                    let head = chunk[chunk.startIndex..<index]
                    if forwardKeys, !head.isEmpty {
                        try? await stream.send(.bytes(Data(head)))
                    }
                    // Only an input owner can release. Either way, closing the
                    // stream ends the frame loop — otherwise a read-only attach
                    // would sit here forever, since the host streams happily on.
                    if forwardKeys { try? await stream.send(.release) }
                    await stream.close()
                    return
                }
                if forwardKeys { try? await stream.send(.bytes(chunk)) }
            }
        }
    }

    /// Tells the host when the window changes, so the pane re-renders at the
    /// new geometry instead of staying at the size we attached with.
    private static func watchForResize(stream: any HerdrStream) -> DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)          // handled by the dispatch source
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler {
            guard let size = terminalSize() else { return }
            Task { try? await stream.send(.resize(cols: size.cols, rows: size.rows)) }
        }
        source.resume()
        return source
    }

    // MARK: - Terminal

    private static func terminalSize() -> (cols: Int, rows: Int)? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    /// Puts the terminal in raw mode so keystrokes reach the host unbuffered.
    /// Returns a closure restoring the previous state, or nil if stdin is not a tty.
    private static func enableRawMode() -> (() -> Void)? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }

        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }

        return {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restore)
        }
    }
}
