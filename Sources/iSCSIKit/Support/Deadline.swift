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
/// **The deadline holds even if `operation` ignores cancellation.** That is the
/// entire point, and the previous implementation — a `withThrowingTaskGroup`
/// racing the work against a sleep — could not deliver it. Structured
/// concurrency guarantees a task group does not return until every child task
/// has finished, and `cancelAll()` only sets a flag. An operation suspended on
/// a plain `withCheckedContinuation` never observes that flag, never finishes,
/// and the group waits on it forever. The deadline fired and changed nothing.
///
/// That is not hypothetical. A volume served over Backend A hung for eight
/// hours behind exactly this, with `iscsid` showing five idle threads and no
/// work in flight — which is what a suspended-forever task looks like from
/// outside, since suspended tasks hold no threads. Above it, the FSKit
/// extension's read blocked, DiskImages retried forever, and
/// `diskimages-helper` sat in uninterruptible wait dragging down
/// `diskarbitrationd`, Finder, Time Machine and everything else that touches
/// the mount table.
///
/// A caller cannot know whether the work it is bounding is cancellable — not
/// knowing is why it asked for a deadline. So the racers are unstructured tasks
/// and the winner is delivered through a gate, which lets this return while the
/// loser is still running.
///
/// The cost is that a genuinely uncancellable operation leaks a suspended task
/// until it completes, which may be never. That is deliberate: an abandoned
/// task costs a few kilobytes, and the alternative is a Mac that has to be
/// rebooted. Callers whose work *is* cancellable — which is all of them in this
/// package — pay nothing, because the loser observes the cancellation below and
/// unwinds immediately.
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
