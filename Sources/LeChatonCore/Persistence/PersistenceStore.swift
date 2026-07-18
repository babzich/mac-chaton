import Darwin
import Foundation
import GRDB

protocol PersistenceFileOperating: Sendable {
    func createDirectory(_ url: URL) throws
    func atomicMove(_ source: URL, to destination: URL) throws
}

struct LocalPersistenceFileOperations: PersistenceFileOperating {
    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func atomicMove(_ source: URL, to destination: URL) throws {
        errno = 0
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else { return Int32(-1) }
            return destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw POSIXPersistenceError(operation: "rename", code: errno == 0 ? EINVAL : errno)
        }
    }
}

private struct POSIXPersistenceError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }
}

/// The sole owner of LeChaton's local relational metadata store.
public actor PersistenceStore {
    public nonisolated let locations: PersistenceLocations

    private let clock: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let repositoryValidator: RepositoryValidator
    private let fileOperations: any PersistenceFileOperating
    private var databasePool: DatabasePool?

    public init(
        applicationSupportRoot: URL? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let resolvedLocations: PersistenceLocations
        if let applicationSupportRoot {
            resolvedLocations = PersistenceLocations(applicationSupportRoot: applicationSupportRoot)
        } else {
            resolvedLocations = try PersistenceLocations.defaultLocations()
        }
        let operations = LocalPersistenceFileOperations()
        locations = resolvedLocations
        self.clock = clock
        makeUUID = { UUID() }
        repositoryValidator = RepositoryValidator()
        fileOperations = operations
        databasePool = try Self.openDatabase(
            at: resolvedLocations,
            fileOperations: operations
        )
    }

    init(
        locations: PersistenceLocations,
        clock: @escaping @Sendable () -> Date,
        makeUUID: @escaping @Sendable () -> UUID,
        repositoryValidator: RepositoryValidator = RepositoryValidator(),
        fileOperations: any PersistenceFileOperating = LocalPersistenceFileOperations()
    ) throws {
        self.locations = locations
        self.clock = clock
        self.makeUUID = makeUUID
        self.repositoryValidator = repositoryValidator
        self.fileOperations = fileOperations
        databasePool = try Self.openDatabase(at: locations, fileOperations: fileOperations)
    }

    /// Recovers a store that can not be initialized because SQLite reported
    /// corruption or migration failure. The caller must stop every session,
    /// authentication, and executable-candidate owner before invoking this API.
    /// Healthy and too-new databases are never moved by this operation.
    public static func recoverFailedLocalMetadata(
        applicationSupportRoot: URL? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> PersistenceResetResult {
        let locations: PersistenceLocations
        if let applicationSupportRoot {
            locations = PersistenceLocations(applicationSupportRoot: applicationSupportRoot)
        } else {
            locations = try PersistenceLocations.defaultLocations()
        }
        return try recoverFailedLocalMetadata(
            locations: locations,
            clock: clock,
            makeUUID: { UUID() },
            fileOperations: LocalPersistenceFileOperations()
        )
    }

    static func recoverFailedLocalMetadata(
        locations: PersistenceLocations,
        clock: @escaping @Sendable () -> Date,
        makeUUID: @escaping @Sendable () -> UUID,
        fileOperations: any PersistenceFileOperating
    ) throws -> PersistenceResetResult {
        guard FileManager.default.fileExists(atPath: locations.databaseFile.path) else {
            throw PersistenceStoreError.recoveryNotPermitted(.databaseMissing)
        }

        do {
            let healthyPool = try openDatabase(at: locations, fileOperations: fileOperations)
            do {
                try healthyPool.close()
            } catch {
                throw PersistenceStoreError.recoveryNotPermitted(
                    .unsupportedFailure("healthy store could not close: \(error)")
                )
            }
            throw PersistenceStoreError.recoveryNotPermitted(.healthyStore)
        } catch let error as PersistenceStoreError {
            switch error {
            case .corruptDatabase, .migrationFailed:
                break
            case .schemaTooNew, .recoveryNotPermitted:
                throw error
            default:
                throw PersistenceStoreError.recoveryNotPermitted(
                    .unsupportedFailure(String(describing: error))
                )
            }
        } catch {
            throw PersistenceStoreError.recoveryNotPermitted(
                .unsupportedFailure(String(describing: error))
            )
        }

        let backupDirectory = try backupDatabaseDirectory(
            at: locations,
            timestamp: milliseconds(clock()),
            identifier: makeUUID(),
            fileOperations: fileOperations
        )

        let replacement: DatabasePool
        do {
            replacement = try openDatabase(at: locations, fileOperations: fileOperations)
        } catch {
            throw PersistenceStoreError.resetRecreationFailed(
                backupDirectory: backupDirectory,
                reason: String(describing: error)
            )
        }
        do {
            let snapshot = try replacement.read { db in try fetchSnapshot(db) }
            try replacement.close()
            return PersistenceResetResult(
                backupDirectory: backupDirectory,
                restoredSnapshot: snapshot
            )
        } catch {
            try? replacement.close()
            throw PersistenceStoreError.resetRecreationFailed(
                backupDirectory: backupDirectory,
                reason: String(describing: error)
            )
        }
    }

    public func restoreMetadata() throws -> PersistenceSnapshot {
        try read { db in try Self.fetchSnapshot(db) }
    }

    public func createThread(_ request: CreateThreadRequest) throws -> SavedThreadMetadata {
        try Self.validate(request)
        let repository = try repositoryValidator.validate(request.repositoryURL)
        let timestamp = Self.milliseconds(clock())

        return try write { db in
            let settings = try Self.fetchSettings(db)
            guard settings.selectedThreadID == nil else {
                throw PersistenceStoreError.selectedThreadAlreadyExists
            }
            let projectID = try Self.upsertProject(
                db,
                requestedID: request.projectID,
                repository: repository,
                timestamp: timestamp
            )
            try Self.insertThread(
                db,
                threadID: request.threadID,
                projectID: projectID,
                vibeSessionID: request.vibeSessionID,
                title: request.title,
                repository: repository,
                timestamp: timestamp
            )
            try Self.selectThread(db, id: request.threadID)
            guard let metadata = try Self.fetchSavedThread(db, id: request.threadID) else {
                throw PersistenceStoreError.invalidStoredMetadata("created Thread could not be read")
            }
            return metadata
        }
    }

    public func replaceSelectedThread(
        expectedSelectedThreadID: UUID,
        with request: CreateThreadRequest
    ) throws -> SavedThreadMetadata {
        try Self.validate(request)
        let repository = try repositoryValidator.validate(request.repositoryURL)
        let timestamp = Self.milliseconds(clock())

        return try write { db in
            let settings = try Self.fetchSettings(db)
            guard let oldThreadID = settings.selectedThreadID else {
                throw PersistenceStoreError.noSelectedThread
            }
            guard oldThreadID == expectedSelectedThreadID else {
                throw PersistenceStoreError.selectedThreadChanged(
                    expected: expectedSelectedThreadID,
                    actual: oldThreadID
                )
            }
            guard let oldMetadata = try Self.fetchSavedThread(db, id: oldThreadID) else {
                throw PersistenceStoreError.invalidStoredMetadata("selected Thread is incomplete")
            }

            try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [Self.id(oldThreadID)])
            let projectID = try Self.upsertProject(
                db,
                requestedID: request.projectID,
                repository: repository,
                timestamp: timestamp
            )
            try Self.insertThread(
                db,
                threadID: request.threadID,
                projectID: projectID,
                vibeSessionID: request.vibeSessionID,
                title: request.title,
                repository: repository,
                timestamp: timestamp
            )
            try Self.selectThread(db, id: request.threadID)
            try Self.deleteProjectIfOrphaned(db, id: oldMetadata.project.id)

            guard let metadata = try Self.fetchSavedThread(db, id: request.threadID) else {
                throw PersistenceStoreError.invalidStoredMetadata("replacement Thread could not be read")
            }
            return metadata
        }
    }

    @discardableResult
    public func removeSelectedThread(expectedSelectedThreadID: UUID) throws -> SavedThreadMetadata {
        try write { db in
            let settings = try Self.fetchSettings(db)
            guard let selectedThreadID = settings.selectedThreadID else {
                throw PersistenceStoreError.noSelectedThread
            }
            guard selectedThreadID == expectedSelectedThreadID else {
                throw PersistenceStoreError.selectedThreadChanged(
                    expected: expectedSelectedThreadID,
                    actual: selectedThreadID
                )
            }
            guard let metadata = try Self.fetchSavedThread(db, id: selectedThreadID) else {
                throw PersistenceStoreError.invalidStoredMetadata("selected Thread is incomplete")
            }
            try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [Self.id(selectedThreadID)])
            try Self.deleteProjectIfOrphaned(db, id: metadata.project.id)
            let updatedSettings = try Self.fetchSettings(db)
            guard updatedSettings.selectedThreadID == nil else {
                throw PersistenceStoreError.invalidStoredMetadata("selection did not clear after Thread deletion")
            }
            return metadata
        }
    }

    public func updateSelectedVibePath(_ executableURL: URL?) throws -> AppSettingsMetadata {
        let selectedPath: String?
        if let executableURL {
            selectedPath = try VibeLocator().validate(executableURL).url.path
        } else {
            selectedPath = nil
        }

        return try write { db in
            try db.execute(
                sql: "UPDATE app_settings SET selected_vibe_path = ? WHERE id = 1",
                arguments: [selectedPath]
            )
            guard db.changesCount == 1 else {
                throw PersistenceStoreError.invalidStoredMetadata("app_settings singleton is missing")
            }
            return try Self.fetchSettings(db)
        }
    }

    public func close() throws {
        guard let databasePool else { return }
        do {
            try databasePool.close()
            self.databasePool = nil
        } catch {
            throw Self.classifyDatabaseError(error)
        }
    }

    /// Call only after session, authentication, and candidate runtime owners are stopped.
    public func resetLocalMetadata() throws -> PersistenceResetResult {
        guard let databasePool else { throw PersistenceStoreError.storeClosed }
        do {
            try databasePool.close()
            self.databasePool = nil
        } catch {
            throw PersistenceStoreError.resetBackupFailed("store could not close: \(error)")
        }

        let backupDirectory = try Self.backupDatabaseDirectory(
            at: locations,
            timestamp: Self.milliseconds(clock()),
            identifier: makeUUID(),
            fileOperations: fileOperations
        )

        let replacement: DatabasePool
        do {
            replacement = try Self.openDatabase(at: locations, fileOperations: fileOperations)
        } catch {
            self.databasePool = nil
            throw PersistenceStoreError.resetRecreationFailed(
                backupDirectory: backupDirectory,
                reason: String(describing: error)
            )
        }
        do {
            let snapshot = try replacement.read { db in try Self.fetchSnapshot(db) }
            self.databasePool = replacement
            return PersistenceResetResult(
                backupDirectory: backupDirectory,
                restoredSnapshot: snapshot
            )
        } catch {
            try? replacement.close()
            self.databasePool = nil
            throw PersistenceStoreError.resetRecreationFailed(
                backupDirectory: backupDirectory,
                reason: String(describing: error)
            )
        }
    }

    private static func backupDatabaseDirectory(
        at locations: PersistenceLocations,
        timestamp: Int64,
        identifier: UUID,
        fileOperations: any PersistenceFileOperating
    ) throws -> URL {
        let backupDirectory = locations.recoveryDirectory.appending(
            path: "Database-\(timestamp)-\(identifier.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        do {
            try fileOperations.createDirectory(locations.recoveryDirectory)
            try fileOperations.atomicMove(locations.databaseDirectory, to: backupDirectory)
            return backupDirectory
        } catch {
            throw PersistenceStoreError.resetBackupFailed(String(describing: error))
        }
    }

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        guard let databasePool else { throw PersistenceStoreError.storeClosed }
        do { return try databasePool.read(body) }
        catch let error as PersistenceStoreError { throw error }
        catch { throw Self.classifyDatabaseError(error) }
    }

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
        guard let databasePool else { throw PersistenceStoreError.storeClosed }
        do { return try databasePool.write(body) }
        catch let error as PersistenceStoreError { throw error }
        catch { throw Self.classifyDatabaseError(error) }
    }

    private static func openDatabase(
        at locations: PersistenceLocations,
        fileOperations: any PersistenceFileOperating
    ) throws -> DatabasePool {
        do {
            try fileOperations.createDirectory(locations.applicationSupportRoot)
            try fileOperations.createDirectory(locations.databaseDirectory)
            try fileOperations.createDirectory(locations.recoveryDirectory)
        } catch {
            throw PersistenceStoreError.storeSetupFailed(String(describing: error))
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            guard try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") == true else {
                throw DatabaseError(message: "foreign key enforcement is disabled")
            }
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: locations.databaseFile.path, configuration: configuration)
        } catch {
            throw classifyDatabaseError(error)
        }

        let migrator = makeMigrator()
        do {
            let integrity = try pool.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            }
            guard integrity == ["ok"] else {
                try? pool.close()
                throw PersistenceStoreError.corruptDatabase(integrity.joined(separator: "; "))
            }
            let superseded = try pool.read { db in try migrator.hasBeenSuperseded(db) }
            if superseded {
                let applied = try pool.read { db in
                    try migrator.appliedIdentifiers(db).sorted()
                }
                try? pool.close()
                throw PersistenceStoreError.schemaTooNew(
                    appliedMigrations: applied,
                    supportedMigrations: migrator.migrations
                )
            }
        } catch let error as PersistenceStoreError {
            throw error
        } catch {
            try? pool.close()
            throw classifyDatabaseError(error)
        }

        do {
            try migrator.migrate(pool)
            return pool
        } catch {
            try? pool.close()
            if let error = error as? DatabaseError,
               error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
                throw PersistenceStoreError.corruptDatabase(error.message ?? "SQLite corruption")
            }
            throw PersistenceStoreError.migrationFailed(String(describing: error))
        }
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    canonical_path TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    last_opened_at_ms INTEGER NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    vibe_session_id TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE thread_environments (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    cwd TEXT NOT NULL,
                    execution_mode TEXT NOT NULL CHECK(execution_mode = 'local')
                );
                CREATE TABLE app_settings (
                    id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1),
                    selected_vibe_path TEXT,
                    selected_thread_id TEXT REFERENCES threads(id) ON DELETE SET NULL
                );
                INSERT INTO app_settings (id) VALUES (1);
                """)
        }
        return migrator
    }

    private static func fetchSnapshot(_ db: Database) throws -> PersistenceSnapshot {
        let settings = try fetchSettings(db)
        guard let selectedThreadID = settings.selectedThreadID else {
            return PersistenceSnapshot(settings: settings, selectedThread: nil)
        }
        guard let thread = try fetchSavedThread(db, id: selectedThreadID) else {
            throw PersistenceStoreError.invalidStoredMetadata("selected Thread is missing its Project or Environment")
        }
        return PersistenceSnapshot(settings: settings, selectedThread: thread)
    }

    private static func fetchSettings(_ db: Database) throws -> AppSettingsMetadata {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, selected_vibe_path, selected_thread_id FROM app_settings"
        )
        guard rows.count == 1 else {
            throw PersistenceStoreError.invalidStoredMetadata("app_settings must contain exactly one row")
        }
        let row = rows[0]
        let settingsID: Int64 = row["id"]
        guard settingsID == 1 else {
            throw PersistenceStoreError.invalidStoredMetadata("app_settings row must have id 1")
        }
        let selectedVibePath: String? = row["selected_vibe_path"]
        let selectedThreadString: String? = row["selected_thread_id"]
        let selectedThreadID: UUID?
        if let selectedThreadString {
            guard let parsed = UUID(uuidString: selectedThreadString) else {
                throw PersistenceStoreError.invalidStoredMetadata("selected Thread id is not a UUID")
            }
            selectedThreadID = parsed
        } else {
            selectedThreadID = nil
        }
        return AppSettingsMetadata(
            selectedVibePath: selectedVibePath,
            selectedThreadID: selectedThreadID
        )
    }

    private static func fetchSavedThread(_ db: Database, id threadID: UUID) throws -> SavedThreadMetadata? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    t.id AS thread_id,
                    t.project_id AS thread_project_id,
                    t.vibe_session_id,
                    t.title,
                    t.created_at_ms AS thread_created_at_ms,
                    t.updated_at_ms AS thread_updated_at_ms,
                    p.id AS project_id,
                    p.canonical_path,
                    p.display_name,
                    p.created_at_ms AS project_created_at_ms,
                    p.last_opened_at_ms,
                    e.thread_id AS environment_thread_id,
                    e.cwd,
                    e.execution_mode
                FROM threads t
                JOIN projects p ON p.id = t.project_id
                JOIN thread_environments e ON e.thread_id = t.id
                WHERE t.id = ?
                """,
            arguments: [Self.id(threadID)]
        ) else { return nil }

        let storedThreadID = try uuid(row, column: "thread_id")
        let threadProjectID = try uuid(row, column: "thread_project_id")
        let projectID = try uuid(row, column: "project_id")
        let environmentThreadID = try uuid(row, column: "environment_thread_id")
        guard storedThreadID == threadID,
              threadProjectID == projectID,
              environmentThreadID == threadID else {
            throw PersistenceStoreError.invalidStoredMetadata("Thread relationship identifiers disagree")
        }
        let executionModeString: String = row["execution_mode"]
        guard let executionMode = ThreadExecutionMode(rawValue: executionModeString) else {
            throw PersistenceStoreError.invalidStoredMetadata("unsupported execution mode \(executionModeString)")
        }

        let project = ProjectMetadata(
            id: projectID,
            canonicalPath: row["canonical_path"],
            displayName: row["display_name"],
            createdAt: date(row, column: "project_created_at_ms"),
            lastOpenedAt: date(row, column: "last_opened_at_ms")
        )
        let thread = ThreadMetadata(
            id: threadID,
            projectID: projectID,
            vibeSessionID: row["vibe_session_id"],
            title: row["title"],
            createdAt: date(row, column: "thread_created_at_ms"),
            updatedAt: date(row, column: "thread_updated_at_ms")
        )
        let environment = ThreadEnvironmentMetadata(
            threadID: threadID,
            cwd: row["cwd"],
            executionMode: executionMode
        )
        return SavedThreadMetadata(project: project, thread: thread, environment: environment)
    }

    private static func upsertProject(
        _ db: Database,
        requestedID: UUID,
        repository: CanonicalRepository,
        timestamp: Int64
    ) throws -> UUID {
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT id FROM projects WHERE canonical_path = ?",
            arguments: [repository.path]
        ) {
            let existingID = try uuid(row, column: "id")
            try db.execute(
                sql: "UPDATE projects SET display_name = ?, last_opened_at_ms = ? WHERE id = ?",
                arguments: [repository.displayName, timestamp, id(existingID)]
            )
            return existingID
        }
        try db.execute(
            sql: """
                INSERT INTO projects (
                    id, canonical_path, display_name, created_at_ms, last_opened_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [id(requestedID), repository.path, repository.displayName, timestamp, timestamp]
        )
        return requestedID
    }

    private static func insertThread(
        _ db: Database,
        threadID: UUID,
        projectID: UUID,
        vibeSessionID: String,
        title: String,
        repository: CanonicalRepository,
        timestamp: Int64
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO threads (
                    id, project_id, vibe_session_id, title, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [id(threadID), id(projectID), vibeSessionID, title, timestamp, timestamp]
        )
        try db.execute(
            sql: """
                INSERT INTO thread_environments (thread_id, cwd, execution_mode)
                VALUES (?, ?, 'local')
                """,
            arguments: [id(threadID), repository.path]
        )
    }

    private static func selectThread(_ db: Database, id threadID: UUID) throws {
        try db.execute(
            sql: "UPDATE app_settings SET selected_thread_id = ? WHERE id = 1",
            arguments: [id(threadID)]
        )
        guard db.changesCount == 1 else {
            throw PersistenceStoreError.invalidStoredMetadata("app_settings singleton is missing")
        }
    }

    private static func deleteProjectIfOrphaned(_ db: Database, id projectID: UUID) throws {
        try db.execute(
            sql: """
                DELETE FROM projects
                WHERE id = ?
                  AND NOT EXISTS (SELECT 1 FROM threads WHERE project_id = projects.id)
                """,
            arguments: [id(projectID)]
        )
    }

    private static func validate(_ request: CreateThreadRequest) throws {
        guard !request.vibeSessionID.isEmpty else {
            throw PersistenceStoreError.invalidArgument("Vibe session id must not be empty")
        }
    }

    private static func id(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func uuid(_ row: Row, column: String) throws -> UUID {
        let value: String = row[column]
        guard let id = UUID(uuidString: value) else {
            throw PersistenceStoreError.invalidStoredMetadata("\(column) is not a UUID")
        }
        return id
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func date(_ row: Row, column: String) -> Date {
        let milliseconds: Int64 = row[column]
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func classifyDatabaseError(_ error: any Error) -> PersistenceStoreError {
        if let error = error as? PersistenceStoreError { return error }
        if let databaseError = error as? DatabaseError {
            if databaseError.resultCode == .SQLITE_CORRUPT || databaseError.resultCode == .SQLITE_NOTADB {
                return .corruptDatabase(databaseError.message ?? "SQLite corruption")
            }
            return .databaseFailure(databaseError.message ?? String(describing: databaseError))
        }
        return .databaseFailure(String(describing: error))
    }
}
