import Foundation

public enum DeadlineError: Error, Equatable, Sendable {
    case timedOut
}

/// Run `operation` with an optional deadline. On timeout the operation task
/// is cancelled and `DeadlineError.timedOut` is thrown.
public func withDeadline<T: Sendable>(
    _ duration: Duration?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let duration else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw DeadlineError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw DeadlineError.timedOut
        }
        return first
    }
}
