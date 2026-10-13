import Foundation

/// One ordered writer prevents an older progress snapshot from replacing saved settings.
final class SnapshotPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.jmdownloader.snapshots", qos: .utility)
    private let writer: (AppSnapshot) throws -> Void
    init(writer: @escaping (AppSnapshot) throws -> Void) { self.writer = writer }
    func save(_ snapshot: AppSnapshot) throws { try queue.sync { try writer(snapshot) } }
    func saveInBackground(_ snapshot: AppSnapshot) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.writer(snapshot); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
