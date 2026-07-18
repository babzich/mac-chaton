import Foundation
import GRDB
import Testing
@testable import LeChatonCore

@Suite("Persistence migration v1", .serialized)
struct PersistenceMigrationTests {
    @Test("v1 exposes only the constrained metadata schema")
    func exactSchema() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try PersistenceStore(applicationSupportRoot: root)
        try await store.close()
        let queue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: root).databaseFile
        )
        defer { try? queue.close() }

        let schema = try await queue.read { db in
            try ["projects", "threads", "thread_environments", "app_settings"]
                .reduce(into: [String: [ColumnDescriptor]]()) { result, table in
                    result[table] = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map {
                        ColumnDescriptor(
                            name: $0["name"],
                            type: $0["type"],
                            notNull: ($0["notnull"] as Int64) == 1,
                            primaryKey: ($0["pk"] as Int64) == 1
                        )
                    }
                }
        }

        #expect(schema["projects"] == [
            .init(name: "id", type: "TEXT", notNull: true, primaryKey: true),
            .init(name: "canonical_path", type: "TEXT", notNull: true, primaryKey: false),
            .init(name: "display_name", type: "TEXT", notNull: true, primaryKey: false),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, primaryKey: false),
            .init(name: "last_opened_at_ms", type: "INTEGER", notNull: true, primaryKey: false),
        ])
        #expect(schema["threads"] == [
            .init(name: "id", type: "TEXT", notNull: true, primaryKey: true),
            .init(name: "project_id", type: "TEXT", notNull: true, primaryKey: false),
            .init(name: "vibe_session_id", type: "TEXT", notNull: true, primaryKey: false),
            .init(name: "title", type: "TEXT", notNull: true, primaryKey: false),
            .init(name: "created_at_ms", type: "INTEGER", notNull: true, primaryKey: false),
            .init(name: "updated_at_ms", type: "INTEGER", notNull: true, primaryKey: false),
        ])
        #expect(schema["thread_environments"] == [
            .init(name: "thread_id", type: "TEXT", notNull: true, primaryKey: true),
            .init(name: "cwd", type: "TEXT", notNull: true, primaryKey: false),
            .init(name: "execution_mode", type: "TEXT", notNull: true, primaryKey: false),
        ])
        #expect(schema["app_settings"] == [
            .init(name: "id", type: "INTEGER", notNull: true, primaryKey: true),
            .init(name: "selected_vibe_path", type: "TEXT", notNull: false, primaryKey: false),
            .init(name: "selected_thread_id", type: "TEXT", notNull: false, primaryKey: false),
        ])

        let migrationIdentifiers = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrationIdentifiers == ["v1"])
        let settingsRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_settings")
        }
        #expect(settingsRows == 1)
    }

    @Test("v1 enforces uniqueness, foreign keys, one-to-one Environment, and singleton Settings")
    func constraintsAndDeleteActions() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(applicationSupportRoot: root)
        try await store.close()
        let queue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: root).databaseFile
        )
        defer { try? queue.close() }

        try await queue.write { db in
            try db.execute(sql: "INSERT INTO projects VALUES ('p1', '/repo', 'Repo', 1001, 1002)")
            try db.execute(sql: "INSERT INTO threads VALUES ('t1', 'p1', 'session-1', 'Thread', 1003, 1004)")
            try db.execute(sql: "INSERT INTO thread_environments VALUES ('t1', '/repo', 'local')")
            try db.execute(sql: "UPDATE app_settings SET selected_thread_id = 't1' WHERE id = 1")
        }

        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO app_settings (id) VALUES (2)")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO projects VALUES ('p2', '/repo', 'Duplicate', 1, 1)")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO threads VALUES ('t2', 'missing', 'session-2', 'Missing', 1, 1)")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO threads VALUES ('t2', 'p1', 'session-1', 'Duplicate', 1, 1)")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO thread_environments VALUES ('t1', '/repo', 'local')")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO thread_environments VALUES ('missing', '/repo', 'local')")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "UPDATE thread_environments SET execution_mode = 'remote' WHERE thread_id = 't1'")
            }
        }

        try await queue.write { db in
            try db.execute(sql: "DELETE FROM threads WHERE id = 't1'")
        }
        let afterThreadDeletion = try await queue.read { db in
            DeleteActionSnapshot(
                projects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects")!,
                threads: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM threads")!,
                environments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread_environments")!,
                selection: try String.fetchOne(db, sql: "SELECT selected_thread_id FROM app_settings WHERE id = 1")
            )
        }
        #expect(afterThreadDeletion == .init(projects: 1, threads: 0, environments: 0, selection: nil))

        try await queue.write { db in
            try db.execute(sql: "INSERT INTO threads VALUES ('t2', 'p1', 'session-2', 'Thread 2', 1005, 1006)")
            try db.execute(sql: "INSERT INTO thread_environments VALUES ('t2', '/repo', 'local')")
            try db.execute(sql: "UPDATE app_settings SET selected_thread_id = 't2' WHERE id = 1")
            try db.execute(sql: "DELETE FROM projects WHERE id = 'p1'")
        }
        let afterProjectDeletion = try await queue.read { db in
            DeleteActionSnapshot(
                projects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects")!,
                threads: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM threads")!,
                environments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread_environments")!,
                selection: try String.fetchOne(db, sql: "SELECT selected_thread_id FROM app_settings WHERE id = 1")
            )
        }
        #expect(afterProjectDeletion == .init(projects: 0, threads: 0, environments: 0, selection: nil))
    }

    @Test("timestamps are persisted as UTC Unix milliseconds in INTEGER columns")
    func timestampRepresentation() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        let repository = try PersistenceTestSupport.makeRepository()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
        }
        let store = try PersistenceStore(
            applicationSupportRoot: root,
            clock: { Date(timeIntervalSince1970: 1_700_000_000.9876) }
        )
        _ = try await store.createThread(.init(
            repositoryURL: repository,
            vibeSessionID: "timestamp-session",
            title: "Timestamp"
        ))
        try await store.close()

        let queue = try PersistenceTestSupport.databaseQueue(
            at: PersistenceLocations(applicationSupportRoot: root).databaseFile
        )
        defer { try? queue.close() }
        let values = try await queue.read { db in
            TimestampStorage(
                projectCreatedType: try String.fetchOne(db, sql: "SELECT typeof(created_at_ms) FROM projects")!,
                projectCreatedValue: try Int64.fetchOne(db, sql: "SELECT created_at_ms FROM projects")!,
                threadUpdatedType: try String.fetchOne(db, sql: "SELECT typeof(updated_at_ms) FROM threads")!,
                threadUpdatedValue: try Int64.fetchOne(db, sql: "SELECT updated_at_ms FROM threads")!
            )
        }
        #expect(values.projectCreatedType == "integer")
        #expect(values.threadUpdatedType == "integer")
        #expect(values.projectCreatedValue == 1_700_000_000_987)
        #expect(values.threadUpdatedValue == 1_700_000_000_987)
    }

    @Test("too-new, corrupt, and migration-failure stores are distinguished")
    func failureClassification() async throws {
        try await verifyTooNewClassification()
        try verifyCorruptionClassification()
        try verifyMigrationFailureClassification()
    }

    private func verifyTooNewClassification() async throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try PersistenceStore(applicationSupportRoot: root)
        try await initial.close()
        let locations = PersistenceLocations(applicationSupportRoot: root)
        let queue = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v2')")
        }
        try queue.close()

        do {
            _ = try PersistenceStore(applicationSupportRoot: root)
            Issue.record("Expected a too-new schema failure")
        } catch let PersistenceStoreError.schemaTooNew(applied, supported) {
            #expect(applied == ["v1", "v2"])
            #expect(supported == ["v1"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func verifyCorruptionClassification() throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: locations.databaseDirectory,
            withIntermediateDirectories: true
        )
        try Data("this is not SQLite".utf8).write(to: locations.databaseFile)

        do {
            _ = try PersistenceStore(applicationSupportRoot: root)
            Issue.record("Expected a corruption failure")
        } catch let error as PersistenceStoreError {
            guard case .corruptDatabase = error else {
                Issue.record("Unexpected persistence classification: \(error)")
                return
            }
        }
    }

    private func verifyMigrationFailureClassification() throws {
        let root = try PersistenceTestSupport.makeApplicationSupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PersistenceLocations(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: locations.databaseDirectory,
            withIntermediateDirectories: true
        )
        let queue = try PersistenceTestSupport.databaseQueue(at: locations.databaseFile)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE projects (conflict INTEGER)")
        }
        try queue.close()

        do {
            _ = try PersistenceStore(applicationSupportRoot: root)
            Issue.record("Expected a migration failure")
        } catch let error as PersistenceStoreError {
            guard case .migrationFailed = error else {
                Issue.record("Unexpected persistence classification: \(error)")
                return
            }
        }
    }
}

private struct ColumnDescriptor: Equatable, Sendable {
    let name: String
    let type: String
    let notNull: Bool
    let primaryKey: Bool
}

private struct DeleteActionSnapshot: Equatable, Sendable {
    let projects: Int
    let threads: Int
    let environments: Int
    let selection: String?
}

private struct TimestampStorage: Equatable, Sendable {
    let projectCreatedType: String
    let projectCreatedValue: Int64
    let threadUpdatedType: String
    let threadUpdatedValue: Int64
}
