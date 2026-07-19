import AppKit
import Foundation
import LeChatonCore
import Observation

@MainActor
@Observable
final class WorkspaceController {
    let model: SessionModel
    let git: GitInspectionController
    let providers: ProviderSettingsController
    let persistenceLocations: PersistenceLocations

    private(set) var transientError: String?
    @ObservationIgnored private var gitBaselineRequestID = UUID()
    @ObservationIgnored private var gitRuntimeEpoch = UUID()
    @ObservationIgnored private var gitBaselineTask: Task<Void, Never>?
    @ObservationIgnored private var hasPromptStartedForGitEpoch = false
    @ObservationIgnored private var shutdownInProgress = false

    var canPrompt: Bool { !shutdownInProgress && model.canPrompt }
    var canCreateThread: Bool {
        guard model.threadPresentation == nil else { return false }

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
        guard model.selectedThread != nil, !model.hasProvisionalThread else { return false }
        return model.lifecycle == .unloaded || model.lifecycle == .idle
    }

    var canRemoveThread: Bool {
        guard model.selectedThread != nil,
              !model.hasProvisionalThread,
              !model.hasPendingCleanup
        else { return false }
        return switch model.lifecycle {
        case .unloaded, .idle, .reloadRequired, .failed(_): true
        default: false
        }
    }

    var canUnloadThread: Bool {
        !shutdownInProgress && !model.hasProvisionalThread && model.lifecycle == .idle
    }

    var canResetRuntime: Bool {
        guard !shutdownInProgress, !model.hasProvisionalThread else { return false }
        return switch model.lifecycle {
        case .idle, .unloaded, .failed, .reloadRequired: true
        default: false
        }
    }

    var canDiscardDraftThread: Bool {
        guard !shutdownInProgress, model.hasProvisionalThread else { return false }
        return switch model.lifecycle {
        case .idle, .failed: true
        default: false
        }
    }

    var canChangeExecutable: Bool {
        guard !shutdownInProgress, !model.hasProvisionalThread else { return false }
        return switch model.lifecycle {
        case .unloaded, .idle, .swapFailed: true
        default: false
        }
    }

    var canChangeConfiguration: Bool {
        !shutdownInProgress && !model.hasProvisionalThread && model.lifecycle == .idle
    }

    init(
        model: SessionModel,
        gitInspector: GitInspector,
        providers: ProviderSettingsController,
        persistenceLocations: PersistenceLocations
    ) {
        self.model = model
        git = GitInspectionController(inspector: gitInspector)
        self.providers = providers
        self.persistenceLocations = persistenceLocations
    }

    func resume() async {
        transientError = nil
        invalidateGitBaseline()
        await model.resume()
        startGitBaselineCaptureIfLoaded()
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
        startGitBaselineCaptureIfLoaded()
    }

    func retryPendingRepositoryTrust() async {
        transientError = nil
        invalidateGitBaseline()
        await model.retryPendingRepositoryTrust()
        startGitBaselineCaptureIfLoaded()
    }

    func cancelPendingRepositoryTrust() {
        transientError = nil
        model.cancelPendingRepositoryTrust()
    }

    func createThread(repositoryURL: URL, title: String) async {
        guard canCreateThread else { return }
        transientError = nil
        invalidateGitBaseline()
        await model.createThread(repositoryURL: repositoryURL, title: title)
        startGitBaselineCaptureIfLoaded()
    }

    func replaceThread(repositoryURL: URL, title: String) async {
        guard canReplaceThread else { return }
        transientError = nil
        invalidateGitBaseline()
        await model.replaceSavedThread(repositoryURL: repositoryURL, title: title)
        startGitBaselineCaptureIfLoaded()
    }

    func retryThreadSave() async {
        transientError = nil
        await model.retryThreadSave()
    }

    func discardDraftThread() async {
        guard canDiscardDraftThread else { return }
        transientError = nil
        invalidateGitBaseline()
        await model.discardDraftThread()
    }

