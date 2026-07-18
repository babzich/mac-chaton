import Foundation
import LeChatonCore

enum ApplicationStartupState: Equatable {
    case starting
    case ready
    case failed(DatabaseStartupFailure)
}

enum DatabaseStartupFailureKind: Equatable {
    case schemaTooNew
    case recoverable
    case unavailable
}

struct DatabaseStartupFailure: Equatable {
    let kind: DatabaseStartupFailureKind
    let title: String
    let message: String
    let details: String

    init(error: any Error) {
        details = String(describing: error)
        switch error {
        case PersistenceStoreError.schemaTooNew:
            kind = .schemaTooNew
            title = "LeChaton needs an update"
            message = "This local metadata store was created by a newer version. It has not been changed."
        case PersistenceStoreError.corruptDatabase, PersistenceStoreError.migrationFailed:
            kind = .recoverable
            title = "Local metadata needs recovery"
            message = "Vibe history is untouched. LeChaton can move its database to Recovery before creating a fresh store."
        default:
            kind = .unavailable
            title = "Local metadata is unavailable"
            message = "LeChaton could not open its app-owned metadata. Vibe history has not been changed."
        }
    }
}

enum WorkspaceDestination: String, Hashable, Identifiable {
    case conversation
    case changes

    var id: String { rawValue }
}

enum ThreadCreationMode: Equatable {
    case new
    case replace
}

struct ThreadCreationDraft: Identifiable, Equatable {
    let id = UUID()
    let mode: ThreadCreationMode
    let repositoryURL: URL
    var title: String
}
