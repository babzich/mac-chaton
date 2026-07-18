import Foundation

public struct PersistenceLocations: Equatable, Sendable {
    public let applicationSupportRoot: URL
    public let databaseDirectory: URL
    public let databaseFile: URL
    public let recoveryDirectory: URL

    public init(applicationSupportRoot: URL) {
        let root = applicationSupportRoot.standardizedFileURL
        self.applicationSupportRoot = root
        databaseDirectory = root.appending(path: "Database", directoryHint: .isDirectory)
        databaseFile = databaseDirectory.appending(path: "LeChaton.sqlite", directoryHint: .notDirectory)
        recoveryDirectory = root.appending(path: "Recovery", directoryHint: .isDirectory)
    }

    public static func defaultLocations() throws -> PersistenceLocations {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PersistenceStoreError.storeSetupFailed("Application Support directory is unavailable")
        }
        return PersistenceLocations(
            applicationSupportRoot: applicationSupport.appending(
                path: "com.vincentbach.LeChaton",
                directoryHint: .isDirectory
            )
        )
    }
}

public struct ProjectMetadata: Equatable, Sendable {
    public let id: UUID
    public let canonicalPath: String
    public let displayName: String
    public let createdAt: Date
    public let lastOpenedAt: Date

    public init(
        id: UUID,
        canonicalPath: String,
        displayName: String,
        createdAt: Date,
        lastOpenedAt: Date
    ) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct ThreadMetadata: Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let vibeSessionID: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        projectID: UUID,
        vibeSessionID: String,
        title: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.vibeSessionID = vibeSessionID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ThreadExecutionMode: String, Equatable, Sendable {
    case local
}

public struct ThreadEnvironmentMetadata: Equatable, Sendable {
    public let threadID: UUID
    public let cwd: String
    public let executionMode: ThreadExecutionMode

    public init(threadID: UUID, cwd: String, executionMode: ThreadExecutionMode) {
        self.threadID = threadID
        self.cwd = cwd
        self.executionMode = executionMode
    }
}

public struct SavedThreadMetadata: Equatable, Sendable {
    public let project: ProjectMetadata
    public let thread: ThreadMetadata
    public let environment: ThreadEnvironmentMetadata

    public init(
        project: ProjectMetadata,
        thread: ThreadMetadata,
        environment: ThreadEnvironmentMetadata
    ) {
        self.project = project
        self.thread = thread
        self.environment = environment
    }
}

public struct AppSettingsMetadata: Equatable, Sendable {
    public let selectedVibePath: String?
    public let selectedThreadID: UUID?

    public init(selectedVibePath: String?, selectedThreadID: UUID?) {
        self.selectedVibePath = selectedVibePath
        self.selectedThreadID = selectedThreadID
    }
}

/// Metadata restored on launch. It never contains transcript or runtime state.
public struct PersistenceSnapshot: Equatable, Sendable {
    public let settings: AppSettingsMetadata
    public let selectedThread: SavedThreadMetadata?

    public init(settings: AppSettingsMetadata, selectedThread: SavedThreadMetadata?) {
        self.settings = settings
        self.selectedThread = selectedThread
    }
}

public struct CreateThreadRequest: Equatable, Sendable {
    public let projectID: UUID
    public let threadID: UUID
    public let repositoryURL: URL
    public let vibeSessionID: String
    public let title: String

    public init(
        projectID: UUID = UUID(),
        threadID: UUID = UUID(),
        repositoryURL: URL,
        vibeSessionID: String,
        title: String
    ) {
        self.projectID = projectID
        self.threadID = threadID
        self.repositoryURL = repositoryURL
        self.vibeSessionID = vibeSessionID
        self.title = title
    }
}

public struct PersistenceResetResult: Equatable, Sendable {
    public let backupDirectory: URL
    public let restoredSnapshot: PersistenceSnapshot

    public init(backupDirectory: URL, restoredSnapshot: PersistenceSnapshot) {
        self.backupDirectory = backupDirectory
        self.restoredSnapshot = restoredSnapshot
    }
}

public enum PersistenceRecoveryRefusal: Equatable, Sendable, CustomStringConvertible {
    case databaseMissing
    case healthyStore
    case unsupportedFailure(String)

    public var description: String {
        switch self {
        case .databaseMissing:
            "No local metadata database exists to recover"
        case .healthyStore:
            "The local metadata database opens successfully"
        case let .unsupportedFailure(reason):
            "The local metadata failure is not eligible for reset: \(reason)"
        }
    }
}

public enum PersistenceStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case storeClosed
    case selectedThreadAlreadyExists
    case noSelectedThread
    case selectedThreadChanged(expected: UUID, actual: UUID?)
    case invalidArgument(String)
    case invalidStoredMetadata(String)
    case schemaTooNew(appliedMigrations: [String], supportedMigrations: [String])
    case corruptDatabase(String)
    case migrationFailed(String)
    case databaseFailure(String)
    case storeSetupFailed(String)
    case recoveryNotPermitted(PersistenceRecoveryRefusal)
    case resetBackupFailed(String)
    case resetRecreationFailed(backupDirectory: URL, reason: String)

    public var description: String {
        switch self {
        case .storeClosed: "Persistence store is closed"
        case .selectedThreadAlreadyExists: "A saved Thread is already selected"
        case .noSelectedThread: "No saved Thread is selected"
        case let .selectedThreadChanged(expected, actual):
            "Saved Thread selection changed (expected: \(expected), actual: \(String(describing: actual)))"
        case let .invalidArgument(message): "Invalid persistence input: \(message)"
        case let .invalidStoredMetadata(message): "Invalid stored metadata: \(message)"
        case let .schemaTooNew(applied, supported):
            "Database schema is newer than this application (applied: \(applied), supported: \(supported))"
        case let .corruptDatabase(message): "Local metadata database is corrupt: \(message)"
        case let .migrationFailed(message): "Local metadata migration failed: \(message)"
        case let .databaseFailure(message): "Local metadata operation failed: \(message)"
        case let .storeSetupFailed(message): "Could not prepare local metadata storage: \(message)"
        case let .recoveryNotPermitted(reason): "Local metadata recovery is not permitted: \(reason)"
        case let .resetBackupFailed(message): "Could not create recoverable metadata backup: \(message)"
        case let .resetRecreationFailed(backupDirectory, reason):
            "Metadata was backed up to \(backupDirectory.path), but the new store could not be created: \(reason)"
        }
    }
}
