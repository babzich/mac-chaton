import AppKit
import Foundation
import LeChatonCore
import Observation

@MainActor
@Observable
final class ApplicationContainer {
    private(set) var startupState: ApplicationStartupState = .starting
    private(set) var workspace: WorkspaceController?
    private(set) var startupRecoveryBackupURL: URL?
    private(set) var notice: String?

    @ObservationIgnored private var store: PersistenceStore?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    let locations: PersistenceLocations?

    init() {
        locations = try? PersistenceLocations.defaultLocations()
    }

    func start() {
        guard startTask == nil, workspace == nil else { return }
        startupState = .starting
        startTask = Task { [weak self] in
            await self?.openStore()
        }
    }

    func retryStartup() {
        guard case .failed = startupState else { return }
        startTask?.cancel()
        startTask = nil
        notice = nil
        start()
    }

    func recoverLocalMetadata() {
        guard case let .failed(failure) = startupState, failure.kind == .recoverable else { return }
        startupState = .starting
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PersistenceStore.recoverFailedLocalMetadata()
                }.value
                startupRecoveryBackupURL = result.backupDirectory
                startTask = nil
                start()
            } catch {
                startupState = .failed(DatabaseStartupFailure(error: error))
                startTask = nil
            }
        }
    }

    func revealDatabase() {
        guard let locations else { return }
        let target = FileManager.default.fileExists(atPath: locations.databaseFile.path)
            ? locations.databaseFile
            : locations.databaseDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func exportStartupDiagnostic() {
        guard case let .failed(failure) = startupState else { return }
        let panel = NSSavePanel()
        panel.title = "Export LeChaton Diagnostic"
        panel.nameFieldStringValue = "LeChaton-metadata-diagnostic.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let databasePath = locations?.databaseFile.path ?? "unavailable"
        let report = """
        LeChaton local metadata diagnostic
        Date: \(Date().formatted(.iso8601))
        Database: \(databasePath)
        Category: \(String(describing: failure.kind))
        Details: \(failure.details)
        """
        do {
            try Data(report.utf8).write(to: destination, options: .atomic)
            notice = "Diagnostic exported to \(destination.path)."
        } catch {
            notice = "The diagnostic could not be exported: \(error)"
        }
    }

    func showUpdateInstructions() {
        notice = "Install a newer LeChaton build, then reopen this database. Reset is intentionally unavailable for a newer schema."
    }

    func dismissNotice() {
        notice = nil
    }

    func shutdown() async -> Bool {
        startTask?.cancel()
        startTask = nil
        if let workspace {
            await workspace.shutdown()
            return workspace.model.lifecycle != .cleanupRequired
        }
        if let store {
            do {
                try await store.close()
                return true
            } catch {
                notice = "LeChaton could not close local metadata safely: \(error)"
                return false
            }
        }
        return true
    }

    private func openStore() async {
        do {
            let store = try PersistenceStore()
            let model = SessionModel(
                store: store,
                neutralApplicationSupportURL: store.locations.applicationSupportRoot
            )
            let workspace = WorkspaceController(
                model: model,
                gitInspector: GitInspector(),
                persistenceLocations: store.locations
            )
            self.store = store
            self.workspace = workspace
            await model.restoreLaunchMetadata()
            startupState = .ready
        } catch is CancellationError {
            return
        } catch {
            store = nil
            workspace = nil
            startupState = .failed(DatabaseStartupFailure(error: error))
        }
        startTask = nil
    }
}
