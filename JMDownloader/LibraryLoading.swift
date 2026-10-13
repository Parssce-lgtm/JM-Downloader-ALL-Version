import Foundation

struct LibraryLoadProgress: Sendable, Equatable {
    var stage: String
    var fraction: Double = 0
    var completed: Int = 0
    var total: Int = 0
    var percent: Int { min(100, max(0, Int((fraction * 100).rounded()))) }
    var text: String { stage + (total > 0 ? " · \(completed)/\(total) · \(percent)%" : " · \(percent)%") }
    static func step(_ stage: String, _ count: Int, _ total: Int, from start: Double = 0, to end: Double = 0.99) -> Self {
        Self(stage: stage, fraction: start + (end - start) * Double(count) / Double(max(1, total)), completed: count, total: total)
    }
}

typealias LibraryProgressHandler = @Sendable (LibraryLoadProgress) async -> Void
typealias LibraryResultsHandler = @Sendable ([Comic]) async -> Void

enum LibraryFailureKind: Sendable, Equatable { case network, load
    static func classify(_ error: Error) -> Self {
        if error is URLError || error is JMTransportError { return .network }
        if let failure = error as? LibraryLoadFailure { return failure.kind }
        return .load
    }
}
struct LibraryLoadFailure: LocalizedError {
    let kind: LibraryFailureKind
    let message: String
    var errorDescription: String? { message }
}
struct JMTransportError: LocalizedError {
    let host: String
    let underlying: URLError
    var errorDescription: String? { "JMComic API \(host)：" + NetworkFailure.describe(underlying) }
}

enum LibraryLoadDeadline {
    // URLSession cooperates with cancellation. An idle UI must never wait through
    // a day-long API resource timeout or an unbounded series of slow routes.
    static func run<Value: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
