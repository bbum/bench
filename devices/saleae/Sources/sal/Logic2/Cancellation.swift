import Dispatch
import Darwin
import Synchronization

/// Cancels a capture without cancelling the cleanup that must follow it.
///
/// Task cancellation alone is not enough: it would also tear down the gRPC connection
/// and fail the calls that stop and close the capture in Logic 2.
final class CaptureCancellation: Sendable {
    private struct State {
        var isCancelled = false
        var interruptible: Task<Void, any Error>?
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.interruptible
        }
        task?.cancel()
    }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Runs the one operation that cancellation may abandon partway through. Throws
    /// `CancellationError` if cancelled, however the operation itself ended.
    func interruptible(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try checkCancelled()
        let task = Task { try await operation() }
        let cancelledAlready = state.withLock { state in
            state.interruptible = task
            return state.isCancelled
        }
        if cancelledAlready { task.cancel() }

        do {
            try await task.value
        } catch {
            try checkCancelled()
            throw error
        }
        try checkCancelled()
    }
}

/// Runs `body` shielded from the caller's cancellation, which is delivered through the
/// `CaptureCancellation` instead. Returns only once `body` has finished cleaning up.
func withCaptureCancellation<Result: Sendable>(
    _ body: @escaping @Sendable (CaptureCancellation) async throws -> Result
) async throws -> Result {
    let cancellation = CaptureCancellation()
    let work = Task.detached { try await body(cancellation) }
    return try await withTaskCancellationHandler {
        try await work.value
    } onCancel: {
        cancellation.cancel()
    }
}

/// Cancels `body` on SIGINT or SIGTERM. The first signal restores the previous handler,
/// so a second one can still kill the process if cleanup hangs.
func cancellingOnInterrupt<Result: Sendable>(
    _ body: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let work = Task { try await body() }
    let watches = [SIGINT, SIGTERM].map { number in
        let previous = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            signal(number, previous)
            work.cancel()
        }
        source.resume()
        return (number, previous, source)
    }
    defer {
        for (number, previous, source) in watches {
            source.cancel()
            signal(number, previous)
        }
    }
    return try await work.value
}
