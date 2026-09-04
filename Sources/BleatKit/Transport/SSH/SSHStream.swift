import Citadel
import Foundation
import NIOCore

/// One `herdr` exec channel presented as a long-lived `HerdrStream`.
///
/// Citadel exposes a bidirectional exec only as a scoped closure, and it closes
/// the channel when that closure returns. So the closure is held open by a gate
/// and returns as soon as either the remote finishes or `close()` is called —
/// returning is the only way to actually tear the channel down. Cancelling the
/// task is not enough: a read-only `observe` never ends on its own, so without
/// this an unattended read-only attach would hang forever.
final class SSHStream: HerdrStream, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, any Error>

    private let writer = LockedBox<TTYStdinWriter?>(nil)
    /// Opens once the stdin writer exists, or once the attempt has failed.
    private let ready = AsyncGate()
    /// Opened by `close()`, or by the remote ending on its own.
    private let done = AsyncGate()
    private var task: Task<Void, Never>?
    /// Held so `close()` can end the stream without waiting on Citadel's
    /// channel teardown, which does not reliably return for a command that
    /// never exits on its own (a read-only `observe`).
    private let sink = LockedBox<AsyncThrowingStream<Data, any Error>.Continuation?>(nil)

    init(client: SSHClient, command: String, args: [String]) async {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        output = stream
        sink.withLock { $0 = continuation }

        let writer = self.writer
        let ready = self.ready
        let done = self.done
        // The client is not Sendable; the exec channel it opens is used only
        // inside this one task, so carrying it across is safe.
        let client = UnsafeTransfer(client)

        task = Task {
            // stderr explains an input record the host rejected, and is the
            // only detail a non-zero exit carries.
            let stderrBuffer = LockedBox(Data())
            // Set once the remote closed stdout of its own accord. After that
            // the channel is already gone, so Citadel's teardown throws
            // "Already closed" — a clean detach, not a failure.
            let drained = LockedBox(false)
            let failure = LockedBox<(any Error)?>(nil)

            do {
                try await client.value.withExec(command) { inbound, outbound in
                    writer.withLock { $0 = outbound }
                    ready.open()

                    // `inbound` is not Sendable and is consumed only here.
                    let inbound = UnsafeTransfer(inbound)
                    let pump = Task {
                        do {
                            for try await chunk in inbound.value {
                                switch chunk {
                                case .stdout(let buffer):
                                    continuation.yield(Data(buffer.readableBytesView))
                                case .stderr(let buffer):
                                    stderrBuffer.withLock { $0.append(contentsOf: buffer.readableBytesView) }
                                }
                            }
                            drained.withLock { $0 = true }
                        } catch is CancellationError {
                            // close() asked us to stop; not a failure.
                        } catch {
                            failure.withLock { $0 = error }
                        }
                        done.open()
                    }

                    // Whichever comes first: the remote ending, or a close.
                    await done.wait()
                    pump.cancel()
                }
            } catch {
                // Returning from `perform` closes an already-closed channel
                // when the remote exited first; that throw is not a failure.
                if !drained.current, failure.current == nil, !done.isOpen {
                    failure.withLock { $0 = error }
                }
            }

            ready.open()          // release anyone still waiting on a writer
            done.open()
            writer.withLock { $0 = nil }

            if let error = failure.current {
                if let failed = error as? SSHClient.CommandFailed {
                    continuation.finish(
                        throwing: LocalProcessTransport.error(
                            command: args,
                            exitCode: Int32(clamping: failed.exitCode),
                            stderr: stderrBuffer.current
                        )
                    )
                } else {
                    continuation.finish(throwing: TransportError.connectionFailed(String(describing: error)))
                }
            } else {
                continuation.finish()
            }
        }
    }

    func send(_ data: Data) async throws {
        await ready.wait()
        guard !done.isOpen, let outbound = writer.current else {
            throw TransportError.channelClosed
        }
        do {
            try await outbound.write(ByteBuffer(bytes: data))
        } catch {
            throw TransportError.channelClosed
        }
    }

    func close() async {
        // After `terminal.release` the host exits on its own; give it a brief
        // moment so the clean path stays the common one, then force the issue.
        for _ in 0..<20 {
            if done.isOpen { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        done.open()
        // End the stream ourselves rather than awaiting the task: tearing the
        // channel down can outlive the detach, and callers are iterating
        // `output` right now. finish() is idempotent, so the task's own call
        // is harmless.
        sink.withLock { $0?.finish(); $0 = nil }
        task?.cancel()
    }
}
