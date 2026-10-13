import Foundation

enum ConcurrentLoad {
    /// Bound service pressure while retaining input order for stable ranking.
    static func map<Input: Sendable, Output: Sendable>(_ values: [Input], limit: Int = 3,
        onValue: ((Int, Output, Int) async -> Void)? = nil,
        operation: @escaping @Sendable (Input) async throws -> Output) async throws -> [Output] {
        guard !values.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var result: [Int: Output] = [:]
            func add(_ index: Int) {
                group.addTask { try Task.checkCancellation(); return (index, try await operation(values[index])) }
            }
            while next < min(max(1, limit), values.count) { add(next); next += 1 }
            while let (index, value) = try await group.next() {
                result[index] = value
                await onValue?(index, value, result.count)
                if next < values.count { add(next); next += 1 }
            }
            return values.indices.compactMap { result[$0] }
        }
    }
}
