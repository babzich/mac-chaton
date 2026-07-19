import Darwin
import Foundation
import GRDB
import Testing
@testable import LeChatonCore

@Suite("Persistence store", .serialized)
struct PersistenceStoreTests {
    @Test("Create and launch restoration persist metadata only")
    func createAndRestore() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository(name: "Project ü")
        let canonicalRepositoryPath = try PersistenceTestSupport.canonicalPath(repository)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let instant = Date(timeIntervalSince1970: 1_720_000_000.123)
        let store = try PersistenceStore(applicationSupportRoot: root, clock: { instant })
        let empty = try await store.restoreMetadata()
        #expect(empty.settings == AppSettingsMetadata(selectedVibePath: nil, selectedThreadID: nil))
        #expect(empty.selectedThread == nil)

        let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let threadID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let nestedRepositoryDirectory = repository.appending(
            path: "Sources/Nested",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: nestedRepositoryDirectory,
            withIntermediateDirectories: true
        )
        let repositoryAlias = root.appending(path: "repository alias", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: repositoryAlias,
            withDestinationURL: nestedRepositoryDirectory
        )
        let created = try await store.createThread(.init(
            projectID: projectID,
            threadID: threadID,
            repositoryURL: repositoryAlias,
            vibeSessionID: "vibe-session-1",
            title: "First Thread"
        ))
        #expect(created.project.id == projectID)
        #expect(created.project.canonicalPath == canonicalRepositoryPath)
        #expect(created.environment.cwd == canonicalRepositoryPath)
        #expect(created.environment.executionMode == .local)
        #expect(created.thread.id == threadID)
        #expect(created.thread.vibeSessionID == "vibe-session-1")
        #expect(created.thread.createdAt == Date(timeIntervalSince1970: 1_720_000_000.123))

