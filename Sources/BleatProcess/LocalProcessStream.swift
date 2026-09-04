import BleatKit
import Foundation

/// A long-lived `herdr` child process presented as a `HerdrStream`.
final class LocalProcessStream: HerdrStream, @unchecked Sendable {
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

            // `terminal.release` makes the host close the stream and exit 0,
            // so a zero status is a clean detach. A non-zero status is also
            // clean when we are the ones who terminated it: a read-only
            // `observe` never exits on its own, so detaching means signalling
            // it, and SIGTERM must not be reported as a failure.
            if process.terminationStatus == 0 || closing.current {
                continuation.finish()
            } else {
                continuation.finish(
                    throwing: HerdrError.fromStderr(
                        command: args,
                        exitCode: process.terminationStatus,
                        stderr: stderrBuffer.current
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
