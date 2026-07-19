import Foundation

/// Orders the destructive portion of the live configuration gate so cleanup and restoration
/// still run after worker failure or caller cancellation. The operations are injected to keep
/// this contract deterministic and offline-testable; the live probe supplies the process and
/// Vibe-specific implementations.
enum ConfigurationGateSupervisor {
    static func run(
        worker: @escaping @Sendable () async throws -> Void,
        cleanupWorker: @escaping @Sendable () async throws -> Void,
        restoreOriginals: @escaping @Sendable () async throws -> Void,
        commitRestoration: @escaping @Sendable () async throws -> Void
    ) async throws {
        var workerError: (any Error)?
        do {
            try await worker()
        } catch {
            workerError = error
        }

        // Neither caller cancellation nor a failed worker may suppress cleanup. A worker that
        // could still mutate global configuration must be gone before restoration starts.
        do {
            try await Task.detached(priority: .userInitiated) {
                try await cleanupWorker()
            }.value
        } catch {
            throw ConfigurationGateSupervisorError.cleanup(error)
        }

        // Restoration and journal removal are one ordered, non-cancelled recovery operation.
        // The commit is deliberately skipped when restoration fails so the journal survives.
        do {
            try await Task.detached(priority: .userInitiated) {
                try await restoreOriginals()
                try await commitRestoration()
            }.value
        } catch {
            throw ConfigurationGateSupervisorError.restoration(error)
        }

        if let workerError { throw workerError }
    }
}

enum ConfigurationGateSupervisorError: Error {
    case cleanup(any Error)
    case restoration(any Error)
}
