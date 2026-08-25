import Foundation

public enum DeadlineError: Error, Equatable, Sendable {
    case timedOut
}

/// Delivers whichever of the racers finishes first, exactly once.
///
/// The loser calls `finish` too, and is ignored. Results that arrive before
/// anyone is waiting are buffered, so the race cannot be lost to scheduling.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var buffered: Result<T, any Error>?
    private var settled = false

    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { buffered = result }
        lock.unlock()
        waiting?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let ready = buffered {
                buffered = nil
                lock.unlock()
                c.resume(with: ready)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

/// Run `operation` with an optional deadline. On timeout the operation task is
/// cancelled and `DeadlineError.timedOut` is thrown.
///
/// **The deadline holds even if `operation` ignores cancellation** — that is
/// the point. A task-group race cannot deliver it: the group waits for every
/// child, and a task suspended on a plain continuation never observes
/// `cancelAll()`, so the deadline fires and changes nothing (a Backend A
/// volume once hung for eight hours behind exactly this). So the racers are
/// unstructured tasks and the winner is delivered through a gate. The cost —
/// deliberate — is that a genuinely uncancellable loser leaks a suspended
/// task, which is a few kilobytes, versus a machine that needs a reboot.
public func withDeadline<T: Sendable>(
    _ duration: Duration?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let duration else { return try await operation() }

    let gate = DeadlineGate<T>()

    let work = Task {
        do { gate.finish(.success(try await operation())) }
        catch { gate.finish(.failure(error)) }
    }
    let timer = Task {
        do {
            try await Task.sleep(for: duration)
            gate.finish(.failure(DeadlineError.timedOut))
        } catch {
            // Cancelled because the work won. Nothing to report.
        }
    }
    defer { work.cancel(); timer.cancel() }

    // The caller being cancelled has to reach the operation too, or a cancelled
    // read would leave its SCSI task outstanding at the target.
    return try await withTaskCancellationHandler {
        try await gate.value()
    } onCancel: {
        work.cancel()
        timer.cancel()
        gate.finish(.failure(CancellationError()))
    }
}
