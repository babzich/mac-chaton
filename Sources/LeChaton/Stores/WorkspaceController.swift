import AppKit
import Foundation
import LeChatonCore
import Observation

@MainActor
@Observable
final class WorkspaceController {
    let model: SessionModel
    let git: GitInspectionController
    let persistenceLocations: PersistenceLocations

    private(set) var transientError: String?

    init(
        model: SessionModel,
        gitInspector: GitInspector,
        persistenceLocations: PersistenceLocations
    ) {
        self.model = model
        git = GitInspectionController(inspector: gitInspector)
        self.persistenceLocations = persistenceLocations
    }

    func resume() async {
        transientError = nil
        await model.resume()
        await recaptureGitBaselineIfLoaded()
    }

    func retryCurrentIssue() async {
        if model.issue?.kind == .database {
            await model.restoreLaunchMetadata()
        } else if model.selectedThread != nil {
            await resume()
        }
    }

    func resolveRepositoryTrust(decision: String) async {
        transientError = nil
        await model.resolveRepositoryTrust(decision: decision)
        await recaptureGitBaselineIfLoaded()
    }

    func createThread(repositoryURL: URL, title: String) async {
        transientError = nil
        await model.createThread(repositoryURL: repositoryURL, title: title)
        await recaptureGitBaselineIfLoaded()
    }

    func replaceThread(repositoryURL: URL, title: String) async {
        transientError = nil
        await model.replaceSavedThread(repositoryURL: repositoryURL, title: title)
        await recaptureGitBaselineIfLoaded()
    }

    func sendPrompt(_ text: String) async {
        transientError = nil
        do {
            _ = try await model.sendPrompt(text)
        } catch {
            transientError = String(describing: error)
        }
    }

    func resolvePermission(_ permission: PendingPermission, optionID: String) async {
        transientError = nil
        do {
            try await model.resolvePermission(
                requestID: permission.id,
                selectedOptionID: optionID
            )
        } catch {
            transientError = String(describing: error)
        }
    }

    func cancelPrompt() async {
        await model.cancelPrompt()
    }

    func unload() async {
        await model.unload()
        git.clear()
    }

    func resetRuntime() async {
        await model.resetRuntime()
        git.clear()
    }

    func removeSavedThread() async {
        await model.removeSavedThread()
        if model.selectedThread == nil { git.clear() }
    }

    func refreshGit() async {
        guard let repositoryURL else { return }
        await git.refresh(repository: repositoryURL)
    }

    func validateExecutable(_ url: URL) async {
        transientError = nil
        await model.validateExecutableCandidate(url)
    }

    func startCandidateAuthentication() async {
        transientError = nil
        do {
            let url = try await model.startCandidateAuthentication()
            NSWorkspace.shared.open(url)
        } catch {
            transientError = String(describing: error)
        }
    }

    func completeCandidateAuthentication(attemptID: String) async {
        transientError = nil
        do {
            try await model.completeCandidateAuthentication(attemptID: attemptID)
        } catch {
            transientError = String(describing: error)
        }
    }

    func discardExecutableCandidate() async {
        await model.discardExecutableCandidate()
    }

    func commitExecutableCandidate() async {
        await model.commitExecutableCandidate()
        if model.lifecycle == .unloaded { git.clear() }
    }

    func applyConfiguration(optionID: String, value: JSONValue) async {
        await model.applyConfiguration(optionID: optionID, value: value)
        await recaptureGitBaselineIfLoaded()
    }

    func revealDatabase() {
        let file = persistenceLocations.databaseFile
        let target = FileManager.default.fileExists(atPath: file.path)
            ? file
            : persistenceLocations.databaseDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func exportDiagnostic() {
        let panel = NSSavePanel()
        panel.title = "Export LeChaton Diagnostic"
        panel.nameFieldStringValue = "LeChaton-diagnostic.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let issue = model.issue
        let report = """
        LeChaton diagnostic
        Date: \(Date().formatted(.iso8601))
        Lifecycle: \(String(describing: model.lifecycle))
        Repository: \(model.selectedThread?.environment.cwd ?? "none")
        Issue: \(issue?.title ?? "none")
        Details: \(issue?.message ?? transientError ?? "none")
        """
        do {
            try Data(report.utf8).write(to: destination, options: .atomic)
        } catch {
            transientError = "The diagnostic could not be exported: \(error)"
        }
    }

    func showUpdateInstructions() {
        transientError = "Install a newer LeChaton build to open this metadata store."
    }

    func dismissTransientError() {
        transientError = nil
    }

    func shutdown() async {
        await model.shutdown()
    }

    private var repositoryURL: URL? {
        model.selectedThread.map {
            URL(filePath: $0.environment.cwd, directoryHint: .isDirectory)
        }
    }

    private func recaptureGitBaselineIfLoaded() async {
        guard model.lifecycle == .idle, let repositoryURL else { return }
        await git.captureBaseline(repository: repositoryURL)
    }
}

@MainActor
@Observable
final class GitInspectionController {
    private(set) var baseline: GitStatusSnapshot?
    private(set) var inspection: GitInspection?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let inspector: GitInspector

    init(inspector: GitInspector) {
        self.inspector = inspector
    }

    func captureBaseline(repository: URL) async {
        isLoading = true
        errorMessage = nil
        inspection = nil
        do {
            baseline = try await inspector.captureBaseline(repository: repository)
        } catch {
            baseline = nil
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    func refresh(repository: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let baseline: GitStatusSnapshot
            if let existing = self.baseline {
                baseline = existing
            } else {
                baseline = try await inspector.captureBaseline(repository: repository)
                self.baseline = baseline
            }
            inspection = try await inspector.inspect(repository: repository, baseline: baseline)
        } catch {
            inspection = nil
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    func clear() {
        baseline = nil
        inspection = nil
        errorMessage = nil
        isLoading = false
    }
}
