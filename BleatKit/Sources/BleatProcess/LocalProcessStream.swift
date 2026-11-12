// `Foundation.Process` does not exist on iOS, and a whole-package iOS build
// compiles every target whether or not it is vended as a product. The `#if` ban
// in CLAUDE.md applies to BleatKit, whose whole point is being platform-free;
// this target is for the machines that run herdr-core — macOS and Linux —, so
// guarding it is the honest way to say so rather than a workaround.
#if !os(iOS)
import BleatKit
import Foundation

/// A long-lived child process — `hc connect` — presented as a `DuplexStream`.
final class LocalProcessStream: DuplexStream, @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    /// Set before we terminate the child, so its exit is not read as a crash.
    private let closing = LockedBox(false)

    let output: AsyncThrowingStream<Data, any Error>

    init(executable: URL, args: [String], environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        output = stream

        // Drain stderr continuously. The host reports ignored input records
        // here without closing the stream, so it must not fill and block, and
        // it is the only place that explains a rejected command.
        let stderrBuffer = LockedBox(Data())
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.withLock { $0.append(chunk) }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }   // EOF handled on termination
            continuation.yield(chunk)
        }

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let closing = self.closing
        process.terminationHandler = { process in
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            // Anything buffered between the last read and exit.
            let tail = outHandle.availableData
            if !tail.isEmpty { continuation.yield(tail) }

            // A zero status is a clean end. A non-zero one is also clean when
            // we are the ones who terminated it: `hc connect` runs until its
            // stdin closes or it is signalled, and SIGTERM on detach must not
            // be reported as a failure.
            if process.terminationStatus == 0 || closing.current {
                continuation.finish()
            } else {
                continuation.finish(
                    throwing: ShellError(
                        command: ([executable.path] + args).joined(separator: " "),
                        exitCode: process.terminationStatus,
                        stderr: String(decoding: stderrBuffer.current, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }

        try process.run()
    }

    func send(_ data: Data) async throws {
        guard process.isRunning else { throw TransportError.channelClosed }
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw TransportError.channelClosed
        }
    }

    func close() async {
        let alreadyClosing = closing.withLock { was -> Bool in
            defer { was = true }
            return was
        }
        guard !alreadyClosing else { return }

        try? inPipe.fileHandleForWriting.close()
        // Give the host a moment to exit on its own after a release.
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
    }
}

#endif
