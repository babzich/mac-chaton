import Foundation
import GRDB
import Testing
@testable import LeChatonCore

@Suite("Recoverable persistence reset", .serialized)
struct PersistenceResetTests {
    @Test("unopened recovery replaces a corrupt store and preserves its forensic bytes")
    func unopenedCorruptionRecovery() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: locations.databaseDirectory,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data("not a SQLite database".utf8)
        try corruptBytes.write(to: locations.databaseFile)
        let marker = locations.databaseDirectory.appending(path: "forensic.marker")
        try Data("keep".utf8).write(to: marker)

        let result = try PersistenceStore.recoverFailedLocalMetadata(
            applicationSupportRoot: root,
            clock: { Date(timeIntervalSince1970: 300) }
        )

        #expect(result.restoredSnapshot == PersistenceSnapshot(
            settings: .init(selectedVibePath: nil, selectedThreadID: nil),
            selectedThread: nil
        ))
        #expect(try Data(contentsOf: result.backupDirectory.appending(path: "LeChaton.sqlite")) == corruptBytes)
        #expect(FileManager.default.fileExists(
            atPath: result.backupDirectory.appending(path: "forensic.marker").path
        ))
        let reopened = try PersistenceStore(applicationSupportRoot: root)
        try await reopened.close()
    }

    @Test("unopened recovery accepts migration failure and produces a clean v1 store")
    func unopenedMigrationRecovery() throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: locations.databaseDirectory,
            withIntermediateDirectories: true
        )
        let conflicting = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        try conflicting.write { db in
            try db.execute(sql: "CREATE TABLE projects (conflicting_column INTEGER NOT NULL)")
        }
        try conflicting.close()

        let result = try PersistenceStore.recoverFailedLocalMetadata(
            applicationSupportRoot: root,
            clock: { Date(timeIntervalSince1970: 400) }
        )
        #expect(result.restoredSnapshot.selectedThread == nil)
        let backup = try PersistenceTestSupport.databaseQueue(
            at: result.backupDirectory.appending(path: "LeChaton.sqlite")
        )
        let backupColumns = try backup.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')")
        }
        #expect(backupColumns == ["conflicting_column"])
        try backup.close()

        let fresh = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        let freshTables = try fresh.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'app_settings'"
            )
        }
        #expect(freshTables == ["app_settings"])
        try fresh.close()
    }

    @Test("unopened recovery refuses healthy, missing, and too-new stores without moving them")
    func unopenedRecoveryRefusals() async throws {
        let healthyRoot = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: healthyRoot)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let healthyStore = try PersistenceStore(applicationSupportRoot: healthyRoot)
        let saved = try await healthyStore.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "healthy-recovery-refusal",
            title: "Healthy"
        ))
        try await healthyStore.close()

        #expect(throws: PersistenceStoreError.recoveryNotPermitted(.healthyStore)) {
            _ = try PersistenceStore.recoverFailedLocalMetadata(applicationSupportRoot: healthyRoot)
        }
        let healthyReopened = try PersistenceStore(applicationSupportRoot: healthyRoot)
        let healthySnapshot = try await healthyReopened.restoreMetadata()
        #expect(healthySnapshot.selectedThread == saved)
        try await healthyReopened.close()

        let missingRoot = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        #expect(throws: PersistenceStoreError.recoveryNotPermitted(.databaseMissing)) {
            _ = try PersistenceStore.recoverFailedLocalMetadata(applicationSupportRoot: missingRoot)
        }
        #expect(!FileManager.default.fileExists(
            atPath: PersistenceLocations(applicationSupportRoot: missingRoot).databaseFile.path
        ))

        let tooNewRoot = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: tooNewRoot) }
        let tooNewStore = try PersistenceStore(applicationSupportRoot: tooNewRoot)
        try await tooNewStore.close()
        let tooNewLocations = PersistenceLocations(applicationSupportRoot: tooNewRoot)
        let tooNewQueue = try PersistenceTestSupport.databaseQueue(at: tooNewLocations.databaseFile)
        try await tooNewQueue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v2')")
        }
        try tooNewQueue.close()

        do {
            _ = try PersistenceStore.recoverFailedLocalMetadata(applicationSupportRoot: tooNewRoot)
            Issue.record("Expected too-new recovery refusal")
        } catch let PersistenceStoreError.schemaTooNew(applied, supported) {
            #expect(applied == ["v1", "v2"])
            #expect(supported == ["v1"])
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: tooNewLocations.databaseFile.path))
        let recoveryEntries = try FileManager.default.contentsOfDirectory(
            at: tooNewLocations.recoveryDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(recoveryEntries.isEmpty)
    }

    @Test("unopened recovery aborts before recreation when the backup move fails")
    func unopenedBackupFailure() throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: locations.databaseDirectory,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data("corrupt and authoritative".utf8)
        try corruptBytes.write(to: locations.databaseFile)

        do {
            _ = try PersistenceStore.recoverFailedLocalMetadata(
                locations: locations,
                clock: { Date(timeIntervalSince1970: 500) },
                makeUUID: { UUID(uuidString: "11111111-aaaa-bbbb-cccc-222222222222")! },
                fileOperations: FailingMoveFileOperations()
            )
            Issue.record("Expected unopened backup failure")
        } catch let error as PersistenceStoreError {
            guard case .resetBackupFailed = error else {
                Issue.record("Unexpected recovery error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: locations.databaseFile) == corruptBytes)
        let recoveryEntries = try FileManager.default.contentsOfDirectory(
            at: locations.recoveryDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(recoveryEntries.isEmpty)
    }

    @Test("unopened recovery preserves its backup when fresh-store creation fails")
    func unopenedRecreationFailure() throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: locations.databaseDirectory,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data("corrupt before recreation".utf8)
        try corruptBytes.write(to: locations.databaseFile)
        let state = RecreationFailureState(databaseDirectory: locations.databaseDirectory)

        let backupDirectory: URL
        do {
            _ = try PersistenceStore.recoverFailedLocalMetadata(
                locations: locations,
                clock: { Date(timeIntervalSince1970: 600) },
                makeUUID: { UUID(uuidString: "33333333-aaaa-bbbb-cccc-444444444444")! },
                fileOperations: RecreationFailingFileOperations(state: state)
            )
            Issue.record("Expected fresh-store recreation failure")
            return
        } catch let PersistenceStoreError.resetRecreationFailed(backup, _) {
            backupDirectory = backup
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: locations.databaseDirectory.path))
        #expect(try Data(contentsOf: backupDirectory.appending(path: "LeChaton.sqlite")) == corruptBytes)
    }

    @Test("reset moves the complete Database directory and creates a fresh migrated store")
    func resetBacksUpWholeDirectory() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let store = try PersistenceStore(applicationSupportRoot: root)
        let saved = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "before-reset",
            title: "Before Reset"
        ))
        let forensicMarker = store.locations.databaseDirectory.appending(path: "forensic.marker")
        try Data("retain me".utf8).write(to: forensicMarker)

        let result = try await store.resetLocalMetadata()
        #expect(result.restoredSnapshot == PersistenceSnapshot(
            settings: .init(selectedVibePath: nil, selectedThreadID: nil),
            selectedThread: nil
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.backupDirectory.appending(path: "LeChaton.sqlite").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.backupDirectory.appending(path: "forensic.marker").path
        ))
        #expect(!FileManager.default.fileExists(atPath: forensicMarker.path))
        #expect(FileManager.default.fileExists(atPath: store.locations.databaseFile.path))

        let backupQueue = try PersistenceTestSupport.databaseQueue(
            at: result.backupDirectory.appending(path: "LeChaton.sqlite")
        )
        let backupSelection = try await backupQueue.read { db in
            try String.fetchOne(db, sql: "SELECT selected_thread_id FROM app_settings WHERE id = 1")
        }
        #expect(backupSelection == saved.thread.id.uuidString.lowercased())
        try backupQueue.close()

        let afterReset = try await store.restoreMetadata()
        #expect(afterReset.selectedThread == nil)
        _ = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "after-reset",
            title: "After Reset"
        ))
        try await store.close()
    }

    @Test("an exclusive backup-name collision aborts without moving or recreating the store")
    func destinationCollisionPreservesOriginal() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let instant = Date(timeIntervalSince1970: 1_720_000_000.123)
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let locations = PersistenceLocations(applicationSupportRoot: root)
        let store = try PersistenceStore(
            locations: locations,
            clock: { instant },
            makeUUID: { uuid }
        )
        let saved = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "collision",
            title: "Collision"
        ))
        let collision = locations.recoveryDirectory.appending(
            path: "Database-1720000000123-11111111-2222-3333-4444-555555555555",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let sentinel = collision.appending(path: "existing")
        try Data("do not replace".utf8).write(to: sentinel)

        await #expect(throws: PersistenceStoreError.self) {
            _ = try await store.resetLocalMetadata()
        }
        #expect(FileManager.default.fileExists(atPath: locations.databaseFile.path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))

        let reopened = try PersistenceStore(applicationSupportRoot: root)
        let snapshot = try await reopened.restoreMetadata()
        #expect(snapshot.selectedThread == saved)
        try await reopened.close()
    }

    @Test("a failed backup move leaves the sole forensic database in place")
    func failedMoveDoesNotRecreate() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        let store = try PersistenceStore(
            locations: locations,
            clock: { Date(timeIntervalSince1970: 100) },
            makeUUID: { UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")! },
            fileOperations: FailingMoveFileOperations()
        )
        let saved = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "failed-move",
            title: "Failed Move"
        ))

        do {
            _ = try await store.resetLocalMetadata()
            Issue.record("Expected backup failure")
        } catch let error as PersistenceStoreError {
            guard case .resetBackupFailed = error else {
                Issue.record("Unexpected reset error: \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: locations.databaseFile.path))
        let recoveryContents = try FileManager.default.contentsOfDirectory(
            at: locations.recoveryDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(recoveryContents.isEmpty)

        let reopened = try PersistenceStore(applicationSupportRoot: root)
        let snapshot = try await reopened.restoreMetadata()
        #expect(snapshot.selectedThread == saved)
        try await reopened.close()
    }

    @Test("fresh-store failure preserves the completed backup and reports its path")
    func failedRecreationPreservesBackup() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        let state = RecreationFailureState(databaseDirectory: locations.databaseDirectory)
        let operations = RecreationFailingFileOperations(state: state)
        let store = try PersistenceStore(
            locations: locations,
            clock: { Date(timeIntervalSince1970: 200) },
            makeUUID: { UUID(uuidString: "99999999-8888-7777-6666-555555555555")! },
            fileOperations: operations
        )
        let saved = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "failed-recreation",
            title: "Failed Recreation"
        ))
        let marker = locations.databaseDirectory.appending(path: "forensic.marker")
        try Data("preserve".utf8).write(to: marker)

        let backupDirectory: URL
        do {
            _ = try await store.resetLocalMetadata()
            Issue.record("Expected recreation failure")
            return
        } catch let PersistenceStoreError.resetRecreationFailed(backup, _) {
            backupDirectory = backup
        } catch {
            Issue.record("Unexpected reset error: \(error)")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: locations.databaseDirectory.path))
        #expect(FileManager.default.fileExists(
            atPath: backupDirectory.appending(path: "LeChaton.sqlite").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: backupDirectory.appending(path: "forensic.marker").path
        ))
        await #expect(throws: PersistenceStoreError.storeClosed) {
            _ = try await store.restoreMetadata()
        }

        let backupQueue = try PersistenceTestSupport.databaseQueue(
            at: backupDirectory.appending(path: "LeChaton.sqlite")
        )
        let selectedID = try await backupQueue.read { db in
            try String.fetchOne(db, sql: "SELECT selected_thread_id FROM app_settings WHERE id = 1")
        }
        #expect(selectedID == saved.thread.id.uuidString.lowercased())
        try backupQueue.close()
    }
}

private struct FailingMoveFileOperations: PersistenceFileOperating {
    private let local = LocalPersistenceFileOperations()

    func createDirectory(_ url: URL) throws {
        try local.createDirectory(url)
    }

    func atomicMove(_: URL, to _: URL) throws {
        throw PersistenceFixtureError.injected("atomic move")
    }
}

private final class RecreationFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var moved = false
    let databaseDirectory: URL

    init(databaseDirectory: URL) {
        self.databaseDirectory = databaseDirectory
    }

    func markMoved() {
        lock.withLock { moved = true }
    }

    func shouldFail(_ url: URL) -> Bool {
        lock.withLock { moved && url.standardizedFileURL == databaseDirectory.standardizedFileURL }
    }
}

private struct RecreationFailingFileOperations: PersistenceFileOperating {
    let state: RecreationFailureState
    private let local = LocalPersistenceFileOperations()

    func createDirectory(_ url: URL) throws {
        if state.shouldFail(url) {
            throw PersistenceFixtureError.injected("fresh Database directory")
        }
        try local.createDirectory(url)
    }

    func atomicMove(_ source: URL, to destination: URL) throws {
        try local.atomicMove(source, to: destination)
        state.markMoved()
    }
}