    func sendPrompt(_ text: String) async {
        transientError = nil
        guard canPrompt else {
            transientError = "The Thread is not ready for a prompt."
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        closeGitAttributionWindowForPrompt()
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
        guard canUnloadThread else { return }
        invalidateGitBaseline()
        await model.unload()
    }

    func resetRuntime() async {
        guard canResetRuntime else { return }
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
        guard canRemoveThread else { return }
        invalidateGitBaseline()
        await model.removeSavedThread()
    }

    func refreshGit() async {
        guard !shutdownInProgress,
              gitBaselineTask == nil,
              let repositoryURL
        else { return }
        let requestID = UUID()
        gitBaselineRequestID = requestID
        let runtimeEpoch = gitRuntimeEpoch
        let repositoryPath = repositoryURL.standardizedFileURL.path
        _ = await git.refreshCurrent(repository: repositoryURL)
        guard gitRuntimeEpoch == runtimeEpoch,
              gitBaselineRequestID == requestID,
              model.lifecycle == .idle,
              self.repositoryURL?.standardizedFileURL.path == repositoryPath
        else { return }
    }

    func validateExecutable(_ url: URL) async {
        transientError = nil
        guard canChangeExecutable else {
            transientError = "Save or discard the draft Thread before changing the Vibe executable."
            return
        }
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
        guard canChangeExecutable else {
            transientError = "Save or discard the draft Thread before changing the Vibe executable."
            return
        }
        do {
            let url = try await model.startCandidateAuthentication()
            NSWorkspace.shared.open(url)
        } catch {
            transientError = String(describing: error)
        }
    }

    func completeCandidateAuthentication(attemptID: String) async {
        transientError = nil
        guard canChangeExecutable else {
            transientError = "Save or discard the draft Thread before changing the Vibe executable."
            return
        }
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
        guard canChangeExecutable else {
            transientError = "Save or discard the draft Thread before changing the Vibe executable."
            return
        }
        invalidateGitBaseline()
        await model.commitExecutableCandidate()
    }

    func applyConfiguration(optionID: String, value: JSONValue) async {
        guard canChangeConfiguration else {
            transientError = "Save or discard the draft Thread before changing model configuration."
            return
        }
        invalidateGitBaseline()
        await model.applyConfiguration(optionID: optionID, value: value)
        startGitBaselineCaptureIfLoaded()
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
        Repository: \(model.threadPresentation?.cwd ?? "none")
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
        await providers.shutdown()
        let pendingBaselineTask = gitBaselineTask
        invalidateGitBaseline()
        await git.prepareForShutdown()
        await pendingBaselineTask?.value

        let canTerminate = await model.shutdown()
        if !canTerminate {
            shutdownInProgress = false
            git.resumeAfterFailedShutdown()
        }
        return canTerminate
    }

    private var repositoryURL: URL? {
        model.threadPresentation.map {
            URL(filePath: $0.cwd, directoryHint: .isDirectory)
        }
    }

    private func startGitBaselineCaptureIfLoaded() {
        guard !shutdownInProgress,
              !hasPromptStartedForGitEpoch,
              model.lifecycle == .idle,
              let repositoryURL
        else { return }

        gitBaselineTask?.cancel()
        let requestID = UUID()
        gitBaselineRequestID = requestID
        let runtimeEpoch = gitRuntimeEpoch
        let repositoryPath = repositoryURL.standardizedFileURL.path

        let git = self.git
        gitBaselineTask = Task { @MainActor [weak self] in
            _ = await git.captureBaseline(repository: repositoryURL)
            guard let self else { return }
            if self.gitBaselineRequestID == requestID {
                self.gitBaselineTask = nil
            }
            let isCurrent = !Task.isCancelled
                && self.gitRuntimeEpoch == runtimeEpoch
                && self.gitBaselineRequestID == requestID
                && !self.hasPromptStartedForGitEpoch
                && self.model.lifecycle == .idle
                && self.repositoryURL?.standardizedFileURL.path == repositoryPath
            guard isCurrent else {
                if self.gitRuntimeEpoch == runtimeEpoch,
                   self.gitBaselineRequestID == requestID {
                    self.git.clear()
                }
                return
            }
        }
    }

    private func closeGitAttributionWindowForPrompt() {
        gitBaselineRequestID = UUID()
        guard !hasPromptStartedForGitEpoch else {
            git.discardInspection()
            return
        }

        hasPromptStartedForGitEpoch = true
        gitBaselineTask?.cancel()
        gitBaselineTask = nil

        if git.baseline == nil {
            git.clear()
        } else {
            git.discardInspection()
        }
    }

    private func invalidateGitBaseline() {
        gitRuntimeEpoch = UUID()
        gitBaselineRequestID = UUID()
        gitBaselineTask?.cancel()
        gitBaselineTask = nil
        hasPromptStartedForGitEpoch = false
        git.clear()
    }
}
