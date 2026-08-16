import Testing
import Foundation
@testable import iSCSIKit

/// `withDeadline` is the last line of defence between a stuck target and a
/// wedged Mac. Everything above it — the daemon's XPC reply, the FSKit
/// extension's read, DiskImages, APFS — is waiting on it to give up on time.
///
/// These tests exist because it did not. A volume served over Backend A hung
/// for eight hours with the daemon showing five idle threads and no work in
/// flight, which is what a suspended-forever Swift task looks like from
/// outside: suspended tasks hold no threads.
@Suite("withDeadline") struct DeadlineTests {

    /// A box that is safe to read from the test while a task writes it.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func returnsAResultBeforeTheDeadline() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func nilDurationMeansNoDeadline() async throws {
        let value = try await withDeadline(nil) { 7 }
        #expect(value == 7)
    }

    @Test func timesOutOnAnOperationThatIsMerelySlow() async throws {
        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// The one that matters.
    ///
    /// `withThrowingTaskGroup` cannot return until every child task has
    /// finished — that is the guarantee structured concurrency is built on.
    /// `group.cancelAll()` only sets a flag, so an operation suspended on a
    /// plain continuation never notices, never finishes, and the group waits on
    /// it forever. The deadline fires and changes nothing.
    ///
    /// A caller cannot know whether the work it is bounding is cancellable —
    /// that is the whole reason it asked for a deadline. So the deadline has to
    /// hold even when the answer is no.
    ///
    /// Deliberately not written as a bare `await withDeadline(...)`: if the bug
    /// is present that never returns, and the test would hang the suite instead
    /// of failing it. The work runs detached and the assertion is on whether it
    /// came back.
    @Test func timesOutEvenWhenTheOperationIgnoresCancellation() async throws {
        let returned = Flag()

        let work = Task {
            _ = try? await withDeadline(.milliseconds(100)) {
                // Never resumed, and no cancellation handler, so cancelling the
                // task that runs this does nothing at all.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            returned.set()
        }

        // Twenty times the deadline. Generous enough that a slow machine cannot
        // fail this, short enough that a hang is obvious.
        try await Task.sleep(for: .seconds(2))
        work.cancel()

        #expect(returned.isSet,
                "withDeadline did not return 2s after a 100ms deadline: it is stuck waiting on an operation that ignores cancellation, which is the case a deadline exists to survive")
    }

    /// Same shape, one layer further out: the error has to be the deadline's,
    /// not something the stuck operation invented, or callers cannot tell
    /// "target is slow" from "target returned an error".
    @Test func reportsTimedOutRatherThanSomeOtherFailure() async throws {
        let caught = ErrorBox()

        let work = Task {
            do {
                try await withDeadline(.milliseconds(100)) {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
            } catch {
                caught.store(error)
            }
        }

        try await Task.sleep(for: .seconds(2))
        work.cancel()

        #expect(caught.value is DeadlineError,
                "expected DeadlineError.timedOut; a caller cannot tell a slow target from a failing one otherwise")
    }

    /// Written by a task, read by the test.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any Error)?
        func store(_ error: any Error) { lock.lock(); stored = error; lock.unlock() }
        var value: (any Error)? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