        await #expect(throws: PersistenceStoreError.selectedThreadAlreadyExists) {
            _ = try await store.createThread(.init(
                repositoryURL: repository,
                vibeSessionID: "vibe-session-2",
                title: "Second"
            ))
        }

        let executable = root.appending(path: "vibe executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        #expect(chmod(executable.path, 0o700) == 0)
        let executableLink = root.appending(path: "selected-vibe")
        try FileManager.default.createSymbolicLink(at: executableLink, withDestinationURL: executable)
        let settings = try await store.updateSelectedVibePath(executableLink)
        #expect(settings.selectedVibePath == executable.path)
        #expect(settings.selectedThreadID == threadID)

        try await store.close()
        let reopened = try PersistenceStore(applicationSupportRoot: root)
        let restored = try await reopened.restoreMetadata()
        #expect(restored.selectedThread == created)
        #expect(restored.settings.selectedVibePath == executable.path)

        // Launch restoration is metadata-only and does not require the repository to remain present.
        try FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        try await reopened.close()
        let missingRepositoryStore = try PersistenceStore(applicationSupportRoot: root)
        let unavailable = try await missingRepositoryStore.restoreMetadata()
        #expect(unavailable.selectedThread?.project.canonicalPath == canonicalRepositoryPath)
        _ = try await missingRepositoryStore.updateSelectedVibePath(nil)
        let clearedPath = try await missingRepositoryStore.restoreMetadata()
        #expect(clearedPath.settings.selectedVibePath == nil)
        try await missingRepositoryStore.close()
    }

    @Test("Replacement is stale-safe, reuses canonical Projects, and removal cleans orphans")
    func replaceAndRemove() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let oldProjectID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let oldThreadID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let newThreadID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let store = try PersistenceStore(applicationSupportRoot: root)
        _ = try await store.createThread(.init(
            projectID: oldProjectID,
            threadID: oldThreadID,
            repositoryURL: repository,
            vibeSessionID: "old-session",
            title: "Old"
        ))

        let staleID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        await #expect(throws: PersistenceStoreError.selectedThreadChanged(
            expected: staleID,
            actual: oldThreadID
        )) {
            _ = try await store.replaceSelectedThread(
                expectedSelectedThreadID: staleID,
                with: .init(repositoryURL: repository, vibeSessionID: "new-session", title: "New")
            )
        }

        let replacement = try await store.replaceSelectedThread(
            expectedSelectedThreadID: oldThreadID,
            with: .init(
                projectID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                threadID: newThreadID,
                repositoryURL: repository,
                vibeSessionID: "new-session",
                title: "New"
            )
        )
        #expect(replacement.project.id == oldProjectID)
        #expect(replacement.thread.id == newThreadID)
        let replacedSnapshot = try await store.restoreMetadata()
        #expect(replacedSnapshot.settings.selectedThreadID == newThreadID)

        let removed = try await store.removeSelectedThread(expectedSelectedThreadID: newThreadID)
        #expect(removed == replacement)
        let emptySnapshot = try await store.restoreMetadata()
        #expect(emptySnapshot.selectedThread == nil)
        try await store.close()

        let queue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: root).databaseFile
        )
        let counts = try await queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM threads")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread_environments")!
            )
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 0)
        try queue.close()
    }

    @Test("A failed replacement rolls back the authoritative selection")
    func replacementRollback() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let oldThreadID = UUID(uuidString: "10101010-1010-1010-1010-101010101010")!
        let hiddenThreadID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
        let store = try PersistenceStore(applicationSupportRoot: root)
        let old = try await store.createThread(.init(
            threadID: oldThreadID,
            repositoryURL: repository,
            vibeSessionID: "authoritative",
            title: "Authoritative"
        ))
        try await store.close()

        let locations = PersistenceLocations(applicationSupportRoot: root)
        let queue = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO threads (id, project_id, vibe_session_id, title, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'hidden', 'Hidden', 1, 1)
                    """,
                arguments: [hiddenThreadID.uuidString.lowercased(), old.project.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "INSERT INTO thread_environments (thread_id, cwd, execution_mode) VALUES (?, ?, 'local')",
                arguments: [hiddenThreadID.uuidString.lowercased(), repository.path]
            )
        }
        try queue.close()

        let reopened = try PersistenceStore(applicationSupportRoot: root)
        await #expect(throws: PersistenceStoreError.self) {
            _ = try await reopened.replaceSelectedThread(
                expectedSelectedThreadID: oldThreadID,
                with: .init(
                    threadID: hiddenThreadID,
                    repositoryURL: repository,
                    vibeSessionID: "candidate",
                    title: "Candidate"
                )
            )
        }
        let restored = try await reopened.restoreMetadata()
        #expect(restored.selectedThread == old)
        #expect(restored.settings.selectedThreadID == oldThreadID)
        try await reopened.close()
    }

    @Test("Unselected relational rows do not impose a schema-wide one-Thread restriction")
    func oneAccessibleThreadIsStoreInvariant() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let hiddenRepository = try PersistenceTestSupport.makeRepository(name: "Hidden")
        let selectedRepository = try PersistenceTestSupport.makeRepository(name: "Selected")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: hiddenRepository.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: selectedRepository.deletingLastPathComponent())
        }
        let initial = try PersistenceStore(applicationSupportRoot: root)
        try await initial.close()
        let locations = PersistenceLocations(applicationSupportRoot: root)
        let queue = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO projects VALUES ('p-hidden', ?, 'Hidden', 1, 1);
                INSERT INTO threads VALUES ('t-hidden', 'p-hidden', 's-hidden', 'Hidden', 1, 1);
                INSERT INTO thread_environments VALUES ('t-hidden', ?, 'local');
                """, arguments: [hiddenRepository.path, hiddenRepository.path])
        }
        try queue.close()

        let store = try PersistenceStore(applicationSupportRoot: root)
        let created = try await store.createThread(.init(
            repositoryURL: selectedRepository,
            vibeSessionID: "accessible",
            title: "Accessible"
        ))
        let snapshot = try await store.restoreMetadata()
        #expect(snapshot.selectedThread == created)
        try await store.close()

        let verification = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        let threadCount = try await verification.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM threads")
        }
        #expect(threadCount == 2)
        try verification.close()
    }

    @Test("Restoration rejects incomplete selected metadata without starting or replacing anything")
    func restorationRequiresEnvironmentAndSingletonSettings() async throws {
        let environmentRoot = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: environmentRoot)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let environmentStore = try PersistenceStore(applicationSupportRoot: environmentRoot)
        let selected = try await environmentStore.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "missing-environment",
            title: "Missing Environment"
        ))
        try await environmentStore.close()

        let environmentQueue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: environmentRoot).databaseFile
        )
        try await environmentQueue.write { db in
            try db.execute(
                sql: "DELETE FROM thread_environments WHERE thread_id = ?",
                arguments: [selected.thread.id.uuidString.lowercased()]
            )
        }
        try environmentQueue.close()

        #expect(throws: PersistenceStoreError.self) {
            _ = try PersistenceStore(applicationSupportRoot: environmentRoot)
        }

        let settingsRoot = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: settingsRoot) }
        let settingsStore = try PersistenceStore(applicationSupportRoot: settingsRoot)
        try await settingsStore.close()
        let settingsQueue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: settingsRoot).databaseFile
        )
        try await settingsQueue.write { db in
            try db.execute(sql: "DELETE FROM app_settings")
        }
        try settingsQueue.close()

        #expect(throws: PersistenceStoreError.self) {
            _ = try PersistenceStore(applicationSupportRoot: settingsRoot)
        }
    }

    @Test("Restoration rejects a Thread environment outside its canonical Project root")
    func restorationRequiresMatchingProjectAndEnvironmentRoots() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }

        let store = try PersistenceStore(applicationSupportRoot: root)
        let selected = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "mismatched-environment",
            title: "Mismatched Environment"
        ))
        try await store.close()

        let queue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: root).databaseFile
        )
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE thread_environments SET cwd = ? WHERE thread_id = ?",
                arguments: ["/tmp/not-the-project", selected.thread.id.uuidString.lowercased()]
            )
        }
        try queue.close()

        #expect(throws: PersistenceStoreError.self) {
            _ = try PersistenceStore(applicationSupportRoot: root)
        }
    }

    @Test("Closing the store cancels and joins in-flight repository validation")
    func closeJoinsRepositoryValidation() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let validator = SuspendedStoreRepositoryValidator()
        let store = try PersistenceStore(
            locations: PersistenceLocations(applicationSupportRoot: root),
            clock: { Date(timeIntervalSince1970: 1_720_000_000) },
            makeUUID: { UUID() },
            validateRepository: { url in try await validator.validate(url) }
        )

        let create = Task {
            try await store.createThread(.init(
                repositoryURL: root,
                vibeSessionID: "must-not-persist",
                title: "Cancelled"
            ))
        }
        await waitUntil { await validator.isWaiting }

        let closeCompletion = PersistenceCloseCompletion()
        let close = Task {
            try await store.close()
            await closeCompletion.markFinished()
        }
        await waitUntil { await validator.cancellationObserved }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(await closeCompletion.isFinished == false)

        await validator.releaseCleanup()
        try await close.value
        await #expect(throws: CancellationError.self) {
            _ = try await create.value
        }
        #expect(await closeCompletion.isFinished)
        await #expect(throws: PersistenceStoreError.storeClosed) {
            _ = try await store.restoreMetadata()
        }
    }
}

private actor SuspendedStoreRepositoryValidator {
    private(set) var isWaiting = false
    private(set) var cancellationObserved = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?

    func validate(_ url: URL) async throws -> CanonicalRepository {
        isWaiting = true
        defer { isWaiting = false }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancellationObserved = true
            await withCheckedContinuation { cleanupContinuation = $0 }
            throw CancellationError()
        }
        return CanonicalRepository(path: url.path)
    }

    func releaseCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}

private actor PersistenceCloseCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0 ..< 2_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for an asynchronous persistence condition")
}
