import Citadel
import Foundation
import NIOCore

/// One `herdr` exec channel presented as a long-lived `HerdrStream`.
///
/// Citadel exposes a bidirectional exec only as a scoped closure, so the
/// channel is held open inside a task and torn down when the remote command
/// exits or `close()` cancels it.
final class SSHStream: HerdrStream, @unchecked Sendable {
    /// Whether the stdin writer exists yet, plus anyone waiting for it.
    private enum Readiness {
        case waiting([CheckedContinuation<Void, Never>])
        case ready
        case failed
    }

    let output: AsyncThrowingStream<Data, any Error>

    private let writer = LockedBox<TTYStdinWriter?>(nil)
    private let readiness = LockedBox<Readiness>(.waiting([]))
    private var task: Task<Void, Never>?

    init(client: SSHClient, command: String, args: [String]) async {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        output = stream

        let writer = self.writer
        let readiness = self.readiness
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
            do {
                try await client.value.withExec(command) { inbound, outbound in
                    writer.withLock { $0 = outbound }
                    Self.settle(readiness, to: .ready)

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer):
                            continuation.yield(Data(buffer.readableBytesView))
                        case .stderr(let buffer):
                            stderrBuffer.withLock { $0.append(contentsOf: buffer.readableBytesView) }
                        }
                    }
                    drained.withLock { $0 = true }
                }
                Self.settle(readiness, to: .failed)   // release any late waiter
                continuation.finish()
            } catch is CancellationError {
                Self.settle(readiness, to: .failed)
                continuation.finish()
            } catch let failure as SSHClient.CommandFailed {
                Self.settle(readiness, to: .failed)
                continuation.finish(
                    throwing: LocalProcessTransport.error(
                        command: args,
                        exitCode: Int32(failure.exitCode),
                        stderr: stderrBuffer.current
                    )
                )
            } catch {
                Self.settle(readiness, to: .failed)
                if drained.current {
                    // The stream ended normally; only the teardown complained.
                    continuation.finish()
                } else {
                    continuation.finish(throwing: TransportError.connectionFailed(String(describing: error)))
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        await waitUntilReady()
        guard let outbound = writer.current else { throw TransportError.channelClosed }
        do {
            try await outbound.write(ByteBuffer(bytes: data))
        } catch {
            throw TransportError.channelClosed
        }
    }

    func close() async {
        // The host exits on its own after `terminal.release`; give it a beat
        // before cancelling so the clean path stays the common one.
        for _ in 0..<20 where task?.isCancelled == false {
            if case .failed = readiness.current { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        task?.cancel()
        writer.withLock { $0 = nil }
    }

    // MARK: - Readiness

    private static func settle(_ box: LockedBox<Readiness>, to value: Readiness) {
        let waiters = box.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard case .waiting(let pending) = state else { return [] }
            state = value
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilReady() async {
        await withCheckedContinuation { continuation in
            let resumeNow = readiness.withLock { state -> Bool in
                guard case .waiting(var pending) = state else { return true }
                pending.append(continuation)
                state = .waiting(pending)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
