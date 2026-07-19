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
    private(set) var isGitBaselineReady = false
    @ObservationIgnored private var gitBaselineRequestID = UUID()
    @ObservationIgnored private var shutdownInProgress = false

    var canPrompt: Bool { !shutdownInProgress && model.canPrompt && isGitBaselineReady }

    var canCreateThread: Bool {
        guard model.selectedThread == nil else { return false }

        switch model.issue?.kind {
        case .database, .authenticationRequired, .trustRequired:
            return false
        default:
            break
        }

        return switch model.lifecycle {
        case .unloaded, .failed(_): true
        default: false
        }
    }

    var canReplaceThread: Bool {
        guard model.selectedThread != nil else { return false }
        return model.lifecycle == .unloaded || model.lifecycle == .idle
    }

    var canRemoveThread: Bool {
        guard model.selectedThread != nil, !model.hasPendingCleanup else { return false }
        return switch model.lifecycle {
        case .unloaded, .idle, .reloadRequired, .failed(_): true
        default: false
        }
    }

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
        invalidateGitBaseline()
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
        invalidateGitBaseline()
        await model.resolveRepositoryTrust(decision: decision)
        await recaptureGitBaselineIfLoaded()
    }

    func retryPendingRepositoryTrust() async {
        transientError = nil
        invalidateGitBaseline()
        await model.retryPendingRepositoryTrust()
        await recaptureGitBaselineIfLoaded()
    }

    func cancelPendingRepositoryTrust() {
        transientError = nil
        model.cancelPendingRepositoryTrust()
    }

    func createThread(repositoryURL: URL, title: String) async {
        transientError = nil
        invalidateGitBaseline()
        await model.createThread(repositoryURL: repositoryURL, title: title)
        await recaptureGitBaselineIfLoaded()
    }

    func replaceThread(repositoryURL: URL, title: String) async {
        transientError = nil
        invalidateGitBaseline()
        await model.replaceSavedThread(repositoryURL: repositoryURL, title: title)
        await recaptureGitBaselineIfLoaded()
    }

    func sendPrompt(_ text: String) async {
        transientError = nil
        guard canPrompt else {
            transientError = "Capture the repository baseline before prompting. Use Retry Baseline or open Repository Changes."
            return
        }
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
        invalidateGitBaseline()
        await model.unload()
    }

    func resetRuntime() async {
        invalidateGitBaseline()
        await model.resetRuntime()
    }

    func retryCleanup() async {
        transientError = nil
        await model.retryCleanup()
    }

    func retryExecutableCandidate() async {
        transientError = nil
        await model.retryExecutableCandidate()
    }

    func removeSavedThread() async {
        invalidateGitBaseline()
        await model.removeSavedThread()
    }

    func refreshGit() async {
        guard !shutdownInProgress, let repositoryURL else { return }
        let requestID = UUID()
        gitBaselineRequestID = requestID
        let repositoryPath = repositoryURL.standardizedFileURL.path
        let ready = await git.refresh(repository: repositoryURL)
        guard gitBaselineRequestID == requestID,
              model.lifecycle == .idle,
              self.repositoryURL?.standardizedFileURL.path == repositoryPath
        else { return }
        isGitBaselineReady = ready
    }

    func validateExecutable(_ url: URL) async {
        transientError = nil
        await model.validateExecutableCandidate(url)
    }

    func refreshCurrentAuthentication() async {
        transientError = nil
        do {
            try await model.refreshCurrentAuthentication()
        } catch {
            transientError = String(describing: error)
        }
    }

    func startCurrentAuthentication() async {
        transientError = nil
        do {
            let url = try await model.startCurrentAuthentication()
            NSWorkspace.shared.open(url)
        } catch {
            transientError = String(describing: error)
        }
    }

    func completeCurrentAuthentication(attemptID: String) async {
        transientError = nil
        do {
            try await model.completeCurrentAuthentication(attemptID: attemptID)
        } catch {
            transientError = String(describing: error)
        }
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
        invalidateGitBaseline()
        await model.commitExecutableCandidate()
    }

    func applyConfiguration(optionID: String, value: JSONValue) async {
        await model.applyConfiguration(optionID: optionID, value: value)
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

    @discardableResult
    func shutdown() async -> Bool {
        shutdownInProgress = true
        invalidateGitBaseline()
        await git.prepareForShutdown()

        let canTerminate = await model.shutdown()
        if !canTerminate {
            shutdownInProgress = false
            git.resumeAfterFailedShutdown()
        }
        return canTerminate
    }

    private var repositoryURL: URL? {
        model.selectedThread.map {
            URL(filePath: $0.environment.cwd, directoryHint: .isDirectory)
        }
    }

    private func recaptureGitBaselineIfLoaded() async {
        isGitBaselineReady = false
        guard !shutdownInProgress, model.lifecycle == .idle, let repositoryURL else { return }
        let requestID = UUID()
        gitBaselineRequestID = requestID
        let repositoryPath = repositoryURL.standardizedFileURL.path
        let ready = await git.captureBaseline(repository: repositoryURL)
        guard gitBaselineRequestID == requestID,
              model.lifecycle == .idle,
              self.repositoryURL?.standardizedFileURL.path == repositoryPath
        else { return }
        isGitBaselineReady = ready
    }

    private func invalidateGitBaseline() {
        gitBaselineRequestID = UUID()
        isGitBaselineReady = false
        git.clear()
    }
}
